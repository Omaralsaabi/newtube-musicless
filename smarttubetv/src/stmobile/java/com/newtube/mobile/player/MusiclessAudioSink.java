package com.newtube.mobile.player;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.audio.AudioOffloadSupport;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/** Runs the asynchronous processor outside DefaultAudioSink's synchronous processBuffers loop. */
final class MusiclessAudioSink extends ForwardingAudioSink {
    private final MusiclessAudioProcessor processor;
    private Format inputFormat, pendingFormat;
    private int bufferSize;
    private ByteBuffer output = AudioProcessor.EMPTY_BUFFER;
    private long startUs = C.TIME_UNSET, outputFrames, outputTimeUs;
    private boolean draining;

    MusiclessAudioSink(AudioSink sink, MusiclessAudioProcessor processor) {
        super(sink);
        this.processor = processor;
    }

    @Override public boolean supportsFormat(Format format) {
        return getFormatSupport(format) != SINK_FORMAT_UNSUPPORTED;
    }

    @Override public int getFormatSupport(Format format) {
        return MimeTypes.AUDIO_RAW.equals(format.sampleMimeType)
                && format.pcmEncoding == C.ENCODING_PCM_16BIT
                && format.channelCount >= 1 && format.channelCount <= 2
                ? SINK_FORMAT_SUPPORTED_DIRECTLY : SINK_FORMAT_UNSUPPORTED;
    }

    @Override public AudioOffloadSupport getFormatOffloadSupport(Format format) {
        return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
    }

    @Override public void setOffloadMode(int mode) { super.setOffloadMode(OFFLOAD_MODE_DISABLED); }

    @Override public void configure(Format format, int specifiedBufferSize, int[] outputChannels)
            throws ConfigurationException {
        if (!supportsFormat(format)) throw new ConfigurationException("Musicless requires PCM16 mono/stereo", format);
        bufferSize = specifiedBufferSize;
        pendingFormat = format;
        if (inputFormat == null) applyFormat();
    }

    private void applyFormat() throws ConfigurationException {
        Format format = pendingFormat;
        try {
            processor.configure(new AudioProcessor.AudioFormat(format.sampleRate, format.channelCount, format.pcmEncoding));
        } catch (AudioProcessor.UnhandledAudioFormatException error) {
            throw new ConfigurationException(error, format);
        }
        processor.flush();
        super.configure(format.buildUpon().setSampleRate(MusiclessDsp.RATE).setChannelCount(2)
                .setEncoderDelay((int) ((long) format.encoderDelay * MusiclessDsp.RATE / format.sampleRate))
                .setEncoderPadding((int) ((long) format.encoderPadding * MusiclessDsp.RATE / format.sampleRate))
                .build(), bufferSize, null);
        inputFormat = format;
        pendingFormat = null;
        startUs = C.TIME_UNSET; outputFrames = 0; draining = false;
    }

    @Override public boolean handleBuffer(ByteBuffer buffer, long timeUs, int count)
            throws InitializationException, WriteException {
        if (pendingFormat != null) {
            if (pendingFormat.sampleRate == inputFormat.sampleRate
                    && pendingFormat.channelCount == inputFormat.channelCount
                    && pendingFormat.encoderDelay == inputFormat.encoderDelay
                    && pendingFormat.encoderPadding == inputFormat.encoderPadding) {
                pendingFormat = null;
            } else {
                processor.queueEndOfStream();
                if (!drain() || !processor.isEnded()) return false;
                try { applyFormat(); }
                catch (ConfigurationException error) { throw new IllegalStateException(error); }
            }
        }
        if (startUs == C.TIME_UNSET) startUs = timeUs;
        if (!drain()) return false;
        processor.queueInput(buffer);
        drain();
        return !buffer.hasRemaining();
    }

    private boolean drain() throws InitializationException, WriteException {
        while (true) {
            if (!output.hasRemaining()) {
                output = processor.getOutput();
                if (!output.hasRemaining()) return true;
                outputTimeUs = startUs + outputFrames * 1000000L / MusiclessDsp.RATE;
                outputFrames += output.remaining() / 4;
            }
            if (!super.handleBuffer(output, outputTimeUs, 1)) return false;
        }
    }

    @Override public void playToEndOfStream() throws WriteException {
        if (!draining) { processor.queueEndOfStream(); draining = true; }
        try {
            if (drain() && processor.isEnded()) super.playToEndOfStream();
        } catch (InitializationException error) {
            WriteException failure = new WriteException(-1, inputFormat, false);
            failure.initCause(error);
            throw failure;
        }
    }

    @Override public boolean isEnded() {
        return draining && !output.hasRemaining() && processor.isEnded() && super.isEnded();
    }

    @Override public void flush() {
        super.flush();
        processor.flush();
        output = AudioProcessor.EMPTY_BUFFER;
        startUs = C.TIME_UNSET; outputFrames = 0; draining = false;
    }

    @Override public void reset() {
        super.reset(); processor.reset();
        inputFormat = pendingFormat = null;
        output = AudioProcessor.EMPTY_BUFFER;
        startUs = C.TIME_UNSET; outputFrames = 0; draining = false;
    }

    @Override public void release() { reset(); super.release(); }
}
