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
    private boolean draining, discontinuity;
    private long inputFrames;
    private ByteBuffer inputBuffer;
    private boolean holding;
    private long holdStart;
    private String holdReason = "start";

    private void updateHold() {
        boolean next = processor.hasPendingData() && !super.hasPendingData();
        if (next == holding) return;
        holding = next;
        if (next) {
            holdStart = System.nanoTime();
            processor.beginHold();
        } else {
            logHold();
            holdReason = "underrun";
        }
        MusiclessHold.publish(this, next);
    }
    private void logHold() {
        long end = System.nanoTime();
        long inputEnd = processor.inputReadyNs == 0 ? end : processor.inputReadyNs;
        android.util.Log.i("Musicless", "hold reason=" + holdReason
                + " waitInputMs=" + Math.max(0, (inputEnd - holdStart) / 1000000)
                + " waitModelMs=" + processor.waitModelMs + " inferMs=" + processor.inferMs
                + " totalMs=" + (end - holdStart) / 1000000);
    }
    private void clearHold() {
        if (holding) logHold();
        holding = false;
        MusiclessHold.publish(this, false);
    }

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
                // DASH/SABR audio formats leave channelCount unset; configure() checks the decoder output.
                && (format.channelCount == Format.NO_VALUE
                        || (format.channelCount >= 1 && format.channelCount <= 2))
                ? SINK_FORMAT_SUPPORTED_DIRECTLY : SINK_FORMAT_UNSUPPORTED;
    }

    @Override public AudioOffloadSupport getFormatOffloadSupport(Format format) {
        return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
    }

    @Override public void setOffloadMode(int mode) { super.setOffloadMode(OFFLOAD_MODE_DISABLED); }

    @Override public void configure(Format format, int specifiedBufferSize, int[] outputChannels)
            throws ConfigurationException {
        if (!supportsFormat(format) || format.channelCount == Format.NO_VALUE) throw new ConfigurationException("Musicless requires PCM16 mono/stereo", format);
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
        startUs = C.TIME_UNSET; outputFrames = inputFrames = 0;
        draining = discontinuity = false; inputBuffer = null;
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
        if (inputBuffer == null) {
            long expectedUs = startUs + inputFrames * 1000000L / inputFormat.sampleRate;
            if (startUs != C.TIME_UNSET && (discontinuity || Math.abs(timeUs - expectedUs) > 200000)) {
                processor.queueEndOfStream();
                if (!drain() || !processor.isEnded()) return false;
                processor.flush();
                startUs = C.TIME_UNSET; outputFrames = inputFrames = 0;
                super.handleDiscontinuity();
            }
            discontinuity = false;
            inputBuffer = buffer;
        }
        if (startUs == C.TIME_UNSET) startUs = timeUs;
        if (!drain()) return false;
        int before = buffer.remaining();
        if (!holding && inputFrames == 0) {
            holding = true; holdStart = System.nanoTime(); processor.beginHold();
            MusiclessHold.publish(this, true);
        }
        processor.queueInput(buffer);
        inputFrames += (before - buffer.remaining()) / (inputFormat.channelCount * 2);
        drain();
        if (buffer.hasRemaining()) return false;
        inputBuffer = null;
        return true;
    }

    private boolean drain() throws InitializationException, WriteException {
        while (true) {
            if (!output.hasRemaining()) {
                output = processor.getOutput();
                if (!output.hasRemaining()) { updateHold(); return true; }
                outputTimeUs = startUs + outputFrames * 1000000L / MusiclessDsp.RATE;
                outputFrames += output.remaining() / 4;
            }
            if (!super.handleBuffer(output, outputTimeUs, 1)) { updateHold(); return false; }
            updateHold();
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

    @Override public void handleDiscontinuity() {
        // Apply at the separated-sample boundary, not to previously queued vocals.
        discontinuity = true;
    }

    @Override public boolean hasPendingData() {
        // Stream-read EOF can precede playToEndOfStream: keep ALL unwritten vocals on the audio clock.
        updateHold();
        return output.hasRemaining() || processor.hasPendingData() || super.hasPendingData();
    }

    @Override public boolean isEnded() {
        return draining && !output.hasRemaining() && processor.isEnded() && super.isEnded();
    }

    @Override public void flush() {
        clearHold(); holdReason = startUs == C.TIME_UNSET ? "start" : "seek";
        super.flush();
        processor.flush();
        output = AudioProcessor.EMPTY_BUFFER;
        startUs = C.TIME_UNSET; outputFrames = inputFrames = 0;
        draining = discontinuity = false; inputBuffer = null;
    }

    @Override public void reset() {
        clearHold(); holdReason = "start";
        super.reset(); processor.reset();
        inputFormat = pendingFormat = null;
        output = AudioProcessor.EMPTY_BUFFER;
        startUs = C.TIME_UNSET; outputFrames = inputFrames = 0;
        draining = discontinuity = false; inputBuffer = null;
    }

    @Override public void release() { reset(); super.release(); }
}
