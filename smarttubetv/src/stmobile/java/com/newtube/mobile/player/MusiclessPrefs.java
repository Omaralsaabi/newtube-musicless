package com.newtube.mobile.player;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Musicless prototype switch: separate the voices from the audio and play them instead of the
 * original track. Off by default. The audio sink is built with the player, so the playback screen
 * restarts its engine when it resumes with a different value (MobilePlaybackActivity.onResume).
 */
public final class MusiclessPrefs {

    private static final String PREFS_NAME = "newtube_musicless";
    private static final String KEY_REMOVE_MUSIC = "remove_music";

    private MusiclessPrefs() {
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
    }

    public static boolean isOn(Context context) {
        return prefs(context).getBoolean(KEY_REMOVE_MUSIC, false);
    }

    public static void setOn(Context context, boolean on) {
        prefs(context).edit().putBoolean(KEY_REMOVE_MUSIC, on).apply();
        if (on) MusiclessModels.get(context).start();
    }
}
