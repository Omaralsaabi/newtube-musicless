package com.newtube.mobile.player;

/** Musicless grid.js/dsp.js, ported to Java; periodic Hann and centered reflect padding. */
final class MusiclessDsp {
    static final int RATE = 44100, FFT = 4096, HOP = 1024, FRAMES = 512, BINS = 1024;
    static final int WINDOW = FRAMES * HOP, OVERLAP = 2 * HOP, STRIDE = WINDOW - OVERLAP;
    private final double[] hann = new double[FFT];
    private final double[] re = new double[FFT], im = new double[FFT];

    MusiclessDsp() {
        for (int i = 0; i < FFT; i++) hann[i] = .5 - .5 * Math.cos(2 * Math.PI * i / FFT);
    }

    float[][] analyze(float[] audio) {
        float[] spec = new float[2 * (FRAMES + 1) * BINS * 2];
        float[] magnitude = new float[2 * FRAMES * BINS];
        double sum = 0;
        for (float sample : audio) sum += sample * sample;
        double gain = Math.max(1 / Math.pow(10, 1.5), Math.min(Math.pow(10, 1.5),
                Math.pow(10, -1.2) / (Math.sqrt(sum / audio.length) + 1e-9)));
        for (int c = 0; c < 2; c++) {
            for (int f = 0; f <= FRAMES; f++) {
                for (int i = 0; i < FFT; i++) {
                    int at = f * HOP - FFT / 2 + i;
                    at = at < 0 ? -at : at >= WINDOW ? 2 * (WINDOW - 1) - at : at;
                    re[i] = audio[at * 2 + c] * hann[i];
                    im[i] = 0;
                }
                fft(false);
                for (int k = 0; k < BINS; k++) {
                    int at = (c * (FRAMES + 1) + f) * BINS + k;
                    spec[at * 2] = (float) re[k];
                    spec[at * 2 + 1] = (float) im[k];
                    if (f < FRAMES) magnitude[(c * FRAMES + f) * BINS + k] =
                            (float) (Math.hypot(re[k], im[k]) * gain);
                }
            }
        }
        return new float[][] {spec, magnitude};
    }

    float[] synthesize(float[] spec, float[] mask) {
        double[] output = new double[WINDOW * 2], weight = new double[WINDOW];
        for (int c = 0; c < 2; c++) {
            for (int f = 0; f <= FRAMES; f++) {
                java.util.Arrays.fill(re, 0);
                java.util.Arrays.fill(im, 0);
                for (int k = 0; k < BINS; k++) {
                    int at = (c * (FRAMES + 1) + f) * BINS + k;
                    float m = mask[(c * FRAMES + Math.min(f, FRAMES - 1)) * BINS + k];
                    re[k] = spec[at * 2] * m;
                    im[k] = spec[at * 2 + 1] * m;
                    if (k > 0) { re[FFT - k] = re[k]; im[FFT - k] = -im[k]; }
                }
                fft(true);
                for (int i = 0; i < FFT; i++) {
                    int at = f * HOP - FFT / 2 + i;
                    if (at < 0 || at >= WINDOW) continue;
                    output[at * 2 + c] += re[i] / FFT * hann[i];
                    if (c == 0) weight[at] += hann[i] * hann[i];
                }
            }
        }
        float[] result = new float[WINDOW * 2];
        for (int i = 0; i < WINDOW; i++) {
            for (int c = 0; c < 2; c++) result[i * 2 + c] =
                    (float) (output[i * 2 + c] / (weight[i] > 1e-11 ? weight[i] : 1));
        }
        return result;
    }

    private void fft(boolean inverse) {
        for (int i = 1, j = 0; i < FFT; i++) {
            int bit = FFT >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) {
                double t = re[i]; re[i] = re[j]; re[j] = t;
                t = im[i]; im[i] = im[j]; im[j] = t;
            }
        }
        for (int size = 2; size <= FFT; size <<= 1) {
            double angle = (inverse ? 2 : -2) * Math.PI / size;
            double wr = Math.cos(angle), wi = Math.sin(angle);
            for (int start = 0; start < FFT; start += size) {
                double cr = 1, ci = 0;
                for (int j = 0; j < size / 2; j++) {
                    int a = start + j, b = a + size / 2;
                    double tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
                    re[b] = re[a] - tr; im[b] = im[a] - ti;
                    re[a] += tr; im[a] += ti;
                    double next = cr * wr - ci * wi;
                    ci = cr * wi + ci * wr; cr = next;
                }
            }
        }
    }
}
