package com.newtube.mobile.player;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import com.liskovsoft.smartyoutubetv2.tv.BuildConfig;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.zip.GZIPInputStream;

/** Verified, persistent model downloads; partial files contain the gzip transport bytes. */
public final class MusiclessModels {
    public enum Status { NOT_DOWNLOADED, DOWNLOADING, READY, FAILED }
    public interface Listener { void changed(); }
    static final String[] NAMES = {"vocals.onnx", "accompaniment.onnx"};
    static final String[] HASHES = {
        "f6fce89a06c9a98846e1b38e45dcd79ade2c256c3ce11119b33474da726be552",
        "5e3f3048bf2936658a9ab3a9742b2e24765a06cc6c6c7de638aa93ea86330a45"};
    private static final java.util.concurrent.ExecutorService DOWNLOAD = Executors.newSingleThreadExecutor(
            r -> new Thread(r, "Musicless-download"));
    static MusiclessModels instance; // package-private: tests swap in a store without a download URL
    public static synchronized MusiclessModels get(Context context) {
        if (instance == null) {
            instance = new MusiclessModels(
                    new File(context.getApplicationContext().getNoBackupFilesDir(), "musicless"),
                    BuildConfig.MUSICLESS_MODEL_BASE_URL, NAMES, HASHES);
            File cache = context.getApplicationContext().getCacheDir();
            DOWNLOAD.execute(() -> deleteLegacyCache(cache));
        }
        return instance;
    }
    static void deleteLegacyCache(File cache) {
        File[] files = cache.listFiles((dir, name) -> name.startsWith("musicless-") && name.endsWith(".onnx"));
        if (files == null) return;
        for (File file : files) {
            if (file.isFile() && !file.delete()) android.util.Log.w("Musicless", "Cannot delete legacy cache " + file);
        }
    }
    private final File directory;
    private final String baseUrl;
    private final String[] names, hashes;
    private final List<Listener> listeners = new ArrayList<>();
    private final Handler main = new Handler(Looper.getMainLooper());
    public volatile Status status = Status.NOT_DOWNLOADED;
    public volatile int progress;
    public volatile String error;
    private boolean running;

    MusiclessModels(File directory, String baseUrl, String[] names, String[] hashes) {
        this.directory = directory; this.baseUrl = baseUrl; this.names = names; this.hashes = hashes;
        boolean ready = true;
        for (int i = 0; i < names.length; i++) ready &= modelFile(i).isFile();
        if (ready) status = Status.READY;
    }
    public synchronized void addListener(Listener listener) { listeners.add(listener); }
    public synchronized void removeListener(Listener listener) { listeners.remove(listener); }
    private synchronized void publish(Status state) {
        status = state;
        notifyAll();
        for (Listener listener : new ArrayList<>(listeners)) main.post(() -> {
            synchronized (MusiclessModels.this) { if (!listeners.contains(listener)) return; }
            listener.changed();
        });
    }
    public synchronized void start() {
        if (running || status == Status.READY) return;
        if (baseUrl.isEmpty()) {
            error = "Voice model download is not configured in this build";
            publish(Status.FAILED); return;
        }
        running = true; error = null; progress = 0; publish(Status.DOWNLOADING);
        DOWNLOAD.execute(this::download);
    }
    // Synchronous entry point also permits deterministic HTTP fixture tests.
    void download() {
        try {
            if (baseUrl.isEmpty()) throw new IOException("Voice model download is not configured in this build");
            if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("Cannot create model directory");
            for (int i = 0; i < names.length; i++) {
                if (!modelFile(i).isFile()) fetch(i);
            }
            progress = 100; publish(Status.READY);
        } catch (Exception failure) {
            error = "Voice model: " + failure.getMessage(); publish(Status.FAILED);
        } finally { synchronized (this) { running = false; notifyAll(); } }
    }
    private void fetch(int index) throws Exception {
        String name = names[index];
        File partial = new File(directory, name + ".part");
        long offset = partial.length();
        HttpURLConnection connection = (HttpURLConnection) new URL(baseUrl.replaceAll("/+$", "") + "/" + name + ".gz").openConnection();
        connection.setConnectTimeout(20000); connection.setReadTimeout(20000);
        connection.setRequestProperty("Accept-Encoding", "identity");
        if (offset > 0) connection.setRequestProperty("Range", "bytes=" + offset + "-");
        try {
            int code = connection.getResponseCode();
            if (code == 416 && offset > 0) { /* Complete gzip may have been saved before a process exit. */ }
            else {
                if (code != 200 && code != 206) throw new IOException("HTTP " + code);
                boolean append = code == 206 && offset > 0;
                if (code == 206 && (connection.getHeaderField("Content-Range") == null
                        || !connection.getHeaderField("Content-Range").startsWith("bytes " + offset + "-")))
                    throw new IOException("Invalid resume response");
                if (!append) offset = 0;
                long length = connection.getContentLengthLong();
                long total = length < 0 ? -1 : length + offset;
                try (InputStream in = connection.getInputStream(); FileOutputStream out = new FileOutputStream(partial, append)) {
                    byte[] bytes = new byte[65536];
                    for (int count; (count = in.read(bytes)) != -1;) {
                        if ((offset += count) > 100_000_000) throw new IOException("Download too large");
                        out.write(bytes, 0, count);
                        int next = (int) ((index * 100L + (total > 0 ? offset * 100 / total : 0)) / names.length);
                        if (next != progress) { progress = Math.min(99, next); publish(Status.DOWNLOADING); }
                    }
                    out.getFD().sync();
                }
            }
        } finally { connection.disconnect(); }
        File unpacked = new File(directory, name + ".unpack");
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            try (InputStream in = new GZIPInputStream(new FileInputStream(partial)); FileOutputStream out = new FileOutputStream(unpacked)) {
                byte[] bytes = new byte[65536];
                long size = 0;
                for (int count; (count = in.read(bytes)) != -1;) {
                    if ((size += count) > 100_000_000) throw new IOException("Model too large");
                    digest.update(bytes, 0, count); out.write(bytes, 0, count);
                }
                out.getFD().sync();
            }
            StringBuilder hex = new StringBuilder();
            for (byte b : digest.digest()) hex.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            if (!hashes[index].equals(hex.toString())) throw new IOException("SHA-256 mismatch; tap to retry");
            if (!unpacked.renameTo(modelFile(index))) throw new IOException("Cannot publish model");
            partial.delete();
        } catch (Exception failure) {
            partial.delete(); throw failure;
        } finally { unpacked.delete(); }
    }
    synchronized void awaitReady() throws IOException, InterruptedException {
        start();
        while (status == Status.DOWNLOADING) wait();
        if (status != Status.READY) throw new IOException(error);
    }
    private File modelFile(int index) { return new File(directory, hashes[index] + "-" + names[index]); }
    String path(int index) { return modelFile(index).getAbsolutePath(); }
    public String summary(Context context) {
        switch (status) {
            case READY: return context.getString(com.liskovsoft.smartyoutubetv2.tv.R.string.mobile_settings_remove_music_summary);
            case DOWNLOADING: return context.getString(com.liskovsoft.smartyoutubetv2.tv.R.string.musicless_downloading, progress);
            case FAILED: return error;
            default: return baseUrl.isEmpty() ? "Voice model download is not configured in this build" : context.getString(com.liskovsoft.smartyoutubetv2.tv.R.string.musicless_download_size);
        }
    }
}
