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
        ByteBuffer silence = processor.getOutput();
        assertEquals(4410 * 4, silence.remaining());
        while (silence.hasRemaining()) assertEquals(0, silence.getShort());
        processor.flush();
        assertFalse(processor.getOutput().hasRemaining());
        processor.reset();
    }
}
