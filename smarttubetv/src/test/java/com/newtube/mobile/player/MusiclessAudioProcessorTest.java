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
        org.robolectric.shadows.ShadowSystemProperties.override("debug.arc.remove_music", "1");
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
            sink.reset();
        } finally {
            org.robolectric.shadows.ShadowSystemProperties.override("debug.arc.remove_music", "");
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
        processor.queueInput(pcm(MusiclessDsp.WINDOW - 1, 0));
        assertTrue(jobs.isEmpty());
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueInput(pcm(1, MusiclessDsp.WINDOW - 1));
        assertEquals(1, jobs.size());
        assertFalse(processor.getOutput().hasRemaining());
        processor.queueInput(pcm(MusiclessDsp.STRIDE, MusiclessDsp.WINDOW));
        ByteBuffer blocked = pcm(10, 0);
        processor.queueInput(blocked);
        assertEquals(0, blocked.position());
        assertFalse(processor.getOutput().hasRemaining());
        jobs.remove().run();
        ByteBuffer vocals = processor.getOutput();
        assertEquals(MusiclessDsp.STRIDE * 4, vocals.remaining());
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
        MusiclessDsp dsp = new MusiclessDsp();
        checkAlignment(new MusiclessAudioProcessor.Worker() {
            @Override float[] infer(float[] block) {
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
        assertEquals(startUs + MusiclessDsp.STRIDE * 1000000L / MusiclessDsp.RATE, (long) times.get(1));
        assertTrue(sink.isEnded());
        sink.reset();
        while (!jobs.isEmpty()) jobs.remove().run();
    }

    @Test public void flushDiscardsInFlightWorkAndErrorsStaySilentWithSameLength() throws Exception {
        java.util.ArrayDeque<Runnable> jobs = new java.util.ArrayDeque<>();
        MusiclessAudioProcessor processor = configured(new MusiclessAudioProcessor.Worker() {
            @Override float[] infer(float[] block) { throw new IllegalStateException("test failure"); }
        }, jobs::add);
        processor.queueInput(pcm(MusiclessDsp.WINDOW, 0));
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
