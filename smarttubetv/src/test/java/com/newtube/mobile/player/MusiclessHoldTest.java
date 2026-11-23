package com.newtube.mobile.player;

import android.os.Looper;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.LooperMode;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, application = android.app.Application.class)
@org.robolectric.annotation.ConscryptMode(org.robolectric.annotation.ConscryptMode.Mode.OFF)
@LooperMode(LooperMode.Mode.PAUSED)
public class MusiclessHoldTest {
    @Test public void postsChangesOnceOnMainAndRejectsStaleRelease() throws Exception {
        List<Boolean> states = new ArrayList<>();
        MusiclessHold.Listener listener = hold -> {
            assertSame(Looper.getMainLooper(), Looper.myLooper()); states.add(hold);
        };
        Object oldSink = new Object(), newSink = new Object();
        MusiclessHold.addListener(listener);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        states.clear();
        Thread worker = new Thread(() -> {
            MusiclessHold.publish(oldSink, true);
            MusiclessHold.publish(newSink, true);
            MusiclessHold.publish(oldSink, false);
        });
        worker.start(); worker.join();
        assertTrue(states.isEmpty());
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertEquals(java.util.Arrays.asList(true), states);
        MusiclessHold.publish(newSink, false);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertEquals(java.util.Arrays.asList(true, false), states);
        MusiclessHold.removeListener(listener);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
    }
}
