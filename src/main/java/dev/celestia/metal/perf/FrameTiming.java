package dev.celestia.metal.perf;

import java.util.Arrays;

/** Rolling frame intervals measured between consecutive render starts. */
final class FrameTiming {
    private static final int WINDOW_SIZE = 120;
    private final double[] intervals = new double[WINDOW_SIZE];
    private final double[] sorted = new double[WINDOW_SIZE];
    private long previousStartNs;
    private boolean hasPreviousStart;
    private int cursor;
    private int count;
    private double totalMs;

    double recordStart(long nowNs) {
        long elapsedNs = nowNs - previousStartNs;
        previousStartNs = nowNs;
        if (!hasPreviousStart) {
            hasPreviousStart = true;
            return 0.0;
        }
        if (elapsedNs <= 0) return 0.0;

        double elapsedMs = elapsedNs / 1_000_000.0;
        totalMs += elapsedMs - intervals[cursor];
        intervals[cursor] = elapsedMs;
        cursor = (cursor + 1) % intervals.length;
        if (count < intervals.length) count++;
        return elapsedMs;
    }

    double averageFps() {
        return count > 0 ? 1000.0 * count / totalMs : 0.0;
    }

    double onePercentLowFps() {
        if (count == 0) return 0.0;
        System.arraycopy(intervals, 0, sorted, 0, count);
        Arrays.sort(sorted, 0, count);
        // Average the frame times in the slowest 1%, rounding up to whole frames.
        int slowFrames = (count + 99) / 100;
        double slowTimeMs = 0.0;
        for (int i = count - slowFrames; i < count; i++) slowTimeMs += sorted[i];
        return 1000.0 * slowFrames / slowTimeMs;
    }
}
