package com.newtube.mobile.player;

import java.util.ArrayDeque;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.junit.Test;
import static org.junit.Assert.*;

public class MusiclessModelHolderTest {
    private static class Scheduler extends ScheduledThreadPoolExecutor {
        final ArrayDeque<Runnable> timers = new ArrayDeque<>();
        Scheduler() { super(1); }
        @Override public ScheduledFuture<?> schedule(Runnable job, long delay, TimeUnit unit) {
            assertEquals(120, unit.toSeconds(delay));
            timers.add(job); return null;
        }
    }
    private static class Holder extends MusiclessModelHolder {
        int closes;
        Holder(Scheduler scheduler) { super(scheduler); }
        @Override void close() { closes++; }
    }
    @Test public void processWideHolderIsShared() {
        assertSame(MusiclessModelHolder.get(), MusiclessModelHolder.get());
        assertEquals(1, MusiclessModelHolder.get().executor.getCorePoolSize());
    }
    @Test public void sessionsSurviveUntilLastSinkReleasesAndIdleTimerExpires() {
        Scheduler scheduler = new Scheduler();
        Holder holder = new Holder(scheduler);
        holder.acquire(); holder.acquire(); holder.release();
        assertTrue(scheduler.timers.isEmpty());
        holder.release(); assertEquals(1, scheduler.timers.size());
        assertEquals(0, holder.closes);
        scheduler.timers.remove().run(); assertEquals(1, holder.closes);
    }
    @Test public void memoryPressureReleasesButUiHiddenKeepsActivePlayback() {
        Holder holder = new Holder(new Scheduler());
        holder.acquire();
        holder.trim(android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN);
        assertEquals(0, holder.closes);
        holder.trim(android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW);
        assertEquals(1, holder.closes);
        holder.release();
        holder.trim(android.content.ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN);
        assertEquals(2, holder.closes);
    }
    @Test public void reuseInvalidatesPreviousIdleRelease() {
        Scheduler scheduler = new Scheduler();
        Holder holder = new Holder(scheduler);
        holder.acquire(); holder.release();
        holder.acquire();
        scheduler.timers.remove().run(); assertEquals(0, holder.closes);
        holder.release(); scheduler.timers.remove().run(); assertEquals(1, holder.closes);
    }
}
