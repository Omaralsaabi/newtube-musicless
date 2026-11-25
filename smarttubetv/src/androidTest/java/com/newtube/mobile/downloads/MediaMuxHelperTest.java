package com.newtube.mobile.downloads;

import static org.junit.Assert.assertEquals;

import android.media.MediaExtractor;
import android.media.MediaMuxer;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

@RunWith(AndroidJUnit4.class)
public class MediaMuxHelperTest {
    /** A progressive (itag 18) rung is one file with both tracks; it is passed as video and audio part. */
    @Test(timeout = 60000)
    public void progressiveFileKeepsItsAudio() throws Exception {
        File in = asset("musicless/muxed.mp4"), out = new File(in.getParentFile(), "muxed-out.mp4");
        MediaMuxer muxer = new MediaMuxer(out.getPath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        MediaMuxHelper.mux(in, in, muxer, (timeUs, durationUs) -> true);
        muxer.release();

        MediaExtractor extractor = new MediaExtractor();
        extractor.setDataSource(out.getPath());
        int count = extractor.getTrackCount();
        extractor.release();
        assertEquals(2, count);
    }

    static File asset(String name) throws Exception {
        File file = new File(InstrumentationRegistry.getInstrumentation().getTargetContext().getCacheDir(),
                name.replace('/', '-'));
        try (InputStream in = InstrumentationRegistry.getInstrumentation().getContext().getAssets().open(name);
             OutputStream out = new FileOutputStream(file)) {
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
        }
        return file;
    }
}
