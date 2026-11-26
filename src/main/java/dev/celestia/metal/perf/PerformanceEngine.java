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
    private final float[] frameTimeHistoryMs = new float[120];
    private int historyCursor;
    private int historyCount;
    private double ewmaGpuMs = 0.0;
    private double ewmaFrameMs = 8.33;
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

    public void onFrameEnd(double frameDurationMs) {
        frameTimeHistoryMs[historyCursor] = (float) frameDurationMs;
        historyCursor = (historyCursor + 1) % frameTimeHistoryMs.length;
        if (historyCount < frameTimeHistoryMs.length) historyCount++;

        ewmaFrameMs = ewmaFrameMs * 0.92 + frameDurationMs * 0.08;

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

        updateEffectiveScale();
    }

    private void updateEffectiveScale() {
        CelestiaConfig.AppleSiliconSection cfg = CelestiaConfig.get().appleSilicon;
        if (!cfg.autoRenderScale) {
            effectiveScalePercent = cfg.renderScalePercent;
            trialFromPercent = -1;
            return;
        }
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
        double targetBudgetMs = 1000.0 / Math.max(60, Math.min(120, displayRefreshHz));
        if (lowPowerMode || cfg.thermalMode == CelestiaConfig.ThermalMode.BATTERY_SAVER) {
            targetBudgetMs = 1000.0 / 60.0;
        }
        int maxPercent = cfg.renderScalePercent;
        boolean backoff = System.currentTimeMillis() < noStepBelowUntilMs && effectiveScalePercent <= noStepBelowPercent;
        if (ewmaGpuMs > targetBudgetMs * 0.92 && effectiveScalePercent > 65 && !backoff) {
            trialFromPercent = effectiveScalePercent;
            trialBaselineFrameMs = ewmaFrameMs;
            trialFramesLeft = TRIAL_FRAMES;
            effectiveScalePercent = Math.max(65, effectiveScalePercent - 5);
        } else if (ewmaGpuMs > 0.0 && ewmaGpuMs < targetBudgetMs * 0.65 && effectiveScalePercent < maxPercent) {
            effectiveScalePercent = Math.min(maxPercent, effectiveScalePercent + 5);
            autoScaleCooldownFrames = 90;
        }
        if (cfg.thermalMode != CelestiaConfig.ThermalMode.OFF && thermalState >= 2) {
            effectiveScalePercent = Math.min(effectiveScalePercent, 80);
        }
    }

    public int effectiveRenderScalePercent() {
        return effectiveScalePercent;
    }

    public double ewmaGpuMs() {
        return ewmaGpuMs;
    }

    public double ewmaFrameMs() {
        return ewmaFrameMs;
    }

    public double estimatedFps() {
        return ewmaFrameMs > 0.01 ? 1000.0 / ewmaFrameMs : 0.0;
    }

    public double onePercentLowFps() {
        if (historyCount == 0) return 0.0;
        float[] copy = new float[historyCount];
        System.arraycopy(frameTimeHistoryMs, 0, copy, 0, historyCount);
        java.util.Arrays.sort(copy);
        int idx = Math.min(historyCount - 1, (int) Math.floor(historyCount * 0.99));
        float p99Ms = copy[idx];
        return p99Ms > 0.01f ? 1000.0 / p99Ms : 0.0;
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
