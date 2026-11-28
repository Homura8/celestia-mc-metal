package dev.celestia.metal;

import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.pipeline.BlendFactor;
import com.mojang.renderpearl.api.pipeline.BlendOp;
import com.mojang.renderpearl.api.pipeline.CompareOp;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.StartupGuard;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.perf.PerformanceEngine;
import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.ui.CelestiaWidgets;
import dev.celestia.metal.ui.OptionEntry;
import java.nio.file.Path;
import net.minecraft.client.PreferredGraphicsApi;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class ConfigAndUiTest {

    @Test
    void renderScaleRespectsTheConfiguredLimitBeforeTheFirstFrame() {
        var cfg = CelestiaConfig.get().appleSilicon;
        int previousScale = cfg.renderScalePercent;
        boolean previousAutoScale = cfg.autoRenderScale;
        try {
            cfg.autoRenderScale = true;
            cfg.renderScalePercent = 75;
            assertEquals(75, PerformanceEngine.get().effectiveRenderScalePercent());
            cfg.renderScalePercent = 55;
            assertEquals(55, PerformanceEngine.get().effectiveRenderScalePercent());
            cfg.autoRenderScale = false;
            cfg.renderScalePercent = 80;
            assertEquals(80, PerformanceEngine.get().effectiveRenderScalePercent());
        } finally {
            cfg.renderScalePercent = previousScale;
            cfg.autoRenderScale = previousAutoScale;
        }
    }

    @Test
    void configRoundTripsAndClampsBounds(@TempDir Path tmpDir) {
        Path cfgFile = tmpDir.resolve("celestia-metal.json");
        CelestiaConfig cfg = new CelestiaConfig();
        cfg.appleSilicon.renderScalePercent = 150; // above max 100
        cfg.appleSilicon.hdrPeakNits = 2400.0f;  // above max 1600
        cfg.performance.maxChunkUploadsPerFrame = 0; // below min 1
        cfg.appleSilicon.metalMode = CelestiaConfig.MetalMode.METAL_4;
        cfg.save(cfgFile);

        CelestiaConfig loaded = CelestiaConfig.load(cfgFile);
        assertEquals(100, loaded.appleSilicon.renderScalePercent);
        assertEquals(1600.0f, loaded.appleSilicon.hdrPeakNits);
        assertEquals(1, loaded.performance.maxChunkUploadsPerFrame);
        assertEquals(CelestiaConfig.MetalMode.METAL_4, loaded.appleSilicon.metalMode);
    }

    @Test
    void encoderOptimizationTogglesDefaultOnAndRoundTrip(@TempDir Path tmpDir) throws Exception {
        CelestiaConfig fresh = new CelestiaConfig();
        assertTrue(fresh.performance.renderPassMerging);
        assertTrue(fresh.performance.deferredClears);

        // Configs written before these options existed must keep the optimizations enabled
        Path legacy = tmpDir.resolve("legacy.json");
        java.nio.file.Files.writeString(legacy, "{\"performance\":{\"bufferPooling\":false}}");
        CelestiaConfig loadedLegacy = CelestiaConfig.load(legacy);
        assertTrue(loadedLegacy.performance.renderPassMerging);
        assertTrue(loadedLegacy.performance.deferredClears);

        fresh.performance.renderPassMerging = false;
        fresh.performance.deferredClears = false;
        Path file = tmpDir.resolve("toggles.json");
        fresh.save(file);
        CelestiaConfig reloaded = CelestiaConfig.load(file);
        assertFalse(reloaded.performance.renderPassMerging);
        assertFalse(reloaded.performance.deferredClears);
    }

    @Test
    void startupGuardCreatesAndClearsLock(@TempDir Path gameDir) {
        StartupGuard.begin(PreferredGraphicsApi.DEFAULT, gameDir);
        assertTrue(StartupGuard.isAttemptingMetal());
        StartupGuard.markStartupSuccess(gameDir);
        assertFalse(StartupGuard.isAttemptingMetal());
    }

    @Test
    void metalConstMappingsCoverRenderPearlFormats() {
        assertEquals(MetalConst.FMT_RGBA16_FLOAT, MetalConst.toNativeFormat(GpuFormat.RGBA16_FLOAT));
        assertEquals(MetalConst.FMT_D32_FLOAT, MetalConst.toNativeFormat(GpuFormat.D32_FLOAT));
        assertEquals(5, MetalConst.toNativeCompare(CompareOp.GREATER_THAN_OR_EQUAL));
        assertEquals(7, MetalConst.toNativeBlendFactor(BlendFactor.ONE_MINUS_SRC_ALPHA));
        assertEquals(0, MetalConst.toNativeBlendOp(BlendOp.ADD));
        assertEquals(3, MetalConst.toNativeTopology(PrimitiveTopology.TRIANGLES));
        assertThrows(IllegalArgumentException.class, () -> MetalConst.toNativeFormat(GpuFormat.RGB8_UNORM));
        assertThrows(IllegalArgumentException.class, () -> MetalConst.toNativeFormat(GpuFormat.RGB32_FLOAT));

        // Metal supports all 3-component vertex attribute formats even though 3-component textures are disallowed.
        GpuFormat[] supportedVertexRgb = {
            GpuFormat.RGB8_UNORM, GpuFormat.RGB8_SNORM,
            GpuFormat.RGB16_UNORM, GpuFormat.RGB16_SNORM,
            GpuFormat.RGB8_UINT, GpuFormat.RGB8_SINT,
            GpuFormat.RGB16_UINT, GpuFormat.RGB16_SINT,
            GpuFormat.RGB32_UINT, GpuFormat.RGB32_SINT,
            GpuFormat.RGB16_FLOAT, GpuFormat.RGB32_FLOAT
        };
        for (GpuFormat fmt : supportedVertexRgb) {
            assertTrue(MetalConst.toNativeVertexFormat(fmt) >= MetalConst.FMT_RGB8_UNORM,
                "Expected valid native vertex format for " + fmt);
        }
        assertEquals(MetalConst.FMT_RGB32_FLOAT, MetalConst.toNativeVertexFormat(GpuFormat.RGB32_FLOAT));
        assertEquals(MetalConst.FMT_RGBA8_UNORM, MetalConst.toNativeVertexFormat(GpuFormat.RGBA8_UNORM));
        assertEquals(MetalConst.FMT_R16_FLOAT, MetalConst.toNativeVertexFormat(GpuFormat.R16_FLOAT));
    }

    @Test
    void optionEntrySearchMatchesLabelAndDescription() {
        OptionEntry entry = new OptionEntry.Toggle(
            "HDR / EDR Highlights",
            "Extended Linear Display P3 swapchain for XDR displays.",
            ShaderOptionDef.Impact.LOW,
            () -> true,
            v -> {}
        );
        assertTrue(entry.matches("edr"));
        assertTrue(entry.matches("display p3"));
        assertFalse(entry.matches("shadows"));
    }

    @Test
    void proportionalWidthDistributionFitsAndPreservesHierarchy() {
        int[] labels = {42, 40, 66, 70, 42, 50};
        // Wide layout fills full bar cleanly
        int[] wide = CelestiaWidgets.distributeWidths(labels, 600, 4, 8, 16);
        assertEquals(600, java.util.Arrays.stream(wide).sum() + 4 * 5);
        assertTrue(wide[2] > wide[0]);

        // Narrow 427px window layout still never exceeds available width
        int[] narrow = CelestiaWidgets.distributeWidths(labels, 411, 4, 8, 16);
        assertTrue(java.util.Arrays.stream(narrow).sum() + 4 * 5 <= 411);
        assertTrue(narrow[3] >= labels[3] + 8);
    }
}
