package dev.celestia.metal.perf;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Persistent configuration for Celestia Metal ({@code config/celestia-metal.json}).
 * Uses atomic snapshot reads and temp-file atomic writes.
 */
public final class CelestiaConfig {
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();
    private static volatile CelestiaConfig instance;

    public enum MetalMode { AUTO_METAL_4, METAL_4, METAL_3 }
    public enum UpscalerMode { METALFX_TEMPORAL, METALFX_SPATIAL, BILINEAR }
    public enum ThermalMode { OFF, BALANCED, BATTERY_SAVER }
    public enum HudMode { OFF, COMPACT, DETAILED }

    public static final class QualitySection {
        public boolean smoothLighting = true;
        public int biomeBlendRadius = 2;
        public boolean entityShadows = true;
        public boolean cutoutLeaves = true;
        public boolean vignette = true;
        public int mipmapLevels = 4;
        public int anisotropicLevel = 4;
        public boolean improvedTransparency = true;
    }

    public static final class PerformanceSection {
        public boolean chunkUploadPacing = true;
        public int maxChunkUploadsPerFrame = 4;
        public boolean bufferPooling = true;
        public boolean indirectBatching = true;
        public boolean entityFrustumCulling = true;
        public boolean relaxedTerrainMath = true;
        public boolean terrainLod = true;
        public int terrainLodRadiusPercent = 75;
        /** Continue the open Metal render encoder for consecutive passes on identical attachments. */
        public boolean renderPassMerging = true;
        /** Fold texture clears into the next render pass's load action instead of separate clear encoders. */
        public boolean deferredClears = true;
    }

    public static final class AppleSiliconSection {
        public MetalMode metalMode = MetalMode.AUTO_METAL_4;
        public boolean autoRenderScale = false;
        public int renderScalePercent = 100;
        public UpscalerMode upscaler = UpscalerMode.METALFX_TEMPORAL;
        public boolean hdrEnabled = false;
        public float hdrPeakNits = 1000.0f;
        public ThermalMode thermalMode = ThermalMode.BALANCED;
        public boolean lowLatencyQueue = true;
        public boolean promotionFramePacing = true;
        public HudMode performanceHud = HudMode.COMPACT;
    }

    public static final class ShadersSection {
        public String activePackId = "builtin:celestia-native";
        public String activePreset = "Balanced";
        public boolean binaryPipelineCache = true;
        public boolean hotReloadOnFocus = false;
    }

    public static final class AdvancedSection {
        public boolean validationLabels = false;
        public boolean dumpTranslatedMsl = false;
        public int shaderCompileThreads = 2;
        public boolean showStartupToast = true;
    }

    public QualitySection quality = new QualitySection();
    public PerformanceSection performance = new PerformanceSection();
    public AppleSiliconSection appleSilicon = new AppleSiliconSection();
    public ShadersSection shaders = new ShadersSection();
    public AdvancedSection advanced = new AdvancedSection();

    public static CelestiaConfig get() {
        CelestiaConfig cur = instance;
        if (cur == null) {
            synchronized (CelestiaConfig.class) {
                if (instance == null) {
                    instance = load(defaultPath());
                }
                cur = instance;
            }
        }
        return cur;
    }

    public static Path defaultPath() {
        return Path.of("config", "celestia-metal.json");
    }

    public static CelestiaConfig load(Path path) {
        if (path != null && Files.exists(path)) {
            try {
                String json = Files.readString(path);
                CelestiaConfig loaded = GSON.fromJson(json, CelestiaConfig.class);
                if (loaded != null) {
                    loaded.ensureNonNullSections();
                    return loaded;
                }
            } catch (Exception ignored) {
            }
        }
        CelestiaConfig fresh = new CelestiaConfig();
        fresh.ensureNonNullSections();
        return fresh;
    }

    public void ensureNonNullSections() {
        if (quality == null) quality = new QualitySection();
        if (performance == null) performance = new PerformanceSection();
        if (appleSilicon == null) appleSilicon = new AppleSiliconSection();
        if (shaders == null) shaders = new ShadersSection();
        if (advanced == null) advanced = new AdvancedSection();
        appleSilicon.renderScalePercent = Math.clamp(appleSilicon.renderScalePercent, 50, 100);
        appleSilicon.hdrPeakNits = Math.clamp(appleSilicon.hdrPeakNits, 400.0f, 1600.0f);
        performance.terrainLodRadiusPercent = Math.clamp(performance.terrainLodRadiusPercent, 40, 100);
        performance.maxChunkUploadsPerFrame = Math.clamp(performance.maxChunkUploadsPerFrame, 1, 16);
        advanced.shaderCompileThreads = Math.clamp(advanced.shaderCompileThreads, 1, 8);
    }

    public void save() {
        save(defaultPath());
    }

    public void save(Path path) {
        ensureNonNullSections();
        try {
            if (path.getParent() != null) Files.createDirectories(path.getParent());
            Path tmp = Files.createTempFile(path.getParent() != null ? path.getParent() : Path.of("."), "celestia-cfg-", ".tmp");
            Files.writeString(tmp, GSON.toJson(this));
            Files.move(tmp, path, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException ignored) {
        }
    }

    public CelestiaConfig copy() {
        CelestiaConfig c = GSON.fromJson(GSON.toJson(this), CelestiaConfig.class);
        c.ensureNonNullSections();
        return c;
    }

    public static void replace(CelestiaConfig next) {
        next.ensureNonNullSections();
        instance = next;
        next.save();
    }
}
