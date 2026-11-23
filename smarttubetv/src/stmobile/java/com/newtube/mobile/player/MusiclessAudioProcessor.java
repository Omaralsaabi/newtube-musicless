package com.newtube.mobile.player;

import android.content.Context;
import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/** Opt-in, bounded, sample-aligned separation experiment. */
final class MusiclessAudioProcessor extends BaseAudioProcessor {
    private static final String TAG = "Musicless";
    private final Context context;
    private final AtomicInteger generation = new AtomicInteger();
    private AtomicInteger outstanding = new AtomicInteger();
    private final ArrayDeque<float[]> ready = new ArrayDeque<>();
    private float[] input = new float[MusiclessDsp.WINDOW * 2];
    private int filled;
    private long sourceFrame, receivedFrames, submittedFrames, emittedFrames;
    private double nextSample;
    private float previousLeft, previousRight;
    private volatile boolean failed;
    private boolean draining;
    private Executor executor;
    private Worker worker;

    MusiclessAudioProcessor(Context context) { this.context = context.getApplicationContext(); }

    MusiclessAudioProcessor(Worker worker, Executor executor) {
        context = null;
        this.worker = worker;
        this.executor = executor;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.encoding != C.ENCODING_PCM_16BIT || format.channelCount < 1
                || format.channelCount > 2 || format.sampleRate <= 0) {
            throw new UnhandledAudioFormatException(format);
        }
        return new AudioFormat(MusiclessDsp.RATE, 2, C.ENCODING_PCM_16BIT);
    }

    @Override
    public void queueInput(ByteBuffer buffer) {
        double step = inputAudioFormat.sampleRate / (double) MusiclessDsp.RATE;
        while (buffer.remaining() >= inputAudioFormat.bytesPerFrame) {
            // Count completed outputs too: a fast worker must not decode the entire movie ahead.
            if (!failed && outstanding.get() >= 2) return;
            float left = buffer.getShort() / 32768f;
            float right = inputAudioFormat.channelCount == 2 ? buffer.getShort() / 32768f : left;
            while (nextSample <= sourceFrame) {
                if (!failed) {
                    double fraction = sourceFrame == 0 ? 1 : nextSample - (sourceFrame - 1);
                    input[filled * 2] = (float) (previousLeft + fraction * (left - previousLeft));
                    input[filled * 2 + 1] = (float) (previousRight + fraction * (right - previousRight));
                    if (++filled == MusiclessDsp.WINDOW) submitWindow(MusiclessDsp.STRIDE);
                }
                receivedFrames++;
                nextSample += step;
            }
            previousLeft = left; previousRight = right;
            sourceFrame++;
        }
    }

    private void submitWindow(int outputFrames) {
        float[] block = input;
        input = new float[MusiclessDsp.WINDOW * 2];
        System.arraycopy(block, MusiclessDsp.STRIDE * 2, input, 0, MusiclessDsp.OVERLAP * 2);
        filled = MusiclessDsp.OVERLAP;
        submittedFrames += outputFrames;
        int token = generation.get();
        AtomicInteger count = outstanding;
        count.incrementAndGet();
        Worker target = worker;
        executor.execute(() -> {
            boolean published = false;
            try {
                if (generation.get() != token || failed) return;
                float[] vocals = target.separate(block, token, outputFrames);
                synchronized (ready) {
                    if (generation.get() == token && !failed) {
                        ready.add(vocals);
                        published = true;
                    }
                }
            } catch (Exception | OutOfMemoryError | LinkageError error) {
                synchronized (ready) {
                    if (generation.get() == token) fail(error);
                }
            } finally {
                if (!published) count.decrementAndGet();
            }
        });
    }

    private void fail(Throwable error) {
        synchronized (ready) {
            failed = true;
            outstanding.addAndGet(-ready.size());
            ready.clear();
        }
        Log.e(TAG, "Separation failed; output remains silent", error);
    }

    @Override
    protected void onQueueEndOfStream() { draining = true; }

    @Override
    public ByteBuffer getOutput() {
        ByteBuffer output = super.getOutput();
        if (output.hasRemaining()) return output;
        if (draining && !failed && receivedFrames > submittedFrames && outstanding.get() < 2) {
            submitWindow((int) (receivedFrames - submittedFrames));
        }
        synchronized (ready) {
            float[] vocals = failed ? null : ready.poll();
            int frames = failed ? (int) Math.min(4096, receivedFrames - emittedFrames)
                    : vocals == null ? 0 : vocals.length / 2;
            if (frames == 0) return output;
            ByteBuffer pcm = replaceOutputBuffer(frames * 4);
            for (int i = 0; i < frames * 2; i++) {
                float sample = failed ? 0 : vocals[i];
                pcm.putShort((short) (Math.max(-1, Math.min(1, sample)) * 32767));
            }
            if (!failed) outstanding.decrementAndGet();
            emittedFrames += frames;
            pcm.flip();
        }
        return super.getOutput();
    }

    @Override
    public boolean isEnded() {
        return super.isEnded() && emittedFrames == receivedFrames;
    }

    @Override
    protected void onFlush(StreamMetadata metadata) {
        synchronized (ready) {
            generation.incrementAndGet();
            outstanding.addAndGet(-ready.size());
            ready.clear();
        }
        filled = 0; sourceFrame = receivedFrames = submittedFrames = emittedFrames = 0; nextSample = 0;
        previousLeft = previousRight = 0; failed = false; draining = false;
        java.util.Arrays.fill(input, 0);
        // shortcut: grid is flush-relative; media-zero windows also need pre-seek context samples.
        if (executor == null) {
            worker = new OrtWorker();
            executor = Executors.newSingleThreadExecutor(r -> new Thread(r, "Musicless-ORT"));
        }
    }

    @Override
    protected void onReset() {
        synchronized (ready) {
            generation.incrementAndGet();
            outstanding.addAndGet(-ready.size());
            ready.clear();
            outstanding = new AtomicInteger();
        }
        if (executor != null) {
            Worker old = worker;
            executor.execute(old::close);
            if (executor instanceof ExecutorService) ((ExecutorService) executor).shutdown();
            executor = null; worker = null;
        }
    }

    abstract static class Worker {
        private float[] tail;
        private int lastGeneration = -1;

        abstract float[] infer(float[] block) throws Exception;

        final float[] separate(float[] block, int token, int outputFrames) throws Exception {
            if (lastGeneration != token) { tail = null; lastGeneration = token; }
            float[] output = infer(block);
            for (int i = 0; i < MusiclessDsp.OVERLAP; i++) {
                float rise = (i + .5f) / MusiclessDsp.OVERLAP;
                for (int c = 0; c < 2; c++) {
                    int at = i * 2 + c;
                    if (tail != null) output[at] = tail[at] + output[at] * rise;
                }
            }
            tail = java.util.Arrays.copyOfRange(output, MusiclessDsp.STRIDE * 2, output.length);
            for (int i = 0; i < MusiclessDsp.OVERLAP; i++) {
                float fall = 1 - (i + .5f) / MusiclessDsp.OVERLAP;
                for (int c = 0; c < 2; c++) tail[i * 2 + c] *= fall;
            }
            return java.util.Arrays.copyOf(output, outputFrames * 2);
        }

        void close() {}
    }

    private final class OrtWorker extends Worker {
        final MusiclessDsp dsp = new MusiclessDsp();
        OrtSession session;

        @Override float[] infer(float[] block) throws Exception {
            if (session == null) {
                long start = System.nanoTime();
                // Atomic publication prevents an interrupted copy from becoming a model next run.
                java.io.File model = new java.io.File(context.getCacheDir(), "musicless-3dc5eaf7.onnx");
                if (!model.isFile() || model.length() != 39364042L) {
                    java.io.File partial = java.io.File.createTempFile("musicless-", ".onnx", context.getCacheDir());
                    try {
                        try (java.io.InputStream asset = context.getAssets().open("musicless/spleeter-2stems.onnx");
                                java.io.OutputStream file = new java.io.FileOutputStream(partial)) {
                            byte[] chunk = new byte[16384];
                            for (int count; (count = asset.read(chunk)) != -1;) file.write(chunk, 0, count);
                        }
                        if (!partial.renameTo(model)) throw new java.io.IOException("Model publication failed");
                    } finally { partial.delete(); }
                }
                try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
                    options.setIntraOpNumThreads(1);
                    options.setInterOpNumThreads(1);
                    options.setSymbolicDimensionValue("num_splits", 1);
                    OrtEnvironment environment = OrtEnvironment.getEnvironment();
                    environment.setTelemetry(false);
                    session = environment.createSession(model.getAbsolutePath(), options);
                }
                Log.i(TAG, "Model loaded ms=" + (System.nanoTime() - start) / 1000000);
            }
            long start = System.nanoTime();
            float[][] analysis = dsp.analyze(block);
            float[] output;
            try (OnnxTensor tensor = OnnxTensor.createTensor(OrtEnvironment.getEnvironment(),
                    FloatBuffer.wrap(analysis[1]), new long[] {2, 1, 512, 1024});
                    OrtSession.Result result = session.run(Collections.singletonMap("x", tensor))) {
                float[] mask = new float[2 * MusiclessDsp.FRAMES * MusiclessDsp.BINS];
                ((OnnxTensor) result.get(0)).getFloatBuffer().get(mask);
                output = dsp.synthesize(analysis[0], mask);
            }
            Log.i(TAG, "Window pipeline ms=" + (System.nanoTime() - start) / 1000000);
            return output;
        }

        @Override void close() {
            if (session != null) {
                try { session.close(); } catch (Exception error) { Log.e(TAG, "Close failed", error); }
            }
        }
    }
}
