package com.newtube.mobile.player;

import java.io.*;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPOutputStream;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.ConscryptMode;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, application = android.app.Application.class)
@ConscryptMode(ConscryptMode.Mode.OFF)
public class MusiclessModelsTest {
    private static final byte[] MODEL = "a small verified voice model fixture".getBytes(java.nio.charset.StandardCharsets.UTF_8);
    private String hash() throws Exception {
        StringBuilder s = new StringBuilder();
        for (byte b : MessageDigest.getInstance("SHA-256").digest(MODEL)) s.append(String.format("%02x", b & 255));
        return s.toString();
    }
    private byte[] gzip() throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (GZIPOutputStream out = new GZIPOutputStream(bytes)) { out.write(MODEL); }
        return bytes.toByteArray();
    }
    private MusiclessModels models(File directory, String url, String hash) {
        return new MusiclessModels(directory, url, new String[] {"fixture.onnx"}, new String[] {hash});
    }
    private static class Server implements AutoCloseable {
        final ServerSocket server = new ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"));
        final FutureTask<String> request;
        Server(byte[] gzip, int offset, boolean resume) throws Exception {
            request = new FutureTask<>(() -> {
                try (Socket socket = server.accept()) {
                    socket.setSoTimeout(5000);
                    BufferedReader in = new BufferedReader(new InputStreamReader(socket.getInputStream(), java.nio.charset.StandardCharsets.US_ASCII));
                    StringBuilder headers = new StringBuilder();
                    for (String line; (line = in.readLine()) != null && !line.isEmpty();) headers.append(line).append('\n');
                    String response = "HTTP/1.1 " + (resume ? "206 Partial Content" : "200 OK")
                            + "\r\nContent-Length: " + (gzip.length - offset) + "\r\nConnection: close\r\n"
                            + (resume ? "Content-Range: bytes " + offset + "-" + (gzip.length - 1) + "/" + gzip.length + "\r\n" : "") + "\r\n";
                    socket.getOutputStream().write(response.getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(gzip, offset, gzip.length - offset);
                    return headers.toString();
                }
            });
            new Thread(request, "musicless-http-test").start();
        }
        String url() { return "http://127.0.0.1:" + server.getLocalPort(); }
        @Override public void close() throws Exception { server.close(); }
    }
    @Test public void resumesPartialGzipAndPublishesOnlyVerifiedModel() throws Exception {
        File dir = Files.createTempDirectory("musicless").toFile();
        byte[] gzip = gzip();
        Files.write(new File(dir, "fixture.onnx.part").toPath(), Arrays.copyOf(gzip, 13));
        try (Server server = new Server(gzip, 13, true)) {
            MusiclessModels models = models(dir, server.url(), hash());
            models.download();
            assertTrue(server.request.get(5, TimeUnit.SECONDS).contains("Range: bytes=13-"));
            assertEquals(MusiclessModels.Status.READY, models.status);
            assertArrayEquals(MODEL, Files.readAllBytes(new File(models.path(0)).toPath()));
            assertFalse(new File(dir, "fixture.onnx.part").exists());
            assertEquals(MusiclessModels.Status.READY, models(dir, "", hash()).status);
            assertEquals(MusiclessModels.Status.NOT_DOWNLOADED, models(dir, "", "new-version").status);
        }
    }
    @Test public void shaMismatchFailsAndRemovesPartialAndUnpackedFile() throws Exception {
        File dir = Files.createTempDirectory("musicless").toFile();
        try (Server server = new Server(gzip(), 0, false)) {
            MusiclessModels models = models(dir, server.url(), "wrong");
            models.download();
            assertEquals(MusiclessModels.Status.FAILED, models.status);
            assertTrue(models.error.contains("SHA-256 mismatch"));
            assertEquals(0, dir.list().length);
            server.request.get(5, TimeUnit.SECONDS);
        }
    }
    @Test public void serverIgnoringRangeRestartsInsteadOfAppending() throws Exception {
        File dir = Files.createTempDirectory("musicless").toFile();
        Files.write(new File(dir, "fixture.onnx.part").toPath(), new byte[] {1, 2, 3});
        try (Server server = new Server(gzip(), 0, false)) {
            MusiclessModels models = models(dir, server.url(), hash()); models.download();
            assertEquals(MusiclessModels.Status.READY, models.status);
            assertArrayEquals(MODEL, Files.readAllBytes(new File(models.path(0)).toPath()));
            server.request.get(5, TimeUnit.SECONDS);
        }
    }
    @Test
    @org.robolectric.annotation.LooperMode(org.robolectric.annotation.LooperMode.Mode.PAUSED)
    public void stateListenerIsPostedOnMainAndCanBeRemoved() throws Exception {
        MusiclessModels models = models(Files.createTempDirectory("musicless").toFile(), "", hash());
        int[] calls = {0};
        MusiclessModels.Listener listener = () -> {
            assertSame(android.os.Looper.getMainLooper(), android.os.Looper.myLooper()); calls[0]++;
        };
        models.addListener(listener); models.start(); assertEquals(0, calls[0]);
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(1, calls[0]);
        models.removeListener(listener); models.start();
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
        assertEquals(1, calls[0]);
    }
    @Test public void unconfiguredUrlFailsWithoutCreatingFiles() throws Exception {
        File dir = Files.createTempDirectory("musicless").toFile();
        MusiclessModels models = models(dir, "", hash()); models.start();
        assertEquals(MusiclessModels.Status.FAILED, models.status);
        assertTrue(models.error.contains("not configured"));
        assertEquals(0, dir.list().length);
    }
}
