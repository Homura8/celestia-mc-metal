package dev.celestia.metal.perf;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalNative;
import net.fabricmc.loader.api.FabricLoader;

/**
 * Runtime performance, thermal, battery, and Auto Render Scale controller for Apple Silicon.
 */
public final class PerformanceEngine {
    private static final PerformanceEngine INSTANCE = new PerformanceEngine();

    private final boolean sodiumPresent = FabricLoader.getInstance().isModLoaded("sodium");
    private final FrameTiming frameTiming = new FrameTiming();
    private double ewmaGpuMs = 0.0;
    private double ewmaFrameMs = 8.33;
    private static final int MIN_AUTO_SCALE_PERCENT = 65;
    private int effectiveScalePercent = 100;
    // Auto Render Scale trial: a step down is kept only if it measurably shortens the frame (the upscaler has a fixed
    // GPU cost, ~2 ms for MetalFX Spatial at 3024x1752, so a lower scale can be slower on light scenes).
    private int trialFromPercent = -1;
    private double trialBaselineFrameMs;
    private int trialFramesLeft;
    private int noStepBelowPercent;
    private long noStepBelowUntilMs;
    static final int TRIAL_FRAMES = 90;
    static final double TRIAL_MIN_GAIN = 0.03;
    static final long TRIAL_BACKOFF_MS = 15_000L;
    private long lastTelemetryPollMs;
    private int thermalState;
    private boolean lowPowerMode;
    private int displayRefreshHz = 120;
    private float edrHeadroom = 1.0f;
    private int autoScaleCooldownFrames;

    private PerformanceEngine() {}

    public static PerformanceEngine get() {
        return INSTANCE;
    }

    public boolean isSodiumPresent() {
        return sodiumPresent;
    }

    public void onFrameEnd(long frameStartNs, int frameRateLimit) {
        double frameIntervalMs = frameTiming.recordStart(frameStartNs);
        if (frameIntervalMs > 0.0) ewmaFrameMs = ewmaFrameMs * 0.92 + frameIntervalMs * 0.08;

        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            long gpuNs = MetalNative.deviceLastGpuNs(dev.handle());
            if (gpuNs > 0L) {
                double gpuMs = gpuNs / 1_000_000.0;
                ewmaGpuMs = ewmaGpuMs <= 0.0 ? gpuMs : (ewmaGpuMs * 0.9 + gpuMs * 0.1);
            }
        }

        long now = System.currentTimeMillis();
        if (now - lastTelemetryPollMs >= 2000L) {
            lastTelemetryPollMs = now;
            if (MetalNative.isLoaded()) {
                MetalNative.Telemetry t = MetalNative.queryTelemetry();
                thermalState = t.thermalState();
                lowPowerMode = t.lowPowerMode();
                if (t.refreshHz() > 0) displayRefreshHz = t.refreshHz();
                edrHeadroom = t.edrHeadroom();
            }
        }

        updateEffectiveScale(frameRateLimit);
    }

    private void updateEffectiveScale(int frameRateLimit) {
        CelestiaConfig.AppleSiliconSection cfg = CelestiaConfig.get().appleSilicon;
        int maxPercent = cfg.renderScalePercent;
        if (!cfg.autoRenderScale || maxPercent <= MIN_AUTO_SCALE_PERCENT) {
            effectiveScalePercent = maxPercent;
            trialFromPercent = -1;
            return;
        }
        effectiveScalePercent = Math.clamp(effectiveScalePercent, MIN_AUTO_SCALE_PERCENT, maxPercent);
        // A change to the configured maximum can invalidate the scale we would restore after a trial.
        if (trialFromPercent > maxPercent) trialFromPercent = -1;
        if (trialFromPercent >= 0) {
            if (--trialFramesLeft > 0) return;
            boolean helped = ewmaFrameMs < trialBaselineFrameMs * (1.0 - TRIAL_MIN_GAIN);
            if (!helped) {
                // Not faster at the lower scale: go back and don't try below it for a while.
                effectiveScalePercent = trialFromPercent;
                noStepBelowPercent = trialFromPercent;
                noStepBelowUntilMs = System.currentTimeMillis() + TRIAL_BACKOFF_MS;
            }
            trialFromPercent = -1;
            autoScaleCooldownFrames = 45;
            return;
        }
        if (autoScaleCooldownFrames > 0) {
            autoScaleCooldownFrames--;
            return;
        }
        double targetBudgetMs = targetFrameBudgetMs(displayRefreshHz, frameRateLimit,
            lowPowerMode || cfg.thermalMode == CelestiaConfig.ThermalMode.BATTERY_SAVER);
        boolean backoff = System.currentTimeMillis() < noStepBelowUntilMs && effectiveScalePercent <= noStepBelowPercent;
        if (ewmaGpuMs > targetBudgetMs * 0.92 && effectiveScalePercent > MIN_AUTO_SCALE_PERCENT && !backoff) {
            trialFromPercent = effectiveScalePercent;
            trialBaselineFrameMs = ewmaFrameMs;
            trialFramesLeft = TRIAL_FRAMES;
            effectiveScalePercent = Math.max(MIN_AUTO_SCALE_PERCENT, effectiveScalePercent - 5);
        } else if (ewmaGpuMs > 0.0 && ewmaGpuMs < targetBudgetMs * 0.65 && effectiveScalePercent < maxPercent) {
            effectiveScalePercent = Math.min(maxPercent, effectiveScalePercent + 5);
            autoScaleCooldownFrames = 90;
        }
        if (cfg.thermalMode != CelestiaConfig.ThermalMode.OFF && thermalState >= 2) {
            effectiveScalePercent = Math.min(effectiveScalePercent, 80);
        }
    }

    static double targetFrameBudgetMs(int refreshHz, int frameRateLimit, boolean batterySaving) {
        int targetFps = batterySaving ? 60 : Math.clamp(refreshHz, 60, 120);
        if (frameRateLimit > 0) targetFps = Math.min(targetFps, frameRateLimit);
        return 1000.0 / targetFps;
    }

    public int effectiveRenderScalePercent() {
        CelestiaConfig.AppleSiliconSection cfg = CelestiaConfig.get().appleSilicon;
        int maxPercent = cfg.renderScalePercent;
        if (!cfg.autoRenderScale || maxPercent <= MIN_AUTO_SCALE_PERCENT) return maxPercent;
        return Math.clamp(effectiveScalePercent, MIN_AUTO_SCALE_PERCENT, maxPercent);
    }

    public double ewmaGpuMs() {
        return ewmaGpuMs;
    }

    public double ewmaFrameMs() {
        return ewmaFrameMs;
    }

    public double averageFps() {
        return frameTiming.averageFps();
    }

    public double onePercentLowFps() {
        return frameTiming.onePercentLowFps();
    }

    public int thermalState() {
        return thermalState;
    }

    public String thermalLabel() {
        return switch (thermalState) {
            case 0 -> "Nominal";
            case 1 -> "Fair";
            case 2 -> "Serious";
            case 3 -> "Critical";
            default -> "Unknown";
        };
    }

    public boolean isLowPowerMode() {
        return lowPowerMode;
    }

    public int displayRefreshHz() {
        return displayRefreshHz;
    }

    public float edrHeadroom() {
        return edrHeadroom;
    }

    public int effectiveFramerateCap(int userCap) {
        CelestiaConfig.AppleSiliconSection cfg = CelestiaConfig.get().appleSilicon;
        if (cfg.thermalMode == CelestiaConfig.ThermalMode.BATTERY_SAVER || lowPowerMode) {
            int batCap = thermalState >= 2 ? 30 : 60;
            return userCap <= 0 ? batCap : Math.min(userCap, batCap);
        }
        if (cfg.thermalMode == CelestiaConfig.ThermalMode.BALANCED && thermalState >= 2) {
            return userCap <= 0 ? 60 : Math.min(userCap, 60);
        }
        return userCap;
    }
}
