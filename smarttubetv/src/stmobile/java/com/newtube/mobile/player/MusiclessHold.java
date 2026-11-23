package com.newtube.mobile.player;

import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;
import java.util.List;

/** Main-thread notifications; owner tokens prevent released sinks clearing a new player's hold. */
public final class MusiclessHold {
    public interface Listener { void changed(boolean holding); }
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final List<Listener> LISTENERS = new ArrayList<>();
    private static Object owner;
    private static boolean holding;
    public static void addListener(Listener listener) {
        MAIN.post(() -> { LISTENERS.add(listener); listener.changed(holding); });
    }
    public static void removeListener(Listener listener) { MAIN.post(() -> LISTENERS.remove(listener)); }
    static void publish(Object source, boolean value) {
        MAIN.post(() -> {
            if (!value && owner != source) return;
            owner = source;
            if (holding == value) return;
            holding = value;
            for (Listener listener : new ArrayList<>(LISTENERS)) listener.changed(value);
        });
    }
}
