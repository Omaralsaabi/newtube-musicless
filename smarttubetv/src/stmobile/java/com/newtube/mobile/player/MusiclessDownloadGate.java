package com.newtube.mobile.player;

/** Pauses actual playback during model acquisition without losing the user's play/pause intent. */
public final class MusiclessDownloadGate {
    private boolean blocked, playIntent;

    public boolean update(boolean unavailable, boolean actualPlay) {
        boolean wasBlocked = blocked;
        if (unavailable && !blocked) playIntent = actualPlay;
        blocked = unavailable;
        return unavailable ? false : wasBlocked ? playIntent : actualPlay;
    }

    public boolean request(boolean play) {
        playIntent = play;
        return play && !blocked;
    }

    public boolean isBlocked() { return blocked; }
    public boolean playIntent(boolean actualPlay) { return blocked ? playIntent : actualPlay; }
    public void reset() { blocked = playIntent = false; }
}
