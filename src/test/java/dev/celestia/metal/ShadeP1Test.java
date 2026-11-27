package dev.celestia.metal;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.UniformType;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.backend.MetalShaderTranslator;
import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeLook;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import dev.celestia.metal.shade.ShadeSky;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;
import org.joml.Matrix4f;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import static org.junit.jupiter.api.Assertions.*;

@EnabledOnOs(OS.MAC)
class ShadeP1Test {

    @Test
    void shadeFrameAndLookStructLayoutsMatchMsl() {
        assertEquals(1024, ShadeFrame.SIZE);
        assertEquals(1136, ShadeLook.SIZE);

        ShadeFrame frame = new ShadeFrame();
        frame.view.identity();
        frame.proj.perspective((float) Math.toRadians(70.0), 16f / 9f, 0.05f, 256f);
        frame.proj.mul(frame.view, frame.viewProj);
        frame.viewProj.invert(frame.invViewProj);
        frame.cameraX = 123.75;
        frame.cameraY = 68.25;
        frame.cameraZ = -44.5;
        frame.width = 1920;
        frame.height = 1080;
        frame.sunDir.set(0.0f, 0.8f, 0.6f).normalize();
        frame.moonDir.set(0.0f, -0.8f, -0.6f).normalize();
        frame.updateAtmosphere(0.016f, true);

        ShadeLook look = new ShadeLook();
        look.update(frame, 0, 0.016f);

        ByteBuffer fb = ByteBuffer.allocateDirect(ShadeFrame.SIZE).order(ByteOrder.LITTLE_ENDIAN);
        frame.pack(fb);
        assertEquals(123.0f, fb.getFloat(ShadeFrame.CAMERA_BLOCK), 1e-5f);
        assertEquals(0.75f, fb.getFloat(ShadeFrame.CAMERA_FRACT), 1e-5f);
        assertEquals(1920f, fb.getFloat(ShadeFrame.SCREEN), 1e-5f);
        assertEquals(1080f, fb.getFloat(ShadeFrame.SCREEN + 4), 1e-5f);
        assertEquals(ShadeFrame.DIM_OVERWORLD, fb.getInt(ShadeFrame.FLAGS));

        ByteBuffer lb = ByteBuffer.allocateDirect(ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
        look.pack(lb, frame);
        assertTrue(Float.isFinite(lb.getFloat(ShadeLook.TONEMAP)));
        assertTrue(Float.isFinite(lb.getFloat(ShadeLook.EXPOSURE_REF)));
        assertNotEquals(0, lb.getInt(ShadeLook.TIER + 4));
    }

    @Test
    void shadeSkyAndLottesDisplayInverseRoundTrip() {
        double[] dir = new double[3];
        ShadeSky.celestial(0.0, dir);
        assertEquals(0.0, dir[0], 1e-6);
        assertTrue(dir[1] > 0.5 && dir[2] > 0.0); // tilted noon sun

        ShadeFrame frame = new ShadeFrame();
        frame.sunDir.set(0.2f, 0.6f, 0.4f).normalize();
        frame.moonDir.set(-0.2f, -0.6f, -0.4f).normalize();
        frame.updateAtmosphere(0.016f, true);
        assertTrue(frame.sky.sunLight);
        assertTrue(frame.sky.light[0] > 0f && frame.sky.sceneLuma > 0f);

        ShadeLook look = new ShadeLook();
        look.update(frame, 0, 0.016f);
        // sRGB (0.5, 0.3, 0.8) -> scene-linear HDR -> display -> sRGB round-trip check
        float[] hdr = look.ldrToHdr(0.5f, 0.3f, 0.8f);
        assertTrue(hdr[0] >= 0f && hdr[1] >= 0f && hdr[2] >= 0f);
        float[] disp = look.display(hdr);
        for (int i = 0; i < 3; i++) {
            float targetLin = (float) Math.pow(((i == 0 ? 0.5f : i == 1 ? 0.3f : 0.8f) + 0.055f) / 1.055f, 2.4);
            assertEquals(targetLin, disp[i], 0.015f);
        }
    }

    @Test
    void slotDefinesAndShaderPatcherSupportVanillaSodiumEntityAndSky() {
        List<BindGroupLayout.UniformDescription> uniforms = List.of(
            new BindGroupLayout.UniformDescription("Fog", UniformType.UNIFORM_BUFFER),
            new BindGroupLayout.UniformDescription("DynamicTransforms", UniformType.UNIFORM_BUFFER),
            new BindGroupLayout.UniformDescription("Projection", UniformType.UNIFORM_BUFFER),
            new BindGroupLayout.UniformDescription("Sampler0", UniformType.COMBINED_IMAGE_SAMPLER)
        );
        List<MetalShaderTranslator.SlotBinding> bindings = MetalShaderTranslator.buildBindings(uniforms);
        String defines = MetalShaderTranslator.slotDefines(uniforms, bindings);
        assertTrue(defines.contains("#define CELESTIA_BUF_Fog 0"));
        assertTrue(defines.contains("#define CELESTIA_BUF_DynamicTransforms 1"));
        assertTrue(defines.contains("#define CELESTIA_BUF_Projection 2"));
        assertTrue(defines.contains("#define CELESTIA_TEX_Sampler0 0"));
        assertTrue(defines.contains("#define CELESTIA_SAMP_Sampler0 0"));

        String dummyVs = """
            struct main0_in { float3 Position [[attribute(0)]]; float4 Color [[attribute(1)]]; };
            struct main0_out { float4 gl_Position [[position]]; };
            vertex main0_out main0(main0_in in [[stage_in]]) {
                main0_out out = {};
                out.gl_Position = float4(in.Position, 1.0);
                out.gl_Position.y = -(out.gl_Position.y);
                return out;
            }
            """;
        String dummyFs = """
            struct main0_in { float4 v [[user(locn0)]]; };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]]) {
                main0_out out = {};
                out.fragColor = float4(0.5, 0.5, 0.5, 1.0);
                return out;
            }
            """;

        // Generic HDR fallback
        var skyRes = ShadeShaderPatcher.patch("minecraft:pipeline/sky", dummyVs, "main0", dummyFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(skyRes.patched());
        assertTrue(skyRes.vsSource().contains("shadeViewRay"));
        assertTrue(skyRes.fsSource().contains("shadeSkyPixel"));

        // Vanilla terrain patching
        String vanillaTerrainVs = """
            #include <metal_stdlib>
            using namespace metal;
            struct Transforms { float4x4 ProjMat; float4x4 ModelViewMat; };
            struct main0_in { float3 Position [[attribute(0)]]; float4 Color [[attribute(1)]]; int2 UV2 [[attribute(3)]]; };
            struct main0_out { float chunkVisibility [[user(locn4)]]; float4 gl_Position [[position]]; };
            vertex main0_out main0(main0_in in [[stage_in]], constant Transforms& _19 [[buffer(0)]]) {
                main0_out out = {};
                float3 pos = in.Position;
                out.gl_Position = (_19.ProjMat * _19.ModelViewMat) * float4(pos, 1.0);
                out.gl_Position.y = -(out.gl_Position.y);
                out.chunkVisibility = 1.0;
                return out;
            }
            """;
        String vanillaTerrainFs = """
            #include <metal_stdlib>
            using namespace metal;
            struct Fog { float4 FogColor; float FogEnvironmentalStart; float FogEnvironmentalEnd; float FogRenderDistanceStart; float FogRenderDistanceEnd; };
            struct main0_in { float4 vertexColor [[user(locn2)]]; float2 texCoord0 [[user(locn3)]]; float chunkVisibility [[user(locn4)]]; };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]], constant Fog& _22 [[buffer(0)]], texture2d<float> Sampler0 [[texture(0)]], sampler Sampler0Smplr [[sampler(0)]]) {
                main0_out out = {};
                float4 color = Sampler0.sample(Sampler0Smplr, in.texCoord0) * in.vertexColor;
                out.fragColor = color;
                return out;
            }
            """;
        var vanRes = ShadeShaderPatcher.patch("minecraft:pipeline/solid_terrain", vanillaTerrainVs, "main0", vanillaTerrainFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(vanRes.patched());
        assertTrue(vanRes.vsSource().contains("float2(in.UV2) * (1.0 / 240.0)"));
        assertTrue(vanRes.fsSource().contains("shadeTerrainShade("));
        // P6a / P6b: the dynamic-light and coloured-light bindings reach the terrain fragment main.
        assertTrue(vanRes.fsSource().contains("celDL [[buffer(29)]]"));
        assertTrue(vanRes.fsSource().contains("celCL [[buffer(30)]]"));
        assertTrue(vanRes.fsSource().contains("shadeColorLightFrag("));
        assertTrue(vanRes.fsSource().contains("celClLevels [[texture(28)]]"));
        assertTrue(vanRes.fsSource().contains("shadeSmoothBlock("));

        // Sodium 0.9.x terrain patching (no Sodium classes touched)
        String sodiumTerrainVs = """
            #include <metal_stdlib>
            using namespace metal;
            struct u_Globals { float4x4 u_ProjectionMatrix; float4x4 u_ModelViewMatrix; float3 u_CameraOffset; };
            struct main0_in { uint2 a_Position [[attribute(0)]]; float4 a_Color [[attribute(1)]]; uint4 a_LightAndData [[attribute(3)]]; };
            struct main0_out { float v_fadeFactor [[user(locn3)]]; float4 gl_Position [[position]]; };
            vertex main0_out main0(main0_in in [[stage_in]], constant u_Globals& _19 [[buffer(0)]]) {
                main0_out out = {};
                float3 position = float3(in.a_Position.x, 0.0, in.a_Position.y) - _19.u_CameraOffset;
                out.gl_Position = (_19.u_ProjectionMatrix * _19.u_ModelViewMatrix) * float4(position, 1.0);
                out.gl_Position.y = -(out.gl_Position.y);
                out.v_fadeFactor = 1.0;
                return out;
            }
            """;
        String sodiumTerrainFs = """
            #include <metal_stdlib>
            using namespace metal;
            struct u_Globals { float2 u_EnvironmentFog; float2 u_RenderFog; };
            struct main0_in { float4 v_Color [[user(locn0)]]; float2 v_TexCoord [[user(locn1)]]; float v_fadeFactor [[user(locn3)]]; };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]], constant u_Globals& _19 [[buffer(0)]], texture2d<float> u_BlockTex [[texture(0)]], sampler u_BlockTexSmplr [[sampler(0)]]) {
                main0_out out = {};
                float4 color = u_BlockTex.sample(u_BlockTexSmplr, in.v_TexCoord);
                color *= in.v_Color;
                out.fragColor = color;
                return out;
            }
            """;
        var sodRes = ShadeShaderPatcher.patch("sodium:pipeline/cutout_terrain", sodiumTerrainVs, "main0", sodiumTerrainFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(sodRes.patched());
        assertTrue(sodRes.vsSource().contains("(float2(in.a_LightAndData.xy) - 8.0) * (1.0 / 240.0)"));
        assertTrue(sodRes.fsSource().contains("shadeTerrainShade("));
        assertTrue(sodRes.fsSource().contains("in.v_fadeFactor"));

        // Entity patching (world & hand)
        String entityVs = """
            #include <metal_stdlib>
            using namespace metal;
            struct DynamicTransforms { float4x4 ModelViewMat; float4 ColorModulator; };
            struct Projection { float4x4 ProjMat; };
            struct main0_in { float3 Position [[attribute(0)]]; float4 Color [[attribute(1)]]; int2 UV2 [[attribute(3)]]; float3 Normal [[attribute(4)]]; };
            struct main0_out { float2 texCoord0 [[user(locn0)]]; float4 gl_Position [[position]]; };
            vertex main0_out main0(main0_in in [[stage_in]], constant DynamicTransforms& _10 [[buffer(0)]], constant Projection& _11 [[buffer(1)]]) {
                main0_out out = {};
                out.gl_Position = (_11.ProjMat * _10.ModelViewMat) * float4(in.Position, 1.0);
                out.gl_Position.y = -(out.gl_Position.y);
                out.texCoord0 = float2(0.0);
                return out;
            }
            """;
        String entityFs = """
            #include <metal_stdlib>
            using namespace metal;
            struct DynamicTransforms { float4x4 ModelViewMat; float4 ColorModulator; };
            struct Fog { float4 FogColor; float FogEnvironmentalStart; float FogEnvironmentalEnd; float FogRenderDistanceStart; float FogRenderDistanceEnd; };
            struct main0_in { float2 texCoord0 [[user(locn0)]]; };
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0(main0_in in [[stage_in]], constant DynamicTransforms& _10 [[buffer(0)]], constant Fog& _11 [[buffer(1)]], texture2d<float> Sampler0 [[texture(0)]], sampler Sampler0Smplr [[sampler(0)]]) {
                main0_out out = {};
                out.fragColor = Sampler0.sample(Sampler0Smplr, in.texCoord0);
                return out;
            }
            """;
        var entRes = ShadeShaderPatcher.patch("minecraft:pipeline/entity_solid", entityVs, "main0", entityFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(entRes.patched());
        assertTrue(entRes.fsSource().contains("shadeEntityShade("));
        var handRes = ShadeShaderPatcher.patch("minecraft:pipeline/entity_solid", entityVs, "main0", entityFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_HAND);
        assertTrue(handRes.patched());
        assertTrue(handRes.fsSource().contains("#define MCOPT_HAND 1"));

        // Compile patched MSL stages on live Metal GPU to ensure zero syntax or ABI errors
        long ctx = MetalNative.deviceCreate(true, false, "");
        assertNotEquals(0L, ctx);
        try {
            StringBuilder err = new StringBuilder();
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, vanRes.vsSource(), "test.van.vs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, vanRes.fsSource(), "test.van.fs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, sodRes.vsSource(), "test.sod.vs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, sodRes.fsSource(), "test.sod.fs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, entRes.vsSource(), "test.ent.vs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, entRes.fsSource(), "test.ent.fs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, handRes.vsSource(), "test.hand.vs", true, err), () -> err.toString());
            assertNotEquals(0L, MetalNative.compileMslLibrary(ctx, handRes.fsSource(), "test.hand.fs", true, err), () -> err.toString());
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }
}
