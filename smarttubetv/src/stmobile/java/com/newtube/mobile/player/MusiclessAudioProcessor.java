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
import java.util.concurrent.atomic.AtomicInteger;
import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

/** Opt-in, bounded, sample-aligned separation experiment. */
final class MusiclessAudioProcessor extends BaseAudioProcessor {
    private static final String TAG = "Musicless";
    static final int FIRST_FRAMES = 64, FIRST_WINDOW = FIRST_FRAMES * MusiclessDsp.HOP;
    static final int FIRST_STRIDE = FIRST_WINDOW - MusiclessDsp.OVERLAP;
    private static final AtomicInteger IDS = new AtomicInteger();
    private final int id = IDS.incrementAndGet();
    private long windowNumber;
    private final Context context;
    private final AtomicInteger generation = new AtomicInteger();
    private AtomicInteger outstanding = new AtomicInteger();
    private final ArrayDeque<float[]> ready = new ArrayDeque<>();
    private float[] input = new float[MusiclessDsp.WINDOW * 2];
    private int filled, window = FIRST_WINDOW;
    private long sourceFrame, receivedFrames, submittedFrames, emittedFrames;
    private double nextSample;
    private float previousLeft, previousRight;
    private volatile boolean failed;
    private boolean draining;
    private Executor executor;
    private Worker worker;
    private boolean acquired;
    private volatile boolean waitingForDownload;
    volatile long inputReadyNs, queueMs, waitModelMs, inferMs;
    void beginHold() { inputReadyNs = 0; queueMs = waitModelMs = inferMs = 0; }

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
        if (waitingForDownload && emittedFrames == receivedFrames
                && MusiclessModels.get(context).status == MusiclessModels.Status.READY) {
            waitingForDownload = failed = false;
            submittedFrames = receivedFrames;
            generation.incrementAndGet();
            filled = 0; window = FIRST_WINDOW;
            java.util.Arrays.fill(input, 0);
        }
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
                    if (++filled == window) submitWindow(window - MusiclessDsp.OVERLAP);
                }
                receivedFrames++;
                nextSample += step;
            }
            previousLeft = left; previousRight = right;
            sourceFrame++;
        }
    }

    private void submitWindow(int outputFrames) {
        if (inputReadyNs == 0) inputReadyNs = System.nanoTime();
        float[] block = window == MusiclessDsp.WINDOW ? input : java.util.Arrays.copyOf(input, window * 2);
        input = new float[MusiclessDsp.WINDOW * 2];
        System.arraycopy(block, block.length - MusiclessDsp.OVERLAP * 2, input, 0, MusiclessDsp.OVERLAP * 2);
        window = MusiclessDsp.WINDOW;
        filled = MusiclessDsp.OVERLAP;
        submittedFrames += outputFrames;
        int token = generation.get();
        AtomicInteger count = outstanding;
        count.incrementAndGet();
        Worker target = worker;
        long submittedNs = System.nanoTime();
        long number = ++windowNumber, endFrame = submittedFrames;
        executor.execute(() -> {
            boolean published = false;
            try {
                if (generation.get() != token || failed) return;
                long queuedMs = (System.nanoTime() - submittedNs) / 1000000;
                float[] vocals = target.separate(block, token, outputFrames);
                queueMs = queuedMs;
                Log.i(TAG, "Window pipeline ms=" + target.pipelineMs + " processor=" + id
                        + " generation=" + token + " window=" + number
                        + " frames=" + block.length / (2 * MusiclessDsp.HOP)
                        + " outputStartFrame=" + (endFrame - outputFrames) + " outputFrames=" + outputFrames
                        + " queueMs=" + queuedMs + " waitModelMs=" + target.modelMs + target.timings
                        + " users=" + (context == null ? 0 : MusiclessModelHolder.get().userCount())
                        + " thread=" + Thread.currentThread().getName()
                        + " priority=" + android.os.Process.getThreadPriority(android.os.Process.myTid())
                        + " main=" + (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()));
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
            waitingForDownload = context != null && MusiclessModels.get(context).status != MusiclessModels.Status.READY;
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

    boolean hasPendingData() { return receivedFrames > emittedFrames; }

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
        filled = 0; window = FIRST_WINDOW;
        sourceFrame = receivedFrames = submittedFrames = emittedFrames = 0; nextSample = 0;
        previousLeft = previousRight = 0; failed = waitingForDownload = false; draining = false;
        java.util.Arrays.fill(input, 0);
        // shortcut: grid is flush-relative; media-zero windows also need pre-seek context samples.
        if (executor == null) {
            worker = new OrtWorker();
            executor = MusiclessModelHolder.get().executor;
        }
        if (context != null && !acquired) {
            MusiclessModelHolder.get().acquire();
            acquired = true;
            Log.i(TAG, "Processor acquire processor=" + id + " users=" + MusiclessModelHolder.get().userCount());
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
            if (context == null && executor instanceof ExecutorService) ((ExecutorService) executor).shutdown();
            executor = null; worker = null;
        }
        if (acquired) {
            MusiclessModelHolder.get().release(); acquired = false;
            Log.i(TAG, "Processor release processor=" + id + " users=" + MusiclessModelHolder.get().userCount());
        }
    }

    abstract static class Worker {
        String timings = "";
        long modelMs, pipelineMs;
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
            tail = java.util.Arrays.copyOfRange(output, output.length - MusiclessDsp.OVERLAP * 2, output.length);
            for (int i = 0; i < MusiclessDsp.OVERLAP; i++) {
                float fall = 1 - (i + .5f) / MusiclessDsp.OVERLAP;
                for (int c = 0; c < 2; c++) tail[i * 2 + c] *= fall;
            }
            return java.util.Arrays.copyOf(output, outputFrames * 2);
        }

        void close() {}
    }

    private final class OrtWorker extends Worker {
        MusiclessDsp fullDsp, firstDsp;
        float[] mask;
        @Override float[] infer(float[] block) throws Exception {
            MusiclessModelHolder holder = MusiclessModelHolder.get();
            long wait = System.nanoTime();
            holder.load(MusiclessModels.get(context));
            waitModelMs = modelMs = (System.nanoTime() - wait) / 1000000;
            OrtSession vocals = holder.vocals, accompaniment = holder.accompaniment;
            long start = System.nanoTime();
            long cpuStart = android.os.Debug.threadCpuTimeNanos();
            int frames = block.length / (2 * MusiclessDsp.HOP);
            MusiclessDsp dsp;
            if (frames == FIRST_FRAMES) {
                if (firstDsp == null) firstDsp = new MusiclessDsp(FIRST_FRAMES);
                dsp = firstDsp;
            } else {
                if (fullDsp == null) fullDsp = new MusiclessDsp();
                dsp = fullDsp;
            }
            long analyzeStart = System.nanoTime();
            float[][] analysis = dsp.analyze(block);
            long analyzeEnd = System.nanoTime(), vocalsNs, accompanimentNs, maskNs;
            if (mask == null || mask.length != analysis[1].length) mask = new float[analysis[1].length];
            try (OnnxTensor tensor = OnnxTensor.createTensor(OrtEnvironment.getEnvironment(),
                    FloatBuffer.wrap(analysis[1]), new long[] {2, 1, frames, MusiclessDsp.BINS})) {
                long runStart = System.nanoTime();
                try (OrtSession.Result result = vocals.run(Collections.singletonMap(vocals.getInputNames().iterator().next(), tensor))) {
                    vocalsNs = System.nanoTime() - runStart;
                    ((OnnxTensor) result.get(0)).getFloatBuffer().get(mask);
                }
                runStart = System.nanoTime();
                try (OrtSession.Result result = accompaniment.run(Collections.singletonMap(accompaniment.getInputNames().iterator().next(), tensor))) {
                    accompanimentNs = System.nanoTime() - runStart;
                    long maskStart = System.nanoTime();
                    FloatBuffer music = ((OnnxTensor) result.get(0)).getFloatBuffer();
                    for (int i = 0; i < mask.length; i++) mask[i] =
                            (mask[i] + 5e-11f) / (mask[i] + 2 * music.get() + 1e-10f);
                    maskNs = System.nanoTime() - maskStart;
                }
            }
            long synthesizeStart = System.nanoTime();
            float[] output = dsp.synthesize(analysis[0], mask);
            long end = System.nanoTime();
            inferMs = pipelineMs = (end - start) / 1000000;
            timings = " analyzeMs=" + (analyzeEnd - analyzeStart) / 1000000
                    + " vocalsMs=" + vocalsNs / 1000000 + " accompanimentMs=" + accompanimentNs / 1000000
                    + " maskMs=" + maskNs / 1000000 + " synthesizeMs=" + (end - synthesizeStart) / 1000000
                    + " otherMs=" + (end - start - (analyzeEnd - analyzeStart) - vocalsNs
                            - accompanimentNs - maskNs - (end - synthesizeStart)) / 1000000
                    + " cpuMs=" + (android.os.Debug.threadCpuTimeNanos() - cpuStart) / 1000000;
            return output;
        }

    }
}
