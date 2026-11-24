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
    private InitializationException deferredInit;
    private WriteException deferredWrite;
    private final HoldDebounce hold = new HoldDebounce();
    private long holdStart;
    private String holdReason = "start";

    /** AudioTrack pending data flickers for a few ms while chunks are written; only sustained starvation is a hold. */
    static final class HoldDebounce {
        static final long DELAY_NS = 100_000_000L;
        long since = -1;
        boolean holding;
        /** Returns true when the debounced hold state changed. */
        boolean update(boolean starved, long nowNs) {
            if (!starved) since = -1; else if (since < 0) since = nowNs;
            boolean next = starved && (holding || nowNs - since >= DELAY_NS);
            if (next == holding) return false;
            holding = next;
            return true;
        }
        void set(boolean value, long nowNs) { holding = value; since = value ? nowNs : -1; }
    }

    private void updateHold() {
        long now = System.nanoTime();
        // After an underrun DefaultAudioSink can report no pending data for ~10 s while it plays normally;
        // vocals waiting for a full track mean playback is running, so only nothing-to-write is a hold.
        boolean started = outputFrames > output.remaining() / 4;
        boolean starved = !super.hasPendingData() && (started
                ? !output.hasRemaining() && processor.hasPendingData()
                : output.hasRemaining() || processor.hasPendingData());
        if (starved && hold.since < 0 && !hold.holding) processor.beginHold();
        if (!hold.update(starved, now)) return;
        if (hold.holding) {
            holdStart = hold.since;
        } else {
            logHold();
            holdReason = "underrun";
        }
        MusiclessHold.publish(this, hold.holding);
    }
    private void logHold() {
        long end = System.nanoTime();
        long inputEnd = processor.inputReadyNs == 0 ? end : processor.inputReadyNs;
        android.util.Log.i("Musicless", "hold reason=" + holdReason
                + " waitInputMs=" + Math.max(0, (inputEnd - holdStart) / 1000000)
                + " queueMs=" + processor.queueMs + " waitModelMs=" + processor.waitModelMs + " inferMs=" + processor.inferMs
                + " totalMs=" + (end - holdStart) / 1000000);
    }
    private void clearHold() {
        if (hold.holding) logHold();
        hold.set(false, 0);
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
        rethrowDeferred();
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
        // A full AudioTrack must not prevent bounded decoding/inference ahead of the playhead.
        drain();
        int before = buffer.remaining();
        if (!hold.holding && inputFrames == 0) {
            holdStart = System.nanoTime(); hold.set(true, holdStart); processor.beginHold();
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
            rethrowDeferred();
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

    private void rethrowDeferred() throws InitializationException, WriteException {
        InitializationException init = deferredInit; WriteException write = deferredWrite;
        deferredInit = null; deferredWrite = null;
        if (init != null) throw init;
        if (write != null) throw write;
    }

    @Override public boolean hasPendingData() {
        // Look-ahead consumes all decoded audio, so handleBuffer may not run again until the next network
        // chunk; this per-tick poll writes finished vocals meanwhile (errors surface on the next handleBuffer).
        if (startUs != C.TIME_UNSET && deferredInit == null && deferredWrite == null) {
            try { drain(); }
            catch (InitializationException error) { deferredInit = error; }
            catch (WriteException error) { deferredWrite = error; }
        }
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
        deferredInit = null; deferredWrite = null;
    }

    @Override public void reset() {
        clearHold(); holdReason = "start";
        super.reset(); processor.reset();
        inputFormat = pendingFormat = null;
        output = AudioProcessor.EMPTY_BUFFER;
        startUs = C.TIME_UNSET; outputFrames = inputFrames = 0;
        draining = discontinuity = false; inputBuffer = null;
        deferredInit = null; deferredWrite = null;
    }

    @Override public void release() { reset(); super.release(); }
}
