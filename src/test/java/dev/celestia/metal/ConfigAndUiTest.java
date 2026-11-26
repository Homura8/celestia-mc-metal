package dev.celestia.metal;

import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.pipeline.BlendFactor;
import com.mojang.renderpearl.api.pipeline.BlendOp;
import com.mojang.renderpearl.api.pipeline.CompareOp;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.StartupGuard;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.ui.OptionEntry;
import java.nio.file.Path;
import net.minecraft.client.PreferredGraphicsApi;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class ConfigAndUiTest {

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
}
