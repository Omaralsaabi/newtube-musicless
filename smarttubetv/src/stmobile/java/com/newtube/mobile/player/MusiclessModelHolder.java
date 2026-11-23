package com.newtube.mobile.player;

import android.content.Context;
import android.content.ComponentCallbacks2;
import android.util.Log;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** All session loading, inference and disposal run on this single process-wide thread. */
public class MusiclessModelHolder {
    private static final MusiclessModelHolder INSTANCE = new MusiclessModelHolder();
    static MusiclessModelHolder get() { return INSTANCE; }
    final ScheduledThreadPoolExecutor executor;
    private MusiclessModelHolder() {
        this(new ScheduledThreadPoolExecutor(1, r -> new Thread(r, "Musicless-ORT")));
    }
    MusiclessModelHolder(ScheduledThreadPoolExecutor executor) { this.executor = executor; }
    OrtSession vocals, accompaniment;
    private int users, epoch;
    private long loadMs;

    public static void preload(Context context) {
        MusiclessModels models = MusiclessModels.get(context);
        models.start();
        if (models.status == MusiclessModels.Status.READY) INSTANCE.executor.execute(() -> {
            try { INSTANCE.load(models); }
            catch (Exception | OutOfMemoryError | LinkageError error) { Log.e("Musicless", "Preload failed", error); }
            INSTANCE.scheduleRelease();
        });
    }
    synchronized int userCount() { return users; }
    synchronized void acquire() { users++; epoch++; }
    synchronized void release() { if (users > 0) users--; scheduleRelease(); }
    private synchronized void scheduleRelease() {
        if (users != 0) return;
        int token = ++epoch;
        executor.schedule(() -> {
            synchronized (this) { if (users == 0 && epoch == token) close(); }
        }, 2, TimeUnit.MINUTES);
    }
    public static void trimMemory(int level) { INSTANCE.executor.execute(() -> INSTANCE.trim(level)); }
    synchronized void trim(int level) {
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW
                && (level != ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN || users == 0)) close();
    }
    long load(MusiclessModels models) throws Exception {
        if (vocals != null && accompaniment != null) return 0;
        models.awaitReady();
        long start = System.nanoTime();
        try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
            options.setIntraOpNumThreads(2); options.setInterOpNumThreads(1);
            options.setCPUArenaAllocator(false); options.setMemoryPatternOptimization(false);
            options.addConfigEntry("session.intra_op.allow_spinning", "0");
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.BASIC_OPT);
            options.setSymbolicDimensionValue("num_splits", 1);
            OrtEnvironment environment = OrtEnvironment.getEnvironment();
            environment.setTelemetry(false);
            vocals = environment.createSession(models.path(0), options);
            accompaniment = environment.createSession(models.path(1), options);
        } catch (Exception | OutOfMemoryError | LinkageError failure) { close(); throw failure; }
        loadMs = (System.nanoTime() - start) / 1000000;
        Log.i("Musicless", "Model loaded ms=" + loadMs);
        return loadMs;
    }
    void close() {
        for (OrtSession session : new OrtSession[] {vocals, accompaniment}) {
            if (session != null) try { session.close(); } catch (Exception failure) { Log.e("Musicless", "Close failed", failure); }
        }
        vocals = accompaniment = null;
    }
}
