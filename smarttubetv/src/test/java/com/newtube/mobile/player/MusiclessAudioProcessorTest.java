package com.newtube.mobile.player;

import android.content.Context;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.ConscryptMode;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, application = android.app.Application.class)
@ConscryptMode(ConscryptMode.Mode.OFF)
public class MusiclessAudioProcessorTest {
    @Test public void optInSinkRefusesPassthroughAndOffload() {
        MusiclessPrefs.setOn(RuntimeEnvironment.getApplication(), true);
        try {
            androidx.media3.exoplayer.audio.AudioSink sink =
                    new Media3PlayerInitializer.PrerollRenderersFactory(
                            RuntimeEnvironment.getApplication(), true)
                            .buildAudioSink(RuntimeEnvironment.getApplication(), false, false);
            androidx.media3.common.Format aac = new androidx.media3.common.Format.Builder()
                    .setSampleMimeType("audio/mp4a-latm").setSampleRate(48000).setChannelCount(2).build();
            assertFalse(sink.supportsFormat(aac));
            assertEquals(androidx.media3.exoplayer.audio.AudioSink.SINK_FORMAT_UNSUPPORTED,
                    sink.getFormatSupport(aac));
            assertSame(androidx.media3.exoplayer.audio.AudioOffloadSupport.DEFAULT_UNSUPPORTED,
                    sink.getFormatOffloadSupport(aac));
            // MediaCodecAudioRenderer asks with the manifest channel count, which DASH/SABR leave unset.
            assertTrue(sink.supportsFormat(androidx.media3.common.util.Util.getPcmFormat(
                    C.ENCODING_PCM_16BIT, androidx.media3.common.Format.NO_VALUE, 48000)));
            sink.reset();
        } finally {
            MusiclessPrefs.setOn(RuntimeEnvironment.getApplication(), false);
        }
    }

    @Test public void buffersPcmAndResamplesWithoutLeakingOriginalAudio() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        MusiclessAudioProcessor processor = new MusiclessAudioProcessor(context);
        AudioFormat output = processor.configure(new AudioFormat(48000, 2, C.ENCODING_PCM_16BIT));
        assertEquals(44100, output.sampleRate);
        assertEquals(2, output.channelCount);
        processor.flush();
        ByteBuffer pcm = ByteBuffer.allocateDirect(4800 * 4).order(ByteOrder.nativeOrder());
        while (pcm.hasRemaining()) pcm.putShort((short) 10000);
        pcm.flip();
        processor.queueInput(pcm);
        assertFalse(pcm.hasRemaining());
        assertFalse(processor.getOutput().hasRemaining());
        processor.flush();
        assertFalse(processor.getOutput().hasRemaining());
        processor.reset();
    }

    @Test public void acquisitionFailureStaysSilentAndReadyRetryRearmsSeparation() throws Exception {
        Context context = RuntimeEnvironment.getApplication();
        MusiclessModels models = MusiclessModels.get(context);
        MusiclessModels.Status previous = models.status;
        MusiclessAudioProcessor processor = new MusiclessAudioProcessor(context);
        try {
            models.status = MusiclessModels.Status.FAILED;
            processor.configure(new AudioFormat(44100, 2, C.ENCODING_PCM_16BIT));
            processor.flush();
            processor.queueInput(pcm(MusiclessAudioProcessor.FIRST_WINDOW, 0));
            MusiclessModelHolder.get().executor.submit(() -> {}).get(5, java.util.concurrent.TimeUnit.SECONDS);
            int frames = 0;
            for (ByteBuffer silence; (silence = processor.getOutput()).hasRemaining();) {
                frames += silence.remaining() / 4;
                while (silence.hasRemaining()) assertEquals(0, silence.getShort());
            }
            assertEquals(MusiclessAudioProcessor.FIRST_WINDOW, frames);
            models.status = MusiclessModels.Status.READY;
            processor.queueInput(pcm(100, MusiclessAudioProcessor.FIRST_WINDOW));
            assertFalse("READY retry collects a fresh window, not permanent failure silence",
                    processor.getOutput().hasRemaining());
        } finally {
            processor.reset();
            models.status = previous;
        }
    }

    @Test public void sinkPublishesHoldAndClearsItOnSeekAndRelease() throws Exception {
        java.util.ArrayList<Boolean> holds = new java.util.ArrayList<>();
        MusiclessHold.Listener listener = holds::add;
        MusiclessHold.addListener(listener);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        MusiclessAudioSink sink = new MusiclessAudioSink(new Track().sink,
                new MusiclessAudioProcessor(identity(), Runnable::run));
        sink.configure(new androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
                .setPcmEncoding(C.ENCODING_PCM_16BIT).setSampleRate(44100).setChannelCount(2).build(), 0, null);
        sink.handleBuffer(pcm(100, 0), 0, 1);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(Boolean.TRUE, holds.get(holds.size() - 1));
        sink.flush();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(Boolean.FALSE, holds.get(holds.size() - 1));
        sink.handleBuffer(pcm(100, 0), 2000000, 1);
        sink.release();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(Boolean.FALSE, holds.get(holds.size() - 1));
        MusiclessHold.removeListener(listener);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
    }

    @Test public void holdIncludesOutputWaitingForItsFirstTrackWrite() throws Exception {
        java.util.ArrayList<Boolean> holds = new java.util.ArrayList<>();
        MusiclessHold.Listener listener = holds::add;
        MusiclessHold.addListener(listener);
        Track track = new Track();
        track.blocked = true;
        MusiclessAudioSink sink = new MusiclessAudioSink(track.sink,
                new MusiclessAudioProcessor(identity(), Runnable::run));
        sink.configure(new androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
                .setPcmEncoding(C.ENCODING_PCM_16BIT).setSampleRate(44100).setChannelCount(2).build(), 0, null);
        try {
            sink.handleBuffer(pcm(MusiclessAudioProcessor.FIRST_WINDOW, 0), 0, 1);
            sink.hasPendingData();
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
            assertEquals(Boolean.TRUE, holds.get(holds.size() - 1));
        } finally {
            sink.reset();
            MusiclessHold.removeListener(listener);
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        }
    }

    private static MusiclessAudioProcessor.Worker identity() {
        return new MusiclessAudioProcessor.Worker() {
            @Override float[] infer(float[] block) { return block.clone(); }
        };
    }

    private static MusiclessAudioProcessor configured(MusiclessAudioProcessor.Worker worker,
            java.util.concurrent.Executor executor) throws Exception {
        MusiclessAudioProcessor processor = new MusiclessAudioProcessor(worker, executor);
        processor.configure(new AudioFormat(44100, 2, C.ENCODING_PCM_16BIT));
        processor.flush();
        return processor;
    }

    private static ByteBuffer pcm(int frames, int offset) {
        ByteBuffer pcm = ByteBuffer.allocateDirect(frames * 4).order(ByteOrder.nativeOrder());
        for (int i = 0; i < frames; i++) {
            pcm.putShort((short) (9000 * Math.sin(2 * Math.PI * 440 * (offset + i) / 44100)));
            pcm.putShort((short) (6000 * Math.sin(2 * Math.PI * 880 * (offset + i) / 44100)));
        }
        pcm.flip();
        return pcm;
    }

    @Test public void holdsUntilWorkerCompletesAndFullQueueBackpressures() throws Exception {
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioProcessor processor = configured(identity(), jobs::add);
        processor.queueInput(pcm(MusiclessAudioProcessor.FIRST_WINDOW - 1, 0));
        assertTrue(jobs.isEmpty());
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueInput(pcm(1, MusiclessAudioProcessor.FIRST_WINDOW - 1));
        assertEquals(1, jobs.size());
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueInput(pcm(MusiclessDsp.STRIDE, MusiclessDsp.WINDOW));
        ByteBuffer blocked = pcm(10, 0);
        processor.queueInput(blocked);
        assertEquals(0, blocked.position());
        assertFalse(processor.getOutput().hasRemaining());
        jobs.remove().run();
        ByteBuffer vocals = processor.getOutput();
        assertEquals(MusiclessAudioProcessor.FIRST_STRIDE * 4, vocals.remaining());
        vocals.position(vocals.limit());
        processor.queueInput(blocked);
        assertFalse(blocked.hasRemaining());
        processor.reset();
        while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void repeatedFlushCannotAccumulateUnboundedStaleJobs() throws Exception {
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioProcessor processor = configured(identity(), jobs::add);
        processor.queueInput(pcm(MusiclessDsp.WINDOW + MusiclessDsp.STRIDE, 0));
        assertEquals(2, jobs.size());
        for (int seek = 0; seek < 10; seek++) {
            processor.flush();
            ByteBuffer input = pcm(1, 0);
            processor.queueInput(input);
            assertEquals(0, input.position());
            assertEquals(2, jobs.size());
        }
        while (!jobs.isEmpty()) jobs.remove().run();
        ByteBuffer input = pcm(1, 0);
        processor.queueInput(input);
        assertFalse(input.hasRemaining());
        processor.reset();
        while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void identityOutputHasExactlyOneFramePerInputWithoutShiftOrDuplicateEofOverlap() throws Exception {
        checkAlignment(identity(), 1);
    }

    @Test public void unityMaskOutputMatchesSameInputSampleWithinLowPassDspTolerance() throws Exception {
        checkAlignment(new MusiclessAudioProcessor.Worker() {
            @Override float[] infer(float[] block) {
                MusiclessDsp dsp = new MusiclessDsp(block.length / (2 * MusiclessDsp.HOP));
                float[][] analysis = dsp.analyze(block);
                java.util.Arrays.fill(analysis[1], 1);
                return dsp.synthesize(analysis[0], analysis[1]);
            }
        }, 250);
    }

    private static void checkAlignment(MusiclessAudioProcessor.Worker worker, int tolerance) throws Exception {
        MusiclessAudioProcessor processor = configured(worker, Runnable::run);
        int frames = MusiclessDsp.WINDOW + MusiclessDsp.STRIDE + 123;
        ByteBuffer source = pcm(frames, 0);
        // Avoid testing a brick-wall low-pass against the artificial discontinuity into EOF zeros.
        for (int i = 0; i < 4096; i++) {
            int at = (frames - 4096 + i) * 4;
            for (int c = 0; c < 2; c++) {
                source.putShort(at + c * 2, (short) (source.getShort(at + c * 2) * (4095 - i) / 4096));
            }
        }
        ByteBuffer expected = source.duplicate().order(ByteOrder.nativeOrder());
        int samples = 0;
        while (source.hasRemaining()) {
            processor.queueInput(source);
            samples += compare(processor.getOutput(), expected, tolerance);
        }
        processor.queueEndOfStream();
        while (!processor.isEnded()) samples += compare(processor.getOutput(), expected, tolerance);
        assertEquals(frames * 2, samples);
        assertFalse(expected.hasRemaining());
        processor.reset();
    }

    private static int compare(ByteBuffer output, ByteBuffer expected, int tolerance) {
        int samples = output.remaining() / 2;
        while (output.hasRemaining()) {
            assertTrue("No extra frames", expected.hasRemaining());
            assertEquals(expected.getShort(), output.getShort(), tolerance);
        }
        return samples;
    }

    @Test public void media3ClockHoldIsNotGuaranteedAfterRendererReadsEof() throws Exception {
        androidx.media3.exoplayer.MediaClock audioClock = new androidx.media3.exoplayer.MediaClock() {
            @Override public long getPositionUs() { return 0; }
            @Override public boolean hasSkippedSilenceSinceLastCall() { return false; }
            @Override public void setPlaybackParameters(androidx.media3.common.PlaybackParameters p) {}
            @Override public androidx.media3.common.PlaybackParameters getPlaybackParameters() {
                return androidx.media3.common.PlaybackParameters.DEFAULT;
            }
        };
        boolean[] eof = {false};
        androidx.media3.exoplayer.Renderer renderer = (androidx.media3.exoplayer.Renderer)
                java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                        new Class<?>[] {androidx.media3.exoplayer.Renderer.class}, (proxy, method, args) -> {
                            switch (method.getName()) {
                                case "getMediaClock": return audioClock;
                                case "hasReadStreamToEnd": return eof[0];
                                case "getState": return androidx.media3.exoplayer.Renderer.STATE_STARTED;
                            }
                            if (method.getReturnType() == boolean.class) return false;
                            return null;
                        });
        // Test the actual pinned library, not a copy of its clock-selection condition.
        Class<?> type = Class.forName("androidx.media3.exoplayer.DefaultMediaClock");
        Class<?> listenerType = Class.forName("androidx.media3.exoplayer.DefaultMediaClock$PlaybackParametersListener");
        Object listener = java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                new Class<?>[] {listenerType}, (proxy, method, args) -> null);
        java.lang.reflect.Constructor<?> constructor = type.getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        Object clock = constructor.newInstance(listener, androidx.media3.common.util.Clock.DEFAULT);
        java.lang.reflect.Method enable = type.getDeclaredMethod("onRendererEnabled", androidx.media3.exoplayer.Renderer.class);
        java.lang.reflect.Method start = type.getDeclaredMethod("start");
        java.lang.reflect.Method sync = type.getDeclaredMethod("syncAndGetPositionUs", boolean.class);
        enable.setAccessible(true); start.setAccessible(true); sync.setAccessible(true);
        enable.invoke(clock, renderer);
        start.invoke(clock);
        assertEquals(0L, sync.invoke(clock, false));
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(12));
        assertEquals("Unready audio holds before EOF", 0L, sync.invoke(clock, false));
        eof[0] = true;
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(1));
        assertTrue("EOF falls back to an advancing standalone clock", (Long) sync.invoke(clock, false) > 0);
    }

    @Test public void resamplingDrainsExactlyTheConvertedFrameCount() throws Exception {
        MusiclessAudioProcessor processor = new MusiclessAudioProcessor(identity(), Runnable::run);
        processor.configure(new AudioFormat(48000, 1, C.ENCODING_PCM_16BIT));
        processor.flush();
        ByteBuffer input = ByteBuffer.allocateDirect(4800 * 2).order(ByteOrder.nativeOrder());
        processor.queueInput(input);
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueEndOfStream();
        ByteBuffer output = processor.getOutput();
        assertEquals(4410 * 4, output.remaining());
        output.position(output.limit());
        assertTrue(processor.isEnded());
        processor.reset();
    }

    @Test(timeout = 10000) public void sinkBackpressureReturnsWithoutSpinningAndKeepsOutputTimestamps() throws Exception {
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        java.util.ArrayList<Long> times = new java.util.ArrayList<>();
        int[] written = {0};
        boolean[] ended = {false};
        androidx.media3.exoplayer.audio.AudioSink track = (androidx.media3.exoplayer.audio.AudioSink)
                java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                        new Class<?>[] {androidx.media3.exoplayer.audio.AudioSink.class}, (proxy, method, args) -> {
                            switch (method.getName()) {
                                case "handleBuffer":
                                    ByteBuffer output = (ByteBuffer) args[0];
                                    written[0] += output.remaining() / 4;
                                    times.add((Long) args[1]);
                                    output.position(output.limit());
                                    return true;
                                case "isEnded": return ended[0];
                                case "playToEndOfStream": ended[0] = true; break;
                            }
                            if (method.getReturnType() == boolean.class) return false;
                            if (method.getReturnType() == int.class) return 0;
                            if (method.getReturnType() == long.class) return 0L;
                            return null;
                        });
        MusiclessAudioSink sink = new MusiclessAudioSink(track,
                new MusiclessAudioProcessor(identity(), jobs::add));
        sink.configure(new androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
                .setPcmEncoding(C.ENCODING_PCM_16BIT).setSampleRate(44100).setChannelCount(2).build(), 0, null);
        int frames = MusiclessDsp.WINDOW + MusiclessDsp.STRIDE + 17;
        ByteBuffer input = pcm(frames, 0);
        long startUs = 1234567;
        assertFalse(sink.handleBuffer(input, startUs, 1));
        assertEquals(0, written[0]);
        int heldPosition = input.position();
        assertFalse(sink.handleBuffer(input, startUs, 1));
        assertEquals(heldPosition, input.position());
        jobs.remove().run();
        assertTrue(sink.handleBuffer(input, startUs, 1));
        assertEquals(startUs, (long) times.get(0));
        sink.playToEndOfStream();
        while (!jobs.isEmpty()) jobs.remove().run();
        sink.playToEndOfStream();
        assertEquals(frames, written[0]);
        assertEquals(startUs + MusiclessAudioProcessor.FIRST_STRIDE * 1000000L / MusiclessDsp.RATE, (long) times.get(1));
        assertTrue(sink.isEnded());
        sink.reset();
        while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void blockedTrackStillAcceptsTwoWindowsAhead() throws Exception {
        Track track = new Track();
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioSink sink = sink(track, jobs);
        try {
            sink.handleBuffer(pcm(MusiclessAudioProcessor.FIRST_WINDOW, 0), 0, 1);
            jobs.remove().run();
            track.blocked = true;
            ByteBuffer ahead = pcm(3 * MusiclessDsp.STRIDE, MusiclessAudioProcessor.FIRST_WINDOW);
            assertFalse(sink.handleBuffer(ahead, MusiclessAudioProcessor.FIRST_WINDOW * 1000000L / 44100, 1));
            assertEquals("Pending output must not gate input look-ahead", 2 * MusiclessDsp.STRIDE * 4, ahead.position());
            assertEquals(2, jobs.size());
            int position = ahead.position();
            sink.handleBuffer(ahead, MusiclessAudioProcessor.FIRST_WINDOW * 1000000L / 44100, 1);
            assertEquals("Look-ahead remains bounded", position, ahead.position());
        } finally { sink.reset(); while (!jobs.isEmpty()) jobs.remove().run(); }
    }

    @Test public void fixedLatencyWorkerHasNoSteadyPlaybackUnderrunHolds() throws Exception {
        int[] tick = {0}, queuedFrames = {0}, workerAvailable = {0};
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        java.util.ArrayDeque<Integer> due = new java.util.ArrayDeque<>();
        java.util.ArrayList<Boolean> holds = new java.util.ArrayList<>();
        MusiclessHold.Listener listener = holds::add;
        MusiclessHold.addListener(listener);
        androidx.media3.exoplayer.audio.AudioSink track = (androidx.media3.exoplayer.audio.AudioSink)
                java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                        new Class<?>[] {androidx.media3.exoplayer.audio.AudioSink.class}, (proxy, method, args) -> {
                            if (method.getName().equals("hasPendingData")) return queuedFrames[0] > 0;
                            if (method.getName().equals("handleBuffer")) {
                                ByteBuffer buffer = (ByteBuffer) args[0];
                                int frames = Math.min(buffer.remaining() / 4, 4410 - queuedFrames[0]);
                                buffer.position(buffer.position() + frames * 4);
                                queuedFrames[0] += frames;
                                return !buffer.hasRemaining();
                            }
                            if (method.getReturnType() == boolean.class) return false;
                            if (method.getReturnType() == int.class) return 0;
                            if (method.getReturnType() == long.class) return 0L;
                            return null;
                        });
        MusiclessAudioSink sink = new MusiclessAudioSink(track, new MusiclessAudioProcessor(identity(), job -> {
            jobs.add(job);
            workerAvailable[0] = Math.max(tick[0], workerAvailable[0]) + 50; // 500 ms per window.
            due.add(workerAvailable[0]);
        }));
        sink.configure(new androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
                .setPcmEncoding(C.ENCODING_PCM_16BIT).setSampleRate(44100).setChannelCount(2).build(), 0, null);
        ByteBuffer input = ByteBuffer.allocateDirect(6 * MusiclessDsp.WINDOW * 4).order(ByteOrder.nativeOrder());
        try {
            for (; tick[0] < 5000; tick[0]++) {
                queuedFrames[0] = Math.max(0, queuedFrames[0] - 441); // 10 ms of playback.
                while (!due.isEmpty() && due.peek() <= tick[0]) { due.remove(); jobs.remove().run(); }
                sink.handleBuffer(input, 0, 1);
                sink.hasPendingData();
                org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
            }
            assertEquals("One start hold, no underrun holds during 50 s playback", 1,
                    java.util.Collections.frequency(holds, Boolean.TRUE));
            assertTrue("Played more than four full windows", input.position() > 4 * MusiclessDsp.WINDOW * 4);
        } finally {
            sink.reset();
            while (!jobs.isEmpty()) jobs.remove().run();
            MusiclessHold.removeListener(listener);
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        }
    }

    private static final class Track {
        final java.io.ByteArrayOutputStream pcm = new java.io.ByteArrayOutputStream();
        final java.util.ArrayList<Long> times = new java.util.ArrayList<>();
        boolean ended, blocked;
        int discontinuities;
        androidx.media3.common.PlaybackParameters parameters = androidx.media3.common.PlaybackParameters.DEFAULT;
        final androidx.media3.exoplayer.audio.AudioSink sink = (androidx.media3.exoplayer.audio.AudioSink)
                java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                        new Class<?>[] {androidx.media3.exoplayer.audio.AudioSink.class}, (proxy, method, args) -> {
                            switch (method.getName()) {
                                case "handleBuffer":
                                    if (blocked) return false;
                                    ByteBuffer buffer = (ByteBuffer) args[0];
                                    times.add((Long) args[1]);
                                    while (buffer.hasRemaining()) pcm.write(buffer.get());
                                    return true;
                                case "playToEndOfStream": ended = true; break;
                                case "isEnded": return ended;
                                case "handleDiscontinuity": discontinuities++; break;
                                case "setPlaybackParameters": parameters = (androidx.media3.common.PlaybackParameters) args[0]; break;
                                case "getPlaybackParameters": return parameters;
                                case "flush": pcm.reset(); times.clear(); ended = false; break;
                            }
                            if (method.getReturnType() == boolean.class) return false;
                            if (method.getReturnType() == int.class) return 0;
                            if (method.getReturnType() == long.class) return 0L;
                            return null;
                        });
    }

    private static MusiclessAudioSink sink(Track track, java.util.ArrayDeque<Runnable> jobs) throws Exception {
        MusiclessAudioSink sink = new MusiclessAudioSink(track.sink,
                new MusiclessAudioProcessor(identity(), jobs::add));
        sink.configure(new androidx.media3.common.Format.Builder().setSampleMimeType("audio/raw")
                .setPcmEncoding(C.ENCODING_PCM_16BIT).setSampleRate(44100).setChannelCount(2).build(), 0, null);
        return sink;
    }

    @Test public void pendingMusiclessKeepsRealMedia3AudioClockAtEofIncludingPartialWrite() throws Exception {
        Track track = new Track();
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioSink sink = sink(track, jobs);
        assertTrue(sink.handleBuffer(pcm(123, 0), 0, 1));
        assertTrue("Read-stream EOF can precede sink EOS", sink.hasPendingData());
        androidx.media3.exoplayer.MediaClock audioClock = new androidx.media3.exoplayer.MediaClock() {
            @Override public long getPositionUs() { return 0; }
            @Override public boolean hasSkippedSilenceSinceLastCall() { return false; }
            @Override public void setPlaybackParameters(androidx.media3.common.PlaybackParameters p) {}
            @Override public androidx.media3.common.PlaybackParameters getPlaybackParameters() {
                return androidx.media3.common.PlaybackParameters.DEFAULT;
            }
        };
        androidx.media3.exoplayer.Renderer renderer = (androidx.media3.exoplayer.Renderer)
                java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                        new Class<?>[] {androidx.media3.exoplayer.Renderer.class}, (proxy, method, args) -> {
                            switch (method.getName()) {
                                case "getMediaClock": return audioClock;
                                case "hasReadStreamToEnd": return true;
                                case "isReady": return sink.hasPendingData();
                                case "isEnded": return sink.isEnded();
                                case "getState": return androidx.media3.exoplayer.Renderer.STATE_STARTED;
                            }
                            if (method.getReturnType() == boolean.class) return false;
                            return null;
                        });
        Class<?> type = Class.forName("androidx.media3.exoplayer.DefaultMediaClock");
        Class<?> listenerType = Class.forName("androidx.media3.exoplayer.DefaultMediaClock$PlaybackParametersListener");
        Object listener = java.lang.reflect.Proxy.newProxyInstance(getClass().getClassLoader(),
                new Class<?>[] {listenerType}, (proxy, method, args) -> null);
        java.lang.reflect.Constructor<?> constructor = type.getDeclaredConstructors()[0];
        constructor.setAccessible(true);
        Object clock = constructor.newInstance(listener, androidx.media3.common.util.Clock.DEFAULT);
        java.lang.reflect.Method enable = type.getDeclaredMethod("onRendererEnabled", androidx.media3.exoplayer.Renderer.class);
        java.lang.reflect.Method start = type.getDeclaredMethod("start");
        java.lang.reflect.Method sync = type.getDeclaredMethod("syncAndGetPositionUs", boolean.class);
        enable.setAccessible(true); start.setAccessible(true); sync.setAccessible(true);
        enable.invoke(clock, renderer); start.invoke(clock);
        assertEquals(0L, sync.invoke(clock, false));
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(12));
        assertEquals("Read-stream EOF must not switch to standalone even before sink EOS", 0L, sync.invoke(clock, false));
        sink.playToEndOfStream();
        assertTrue(sink.hasPendingData());
        jobs.remove().run(); track.blocked = true;
        sink.playToEndOfStream();
        assertTrue("Still pending after getOutput but before writing", sink.hasPendingData());
        assertFalse(sink.isEnded());
        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(12));
        assertEquals(0L, sync.invoke(clock, false));
        track.blocked = false; sink.playToEndOfStream();
        assertEquals(123 * 4, track.pcm.size());
        assertFalse(sink.hasPendingData()); assertTrue(sink.isEnded());
        sink.reset(); while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void speedChangeMidWindowPreservesMediaRateVocalsForRealSonic() throws Exception {
        Track track = new Track();
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioSink sink = sink(track, jobs);
        int frames = MusiclessAudioProcessor.FIRST_WINDOW;
        assertTrue(sink.handleBuffer(pcm(frames / 2, 0), 0, 1));
        sink.setPlaybackParameters(new androidx.media3.common.PlaybackParameters(1.5f));
        assertEquals(1.5f, track.parameters.speed, 0);
        assertEquals(0, track.pcm.size());
        assertTrue(sink.handleBuffer(pcm(frames / 2, frames / 2), frames / 2 * 1000000L / 44100, 1));
        assertEquals(0, track.pcm.size());
        sink.playToEndOfStream();
        while (!jobs.isEmpty()) jobs.remove().run();
        sink.playToEndOfStream();
        assertEquals(frames * 4, track.pcm.size());
        ByteBuffer mediaRate = ByteBuffer.wrap(track.pcm.toByteArray()).order(ByteOrder.nativeOrder());
        compare(mediaRate.duplicate().order(ByteOrder.nativeOrder()), pcm(frames, 0), 1);
        androidx.media3.common.audio.SonicAudioProcessor sonic = new androidx.media3.common.audio.SonicAudioProcessor();
        sonic.setSpeed(track.parameters.speed);
        sonic.configure(new AudioFormat(44100, 2, C.ENCODING_PCM_16BIT));
        sonic.flush(androidx.media3.common.audio.AudioProcessor.StreamMetadata.DEFAULT);
        sonic.queueInput(mediaRate); sonic.queueEndOfStream();
        assertEquals(frames / 1.5, sonic.getOutput().remaining() / 4, 2);
        sink.reset(); while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void timestampAndExplicitDiscontinuitiesDrainOldWindowBeforeStartingNewHold() throws Exception {
        for (boolean explicit : new boolean[] {false, true}) {
            Track track = new Track();
            java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
            MusiclessAudioSink sink = sink(track, jobs);
            assertTrue(sink.handleBuffer(pcm(123, 0), 1000000, 1));
            if (explicit) sink.handleDiscontinuity();
            long nextUs = explicit ? 1000000 + 123 * 1000000L / 44100 : 5000000;
            ByteBuffer next = pcm(456, 123);
            assertFalse(sink.handleBuffer(next, nextUs, 1));
            assertEquals(0, next.position());
            jobs.remove().run();
            assertTrue(sink.handleBuffer(next, nextUs, 1));
            assertEquals(123 * 4, track.pcm.size());
            assertEquals(1, track.discontinuities);
            assertEquals(1000000L, (long) track.times.get(0));
            sink.playToEndOfStream(); while (!jobs.isEmpty()) jobs.remove().run(); sink.playToEndOfStream();
            assertEquals(nextUs, (long) track.times.get(1));
            compare(ByteBuffer.wrap(track.pcm.toByteArray()).order(ByteOrder.nativeOrder()), pcm(579, 0), 1);
            sink.flush();
            assertTrue(sink.handleBuffer(pcm(17, 0), 9000000, 1));
            assertEquals(0, track.pcm.size());
            sink.playToEndOfStream(); while (!jobs.isEmpty()) jobs.remove().run(); sink.playToEndOfStream();
            assertEquals(9000000L, (long) track.times.get(0));
            assertEquals(17 * 4, track.pcm.size());
            sink.reset(); while (!jobs.isEmpty()) jobs.remove().run();
        }
    }

    @Test public void flushDiscardsInFlightWorkAndErrorsStaySilentWithSameLength() throws Exception {
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioProcessor processor = configured(new MusiclessAudioProcessor.Worker() {
            @Override float[] infer(float[] block) { throw new IllegalStateException("test failure"); }
        }, jobs::add);
        processor.queueInput(pcm(MusiclessAudioProcessor.FIRST_WINDOW, 0));
        processor.flush();
        jobs.remove().run();
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueInput(pcm(123, 0));
        processor.queueEndOfStream();
        assertFalse(processor.getOutput().hasRemaining());
        jobs.remove().run();
        ByteBuffer silence = processor.getOutput();
        assertEquals(123 * 4, silence.remaining());
        while (silence.hasRemaining()) assertEquals(0, silence.getShort());
        assertTrue(processor.isEnded());
        processor.reset();
        while (!jobs.isEmpty()) jobs.remove().run();
    }
}
