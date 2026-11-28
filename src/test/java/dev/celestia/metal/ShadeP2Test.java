package dev.celestia.metal;

import com.mojang.renderpearl.backend.util.TransientBlockAllocator;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import dev.celestia.metal.shade.shadow.ShadowCascade;
import dev.celestia.metal.shade.shadow.ShadowCasterSource;
import dev.celestia.metal.shade.shadow.SodiumShadowCasters;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import static org.junit.jupiter.api.Assertions.*;

@EnabledOnOs(OS.MAC)
class ShadeP2Test {

    @Test
    void shadowCascadeSnappingDepthAndCulling() {
        double[] light = {0.3, 0.9, 0.2};
        double len = Math.sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]);
        light[0] /= len;
        light[1] /= len;
        light[2] /= len;

        ShadowCascade c1 = new ShadowCascade();
        ShadowCascade c2 = new ShadowCascade();
        double texel = 2.0 * 32.0 / 2048.0;
        // Center point inside the texel cell so sub-texel perturbations stay in the same snapped cell
        double baseX = 100.0, baseY = 64.0, baseZ = -50.0;
        c1.fit(light, baseX, baseY, baseZ, 32.0, 2048, 96.0, 32.0, 192.0);
        double uFrac = (baseX * c1.x[0] + baseY * c1.x[1] + baseZ * c1.x[2] - c1.u0) / texel;
        double delta = (0.5 - uFrac) * texel; // move exactly to cell center + 0.25 texel
        c1.fit(light, baseX + c1.x[0] * delta, baseY + c1.x[1] * delta, baseZ + c1.x[2] * delta,
            32.0, 2048, 96.0, 32.0, 192.0);
        c2.fit(light, baseX + c1.x[0] * (delta + texel * 0.25),
            baseY + c1.x[1] * (delta + texel * 0.25),
            baseZ + c1.x[2] * (delta + texel * 0.25),
            32.0, 2048, 96.0, 32.0, 192.0);
        assertEquals(c1.u0, c2.u0, 1e-6);
        assertEquals(c1.v0, c2.v0, 1e-6);

        // Check reversed-Z matrix maps camera center to z in (0, 1) and points closer to light to higher z
        float[] m = new float[16];
        c1.matrix(100.0, 64.0, -50.0, m, 0);
        float zCam = m[14];
        float zTowardLight = m[2] * (float) (light[0] * 10.0) + m[6] * (float) (light[1] * 10.0)
            + m[10] * (float) (light[2] * 10.0) + m[14];
        assertTrue(zCam > 0.0f && zCam < 1.0f);
        assertTrue(zTowardLight > zCam);

        // AABB inside vs far outside cascade
        assertTrue(c1.casts(96.0, 60.0, -54.0, 112.0, 76.0, -38.0));
        assertFalse(c1.casts(500.0, 60.0, 500.0, 516.0, 76.0, 516.0));
    }

    @Test
    void shadowShadersCompileForD16AndD32OnMetal() {
        long ctx = MetalNative.deviceCreate(true, false, "");
        assertNotEquals(0L, ctx);
        try {
            StringBuilder err = new StringBuilder();
            long libSod = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.shadowSodiumSource(), "test.shd.sod", true, err);
            assertNotEquals(0L, libSod, () -> err.toString());
            long libVan = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.shadowVanillaSource(), "test.shd.van", true, err);
            assertNotEquals(0L, libVan, () -> err.toString());

            long vsSod = MetalNative.compileFunction(libSod, "shadow_vs", false, 0, 0, err);
            long vsSodC = MetalNative.compileFunction(libSod, "shadow_cutout_vs", false, 0, 0, err);
            long fsSodC = MetalNative.compileFunction(libSod, "shadow_cutout_fs", false, 0, 0, err);
            long vsVan = MetalNative.compileFunction(libVan, "shadow_vanilla_vs", false, 0, 0, err);
            long vsVanC = MetalNative.compileFunction(libVan, "shadow_vanilla_cutout_vs", false, 0, 0, err);
            long fsVanC = MetalNative.compileFunction(libVan, "shadow_vanilla_cutout_fs", false, 0, 0, err);
            assertTrue(vsSod != 0 && vsSodC != 0 && fsSodC != 0 && vsVan != 0 && vsVanC != 0 && fsVanC != 0);

            int[] depthFmts = {MetalConst.FMT_D16_UNORM, MetalConst.FMT_D32_FLOAT};
            for (int fmt : depthFmts) {
                long p1 = ShadowCasterSource.createDepthPso(ctx, vsSod, 0L, fmt, "p1", err);
                long p2 = ShadowCasterSource.createDepthPso(ctx, vsSodC, fsSodC, fmt, "p2", err);
                long p3 = ShadowCasterSource.createDepthPso(ctx, vsVan, 0L, fmt, "p3", err);
                long p4 = ShadowCasterSource.createDepthPso(ctx, vsVanC, fsVanC, fmt, "p4", err);
                assertTrue(p1 != 0 && p2 != 0 && p3 != 0 && p4 != 0, () -> err.toString());
                MetalNative.pipelineDestroy(ctx, p4);
                MetalNative.pipelineDestroy(ctx, p3);
                MetalNative.pipelineDestroy(ctx, p2);
                MetalNative.pipelineDestroy(ctx, p1);
            }

            MetalNative.functionDestroy(fsVanC);
            MetalNative.functionDestroy(vsVanC);
            MetalNative.functionDestroy(vsVan);
            MetalNative.functionDestroy(fsSodC);
            MetalNative.functionDestroy(vsSodC);
            MetalNative.functionDestroy(vsSod);
            MetalNative.libraryDestroy(libVan);
            MetalNative.libraryDestroy(libSod);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }

    @Test
    void transientBlockAllocatorBoundaryDoesNotDivideByZero() {
        long blockSize = 4L * 1024L * 1024L;
        try (var allocator = new TransientBlockAllocator<>(
            blockSize, 256L, TransientBlockAllocator.Allocator.CpuBlock.memalloc())) {
            // Allocate chunks that fill almost all of the 4 MiB block, then cross into a second block
            long chunk = 1024L * 1024L;
            var a1 = allocator.allocate(chunk, 16L, chunk, 1L);
            var a2 = allocator.allocate(chunk, 16L, chunk, 1L);
            var a3 = allocator.allocate(chunk, 16L, chunk, 1L);
            var a4 = allocator.allocate(chunk - 256L, 16L, chunk - 256L, 1L);
            // Only 256 bytes remain in block 1; next 1 MiB allocation hits the current-block boundary path
            var cross = allocator.allocate(chunk, 16L, chunk, 1L);
            assertNotNull(a1);
            assertNotNull(a2);
            assertNotNull(a3);
            assertNotNull(a4);
            assertNotNull(cross);
            assertNotSame(a1.block(), cross.block());
        }
    }

    @Test
    void sodiumShadowRingSlotsExceedInFlightCascades() {
        assertTrue(SodiumShadowCasters.RING_SLOTS >= 16);
        assertEquals(0, SodiumShadowCasters.RING_SLOTS & (SodiumShadowCasters.RING_SLOTS - 1));
    }
}
