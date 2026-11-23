package com.newtube.mobile.player;

import org.junit.Test;
import static org.junit.Assert.*;

public class MusiclessDownloadGateTest {
    @Test public void downloadingFailedAndUnconfiguredStayPausedUntilReady() {
        MusiclessDownloadGate gate = new MusiclessDownloadGate();
        assertFalse(gate.update(true, true));
        assertTrue(gate.isBlocked());
        assertFalse(gate.update(true, false)); // progress, then a failure: preserve original intent
        assertFalse(gate.update(true, false));
        assertTrue(gate.update(false, false)); // READY restores playing
        assertFalse(gate.isBlocked());
    }
    @Test public void userPauseDuringDownloadPreventsAutoplayOnReady() {
        MusiclessDownloadGate gate = new MusiclessDownloadGate();
        gate.update(true, true);
        assertFalse(gate.request(false));
        assertFalse(gate.update(true, false));
        assertFalse(gate.update(false, false));
    }
    @Test public void playDuringDownloadRemembersIntentButCannotStartAudio() {
        MusiclessDownloadGate gate = new MusiclessDownloadGate();
        gate.update(true, false);
        assertFalse(gate.request(true));
        assertTrue(gate.playIntent(false));
        assertFalse(gate.update(true, false));
        assertTrue(gate.update(false, false));
    }
    @Test public void pausedPlayerStaysPausedAndNormalPlaybackIsUnaffected() {
        MusiclessDownloadGate gate = new MusiclessDownloadGate();
        assertFalse(gate.update(true, false));
        assertFalse(gate.update(false, false));
        assertTrue(gate.request(true));
        assertTrue(gate.update(false, true));
        assertFalse(gate.request(false));
        assertFalse(gate.update(false, false));
    }
    @Test public void resetClearsBlockedStateForReplacementPlayer() {
        MusiclessDownloadGate gate = new MusiclessDownloadGate();
        gate.update(true, true); gate.reset();
        assertFalse(gate.isBlocked());
        assertFalse(gate.playIntent(false));
        assertTrue(gate.request(true));
    }
}
