package dev.celestia.metal;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import dev.celestia.metal.shade.ShadeSettings;
import dev.celestia.metal.shade.water.ShadeWater;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.*;

@EnabledOnOs(OS.MAC)
class ShadeP3aTest {

    @Test
    void shadeWaterParamsLayoutAndTranslucentPipelineDetection() {
        assertEquals(176, ShadeWater.PARAMS_BYTES);
        ByteBuffer b = ByteBuffer.allocateDirect(ShadeWater.PARAMS_BYTES).order(ByteOrder.LITTLE_ENDIAN);
        ShadeWater.packParams(b, new float[] {0.1f, 0.2f, 0.3f, 0.4f}, new float[] {0.5f, 0.6f, 0.7f, 0.8f},
            true, 3.5f, 0.75f, true, true, new ShadeSettings.Water(
                true, true, 1.2f, 0.9f, true, false, 0.8f, 16, 96, 0.4f, 1f, true));
        assertEquals(1, b.getInt(164)); // quality.y: Snell's window
        assertEquals(0.1f, b.getFloat(0), 1e-6f);
        assertEquals(0.8f, b.getFloat(28), 1e-6f);
        assertEquals(1.0f, b.getFloat(32), 1e-6f); // state.x
        assertEquals(3.5f, b.getFloat(36), 1e-6f); // surfaceAbove
        assertEquals(0.75f, b.getFloat(40), 1e-6f); // wetness
        assertEquals(1.0f, b.getFloat(44), 1e-6f); // baked waves valid
        assertEquals(96f, b.getFloat(52));
        assertEquals(0.8f, b.getFloat(56));
        assertEquals(0.4f, b.getFloat(60));
        assertEquals(16, b.getInt(160));
        assertEquals(1.0f, b.getFloat(156), 1e-6f); // baked swell valid

        assertTrue(ShadeShaderPatcher.isTranslucentTerrainPipelineName("minecraft:pipeline/translucent_terrain"));
        assertTrue(ShadeShaderPatcher.isTranslucentTerrainPipelineName("minecraft:pipeline/translucent_terrain_multidraw"));
        assertTrue(ShadeShaderPatcher.isTranslucentTerrainPipelineName("sodium:pipeline/translucent_terrain"));
        assertFalse(ShadeShaderPatcher.isTranslucentTerrainPipelineName("minecraft:pipeline/translucent_terrain_oit"));
        assertFalse(ShadeShaderPatcher.isTranslucentTerrainPipelineName("minecraft:pipeline/solid_terrain"));
    }

    @ParameterizedTest
    @ValueSource(booleans = {true, false})
    void waterBakeAndVanillaSodiumTranslucentShadersCompileOnMetal(boolean preferMetal4) {
        String vanillaVs = """
            #include <metal_stdlib>
            using namespace metal;
            struct Fog { float FogEnvironmentalStart; float FogEnvironmentalEnd; float FogRenderDistanceStart; float FogRenderDistanceEnd; float4 FogColor; };
            struct DynamicTransforms { float4x4 ModelViewMat; };
            struct Projection { float4x4 ProjMat; };
            struct main0_in {
                float3 Position [[attribute(0)]];
                float4 Color [[attribute(1)]];
                float2 UV0 [[attribute(2)]];
                int2 UV2 [[attribute(3)]];
            };
            struct main0_out {
                float4 vertexColor [[user(locn0)]];
                float2 texCoord0 [[user(locn1)]];
                float4 gl_Position [[position]];
            };
            vertex main0_out main0(main0_in in [[stage_in]], constant DynamicTransforms& DynamicTransforms [[buffer(0)]], constant Projection& Projection [[buffer(1)]]) {
                main0_out out = {};
                out.gl_Position = Projection.ProjMat * (DynamicTransforms.ModelViewMat * float4(in.Position, 1.0));
                out.vertexColor = in.Color;
                out.texCoord0 = in.UV0;
                out.gl_Position.y = -(out.gl_Position.y);
                return out;
            }
            """;
        String vanillaFs = """
            #include <metal_stdlib>
            using namespace metal;
            struct Fog { float FogEnvironmentalStart; float FogEnvironmentalEnd; float FogRenderDistanceStart; float FogRenderDistanceEnd; float4 FogColor; };
            struct main0_in {
                float4 vertexColor [[user(locn0)]];
                float2 texCoord0 [[user(locn1)]];
            };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]], constant Fog& Fog [[buffer(0)]],
                                   texture2d<float> Sampler0 [[texture(0)]], sampler Sampler0Smplr [[sampler(0)]]) {
                main0_out out = {};
                float4 color = Sampler0.sample(Sampler0Smplr, in.texCoord0) * in.vertexColor;
                out.fragColor = color;
                return out;
            }
            """;

        String sodiumVs = """
            #include <metal_stdlib>
            using namespace metal;
            struct u_Globals { float4 u_EnvironmentFog; float4 u_RenderFog; };
            struct main0_in {
                float3 a_PosId [[attribute(0)]];
                float4 a_Color [[attribute(1)]];
                float2 a_TexCoord [[attribute(2)]];
                int2 a_LightAndData [[attribute(3)]];
            };
            struct main0_out {
                float4 v_Color [[user(locn0)]];
                float2 v_TexCoord [[user(locn1)]];
                float4 gl_Position [[position]];
            };
            vertex main0_out main0(main0_in in [[stage_in]], constant u_Globals& _globals [[buffer(0)]]) {
                main0_out out = {};
                out.gl_Position = float4(in.a_PosId, 1.0);
                out.v_Color = in.a_Color;
                out.v_TexCoord = in.a_TexCoord;
                out.gl_Position.y = -(out.gl_Position.y);
                return out;
            }
            """;
        String sodiumFs = """
            #include <metal_stdlib>
            using namespace metal;
            struct u_Globals { float4 u_EnvironmentFog; float4 u_RenderFog; };
            struct main0_in {
                float4 v_Color [[user(locn0)]];
                float2 v_TexCoord [[user(locn1)]];
            };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]], constant u_Globals& _globals [[buffer(0)]],
                                   texture2d<float> u_BlockTex [[texture(0)]], sampler u_BlockTexSmplr [[sampler(0)]]) {
                main0_out out = {};
                float4 color = u_BlockTex.sample(u_BlockTexSmplr, in.v_TexCoord);
                color *= in.v_Color;
                out.fragColor = color;
                return out;
            }
            """;

        List<BindGroupLayout.UniformDescription> emptyU = List.of();
        List<dev.celestia.metal.backend.MetalShaderTranslator.SlotBinding> emptyB = List.of();

        var patchedVan = ShadeShaderPatcher.patch("minecraft:pipeline/translucent_terrain",
            vanillaVs, "main0", vanillaFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(patchedVan.patched());
        assertFalse(ShadeShaderPatcher.isOpaqueOrCutoutTerrain("minecraft:pipeline/translucent_terrain", vanillaVs));

        var patchedSod = ShadeShaderPatcher.patch("sodium:pipeline/translucent_terrain",
            sodiumVs, "main0", sodiumFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(patchedSod.patched());
        assertFalse(ShadeShaderPatcher.isOpaqueOrCutoutTerrain("sodium:pipeline/translucent_terrain", sodiumVs));

        var leanVan = ShadeShaderPatcher.patch("minecraft:pipeline/translucent_terrain",
            vanillaVs, "main0", vanillaFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD_WATER_ABOVE);
        var leanSod = ShadeShaderPatcher.patch("sodium:pipeline/translucent_terrain",
            sodiumVs, "main0", sodiumFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD_WATER_ABOVE);
        var skyVan = ShadeShaderPatcher.patch("minecraft:pipeline/translucent_terrain",
            vanillaVs, "main0", vanillaFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD_WATER_SKY_ONLY);
        var skySod = ShadeShaderPatcher.patch("sodium:pipeline/translucent_terrain",
            sodiumVs, "main0", sodiumFs, "main0", emptyU, emptyB, ShadeShaderPatcher.Variant.HDR_WORLD_WATER_ABOVE_SKY_ONLY);
        var skyBuiltInPerformance = ShadeShaderPatcher.patch("minecraft:pipeline/translucent_terrain",
            vanillaVs, "main0", vanillaFs, "main0", emptyU, emptyB,
            ShadeShaderPatcher.Variant.HDR_WORLD_WATER_ABOVE_FAST_SKY_NO_SWELL_CAUSTICS);
        assertTrue(leanVan.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertTrue(leanSod.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertFalse(patchedVan.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertFalse(patchedSod.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertTrue(skyVan.patched());
        assertTrue(skySod.patched());
        assertFalse(skyVan.fsSource().contains("#define SHADE_SSR 1"));
        assertFalse(skySod.fsSource().contains("#define SHADE_SSR 1"));
        assertFalse(skyVan.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertTrue(skySod.fsSource().contains("#define SHADE_LEAN_ABOVE 1"));
        assertTrue(skyBuiltInPerformance.patched());
        assertTrue(skyBuiltInPerformance.fsSource().contains("#undef SHADE_WATER_SWELL\n#undef SHADE_CAUSTICS"));
        assertTrue(skyBuiltInPerformance.fsSource().contains("#define SHADE_WOFF_FAST 1"));

        long ctx = MetalNative.deviceCreate(preferMetal4, false, "");
        assertNotEquals(0L, ctx);
        try {
            StringBuilder err = new StringBuilder();
            long libBake = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.waterBakeSource(), "p3a.bake", true, err);
            assertNotEquals(0L, libBake, () -> err.toString());

            long vsFn = MetalNative.compileFunction(libBake, "shade_fs_vs", false, 0, 0, err);
            long bFn = MetalNative.compileFunction(libBake, "shade_water_bake_fs", false, 0, 0, err);
            long dFn = MetalNative.compileFunction(libBake, "shade_water_bake_detail_fs", false, 0, 0, err);
            long sFn = MetalNative.compileFunction(libBake, "shade_water_bake_swell_fs", false, 0, 0, err);
            long p1Fn = MetalNative.compileFunction(libBake, "shade_water_pyr_fs", false, 0, 0, err);
            long p2Fn = MetalNative.compileFunction(libBake, "shade_water_pyr2_fs", false, 0, 0, err);
            assertTrue(vsFn != 0 && bFn != 0 && dFn != 0 && sFn != 0 && p1Fn != 0 && p2Fn != 0, () -> err.toString());

            long libVanVs = MetalNative.compileMslLibrary(ctx, patchedVan.vsSource(), "p3a.van.vs", false, err);
            assertNotEquals(0L, libVanVs, () -> err.toString());
            long libVanFs = MetalNative.compileMslLibrary(ctx, patchedVan.fsSource(), "p3a.van.fs", false, err);
            assertNotEquals(0L, libVanFs, () -> err.toString());

            long libSodVs = MetalNative.compileMslLibrary(ctx, patchedSod.vsSource(), "p3a.sod.vs", false, err);
            assertNotEquals(0L, libSodVs, () -> err.toString());
            long libSodFs = MetalNative.compileMslLibrary(ctx, patchedSod.fsSource(), "p3a.sod.fs", false, err);
            assertNotEquals(0L, libSodFs, () -> err.toString());

            long leanVanFs = MetalNative.compileMslLibrary(ctx, leanVan.fsSource(), "p3a.van.above", false, err);
            assertNotEquals(0L, leanVanFs, () -> err.toString());
            long leanSodFs = MetalNative.compileMslLibrary(ctx, leanSod.fsSource(), "p3a.sod.above", false, err);
            assertNotEquals(0L, leanSodFs, () -> err.toString());
            long skyVanFs = MetalNative.compileMslLibrary(ctx, skyVan.fsSource(), "p3a.van.sky", false, err);
            assertNotEquals(0L, skyVanFs, () -> err.toString());
            long skySodFs = MetalNative.compileMslLibrary(ctx, skySod.fsSource(), "p3a.sod.above.sky", false, err);
            assertNotEquals(0L, skySodFs, () -> err.toString());
            long skyPerformanceFs = MetalNative.compileMslLibrary(ctx, skyBuiltInPerformance.fsSource(),
                "p3a.van.above.sky.no-swell-caustics", false, err);
            assertNotEquals(0L, skyPerformanceFs, () -> err.toString());

            MetalNative.waterGenerateMipmaps(ctx, 0L, 0L, 0L);
            MetalNative.libraryDestroy(skyPerformanceFs);
            MetalNative.libraryDestroy(skySodFs);
            MetalNative.libraryDestroy(skyVanFs);
            MetalNative.libraryDestroy(leanSodFs);
            MetalNative.libraryDestroy(leanVanFs);
            MetalNative.libraryDestroy(libSodFs);
            MetalNative.libraryDestroy(libSodVs);
            MetalNative.libraryDestroy(libVanFs);
            MetalNative.libraryDestroy(libVanVs);
            MetalNative.functionDestroy(p2Fn);
            MetalNative.functionDestroy(p1Fn);
            MetalNative.functionDestroy(sFn);
            MetalNative.functionDestroy(dFn);
            MetalNative.functionDestroy(bFn);
            MetalNative.functionDestroy(vsFn);
            MetalNative.libraryDestroy(libBake);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }
}
