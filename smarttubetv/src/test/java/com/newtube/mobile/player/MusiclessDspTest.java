package com.newtube.mobile.player;

import org.junit.Test;
import static org.junit.Assert.*;

public class MusiclessDspTest {
    @Test public void unityMaskReconstructsBandLimitedStereoAndZeroMaskIsSilent() {
        MusiclessDsp dsp = new MusiclessDsp();
        float[] audio = new float[MusiclessDsp.WINDOW * 2];
        for (int i = 0; i < MusiclessDsp.WINDOW; i++) {
            audio[i * 2] = (float) (.2 * Math.sin(2 * Math.PI * 440 * i / MusiclessDsp.RATE));
            audio[i * 2 + 1] = (float) (.1 * Math.sin(2 * Math.PI * 880 * i / MusiclessDsp.RATE));
        }
        float[][] analysis = dsp.analyze(audio);
        assertEquals(2 * 513 * 1024 * 2, analysis[0].length);
        assertEquals(2 * 512 * 1024, analysis[1].length);
        float[] mask = new float[analysis[1].length];
        for (float sample : dsp.synthesize(analysis[0], mask)) assertEquals(0, sample, 0);
        java.util.Arrays.fill(mask, 1);
        float[] result = dsp.synthesize(analysis[0], mask);
        double error = 0, signal = 0;
        for (int i = 0; i < audio.length; i++) {
            assertTrue(Float.isFinite(result[i]));
            error += Math.pow(audio[i] - result[i], 2);
            signal += audio[i] * audio[i];
        }
        assertTrue("Unity mask should reconstruct below-11kHz audio", error / signal < 1e-5);
    }

    @Test public void overlapWeightsSumToOne() {
        assertEquals(MusiclessDsp.WINDOW, MusiclessDsp.STRIDE + MusiclessDsp.OVERLAP);
        for (int i = 0; i < MusiclessDsp.OVERLAP; i++) {
            float rise = (i + .5f) / MusiclessDsp.OVERLAP;
            assertEquals(1f, rise + (1 - rise), 1e-7f);
        }
    }
}
