package com.newtube.mobile.player;

/** Host-only: javac -d /tmp/musicless-dsp MusiclessDsp.java DspBenchmark.java; java -cp /tmp/musicless-dsp com.newtube.mobile.player.DspBenchmark */
public final class DspBenchmark {
    public static void main(String[] args) {
        MusiclessDsp dsp = new MusiclessDsp();
        float[] audio = new float[MusiclessDsp.WINDOW * 2];
        for (int i = 0; i < audio.length; i++) audio[i] = (float) (.2 * Math.sin(i * .03));
        float[] mask = new float[2 * MusiclessDsp.FRAMES * MusiclessDsp.BINS];
        java.util.Arrays.fill(mask, 1);
        double[] ms = new double[9];
        for (int i = -3; i < ms.length; i++) {
            long start = System.nanoTime();
            float[][] analysis = dsp.analyze(audio);
            float[] output = dsp.synthesize(analysis[0], mask);
            if (!Float.isFinite(output[1234]) || Math.abs(output[1234] - audio[1234]) > .001)
                throw new AssertionError("reconstruction");
            if (i >= 0) ms[i] = (System.nanoTime() - start) / 1e6;
        }
        java.util.Arrays.sort(ms);
        System.out.printf("analyze+synthesize median %.3f ms (9 windows, 3 warmup)%n", ms[4]);
    }
}
