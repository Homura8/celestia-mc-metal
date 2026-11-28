package dev.celestia.metal.perf;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class PerformanceEngineTest {
    @Test
    void autoScaleUsesTheLowerFrameLimitOrDisplayBudget() {
        assertEquals(1000.0 / 60, PerformanceEngine.targetFrameBudgetMs(120, 60, false));
        assertEquals(1000.0 / 120, PerformanceEngine.targetFrameBudgetMs(120, 260, false));
        assertEquals(1000.0 / 60, PerformanceEngine.targetFrameBudgetMs(120, 260, true));
        assertEquals(1000.0 / 30, PerformanceEngine.targetFrameBudgetMs(120, 30, true));
    }

    @Test
    void frameRateAndLowsIncludePacingAndUseTheSameWindow() {
        FrameTiming timing = new FrameTiming();
        long startNs = 0;
        timing.recordStart(startNs);
        assertEquals(0.0, timing.averageFps());
        assertEquals(0.0, timing.onePercentLowFps());

        timing.recordStart(startNs += 50_000_000L);
        timing.recordStart(startNs += 30_000_000L);
        for (int i = 0; i < 118; i++) timing.recordStart(startNs += 16_000_000L);
        assertEquals(120_000.0 / (118 * 16 + 80), timing.averageFps(), 1e-9);
        assertEquals(25.0, timing.onePercentLowFps(), 1e-9);

        for (int i = 0; i < 120; i++) timing.recordStart(startNs += 16_000_000L);
        assertEquals(62.5, timing.averageFps(), 1e-9);
        assertEquals(timing.averageFps(), timing.onePercentLowFps(), 1e-9);
    }
}
