package com.newtube.mobile.player;

import android.content.Context;
import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.util.ArrayDeque;
import java.util.Collections;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/** Opt-in feasibility experiment, NOT a synchronized playback implementation. */
final class MusiclessAudioProcessor extends BaseAudioProcessor {
    private static final String TAG = "Musicless";
    private final Context context;
    private final AtomicInteger generation = new AtomicInteger();
    private final AtomicInteger pending = new AtomicInteger();
    private final ArrayDeque<float[]> ready = new ArrayDeque<>();
    private float[] input = new float[MusiclessDsp.WINDOW * 2], playing;
    private int filled, playingAt;
    private long sourceFrame;
    private double nextSample;
    private float previousLeft, previousRight;
    private volatile boolean failed;
    private boolean draining;
    private ExecutorService executor;
    private Worker worker;

    MusiclessAudioProcessor(Context context) { this.context = context.getApplicationContext(); }

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
        int frames = buffer.remaining() / inputAudioFormat.bytesPerFrame;
        ByteBuffer out = replaceOutputBuffer((int) Math.ceil((frames + 1.0)
                * MusiclessDsp.RATE / inputAudioFormat.sampleRate) * 4);
        double step = inputAudioFormat.sampleRate / (double) MusiclessDsp.RATE;
        for (int i = 0; i < frames; i++, sourceFrame++) {
            float left = buffer.getShort() / 32768f;
            float right = inputAudioFormat.channelCount == 2 ? buffer.getShort() / 32768f : left;
            while (nextSample <= sourceFrame) {
                double fraction = sourceFrame == 0 ? 1 : nextSample - (sourceFrame - 1);
                float l = (float) (previousLeft + fraction * (left - previousLeft));
                float r = (float) (previousRight + fraction * (right - previousRight));
                input[filled * 2] = l; input[filled * 2 + 1] = r;
                if (++filled == MusiclessDsp.WINDOW) submitWindow();
                // shortcut: silence advances the media clock; add a video/clock hold before shipping.
                synchronized (ready) {
                    if (playing == null && !failed) { playing = ready.poll(); playingAt = 0; }
                    for (int c = 0; c < 2; c++) {
                        float value = playing == null || failed ? 0 : playing[playingAt++];
                        out.putShort((short) (Math.max(-1, Math.min(1, value)) * 32767));
                    }
                    if (playing != null && playingAt == playing.length) playing = null;
                }
                nextSample += step;
            }
            previousLeft = left; previousRight = right;
        }
        out.flip();
    }

    private void submitWindow() { submitWindow(MusiclessDsp.STRIDE); }

    private void submitWindow(int outputFrames) {
        float[] block = input;
        input = new float[MusiclessDsp.WINDOW * 2];
        System.arraycopy(block, MusiclessDsp.STRIDE * 2, input, 0, MusiclessDsp.OVERLAP * 2);
        filled = MusiclessDsp.OVERLAP;
        if (failed) return;
        if (pending.incrementAndGet() > 2) {
            pending.decrementAndGet();
            fail("CPU cannot keep up; bounded inference queue full", null);
            return;
        }
        int token = generation.get();
        Worker target = worker;
        executor.execute(() -> {
            try {
                if (generation.get() != token || failed) return;
                float[] vocals = target.separate(block, token, outputFrames);
                synchronized (ready) {
                    if (generation.get() != token || failed) return;
                    if (ready.size() >= 2) { fail("Output queue full", null); return; }
                    ready.add(vocals);
                }
            } catch (Exception | OutOfMemoryError | LinkageError error) {
                if (generation.get() == token) fail("Separation failed; output remains silent", error);
            } finally { pending.decrementAndGet(); }
        });
    }

    private void fail(String message, Throwable error) {
        failed = true;
        synchronized (ready) { ready.clear(); playing = null; }
        Log.e(TAG, message, error);
    }

    @Override
    protected void onQueueEndOfStream() {
        draining = true;
        if (filled > 0 && !failed) submitWindow(filled);
    }

    @Override
    public ByteBuffer getOutput() {
        ByteBuffer output = super.getOutput();
        if (output.hasRemaining() || !draining || failed) return output;
        synchronized (ready) {
            if (playing == null) { playing = ready.poll(); playingAt = 0; }
            if (playing == null) return output;
            ByteBuffer tail = replaceOutputBuffer((playing.length - playingAt) * 2);
            while (playingAt < playing.length) {
                float sample = playing[playingAt++];
                tail.putShort((short) (Math.max(-1, Math.min(1, sample)) * 32767));
            }
            playing = null;
            tail.flip();
        }
        return super.getOutput();
    }

    @Override
    public boolean isEnded() {
        synchronized (ready) {
            return super.isEnded() && (failed || (pending.get() == 0
                    && ready.isEmpty() && playing == null));
        }
    }

    @Override
    protected void onFlush() {
        generation.incrementAndGet();
        synchronized (ready) { ready.clear(); playing = null; }
        filled = playingAt = 0; sourceFrame = 0; nextSample = 0;
        previousLeft = previousRight = 0; failed = false; draining = false;
        java.util.Arrays.fill(input, 0);
        if (executor == null) {
            worker = new Worker();
            executor = Executors.newSingleThreadExecutor(r -> new Thread(r, "Musicless-ORT"));
        }
    }

    @Override
    protected void onReset() {
        generation.incrementAndGet();
        synchronized (ready) { ready.clear(); playing = null; }
        if (executor != null) {
            Worker old = worker;
            executor.execute(old::close);
            executor.shutdown();
            executor = null; worker = null;
        }
    }

    private final class Worker {
        final MusiclessDsp dsp = new MusiclessDsp();
        OrtSession session;
        float[] tail;
        int lastGeneration = -1;

        float[] separate(float[] block, int token, int outputFrames) throws Exception {
            if (session == null) {
                long start = System.nanoTime();
                try (java.io.InputStream asset = context.getAssets().open("musicless/spleeter-2stems.onnx");
                        OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
                    options.setIntraOpNumThreads(1);
                    options.setInterOpNumThreads(1);
                    options.setSymbolicDimensionValue("num_splits", 1);
                    java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
                    byte[] chunk = new byte[16384];
                    for (int count; (count = asset.read(chunk)) != -1;) bytes.write(chunk, 0, count);
                    OrtEnvironment environment = OrtEnvironment.getEnvironment();
                    environment.setTelemetry(false);
                    session = environment.createSession(bytes.toByteArray(), options);
                }
                Log.i(TAG, "Model loaded ms=" + (System.nanoTime() - start) / 1000000);
            }
            if (lastGeneration != token) { tail = null; lastGeneration = token; }
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
            for (int i = 0; i < MusiclessDsp.OVERLAP; i++) {
                float rise = (i + .5f) / MusiclessDsp.OVERLAP;
                for (int c = 0; c < 2; c++) {
                    int at = i * 2 + c;
                    if (tail != null) output[at] = tail[at] + output[at] * rise;
                    output[MusiclessDsp.STRIDE * 2 + at] *= 1 - rise;
                }
            }
            tail = java.util.Arrays.copyOfRange(output, MusiclessDsp.STRIDE * 2, output.length);
            Log.i(TAG, "Window pipeline ms=" + (System.nanoTime() - start) / 1000000);
            return java.util.Arrays.copyOf(output, outputFrames * 2);
        }

        void close() {
            if (session != null) {
                try { session.close(); } catch (Exception error) { Log.e(TAG, "Close failed", error); }
            }
        }
    }
}
