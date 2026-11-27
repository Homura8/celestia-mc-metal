package dev.celestia.metal;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.UniformType;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.backend.MetalShaderTranslator;
import dev.celestia.metal.shade.ShadeDims;
import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeLook;
import dev.celestia.metal.shade.ShadeSettings;
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

        // the fog colour's HDR value is packed once per frame (shaders read fogColorHdr instead of inverting the tonemap per pixel)
        frame.fogColor[0] = 0.05f; frame.fogColor[1] = 0.2f; frame.fogColor[2] = 0.6f;
        float[] fogHdr = look.ldrToHdr(frame.fogColor[0], frame.fogColor[1], frame.fogColor[2]);
        System.arraycopy(fogHdr, 0, frame.fogColorHdr, 0, 3);
        frame.pack(fb);
        for (int i = 0; i < 3; i++) {
            assertTrue(Float.isFinite(fogHdr[i]) && fogHdr[i] >= 0f);
            assertEquals(fogHdr[i], fb.getFloat(ShadeFrame.FOG_COLOR_HDR + 4 * i), 1e-6f);
        }
        assertTrue(fogHdr[2] > fogHdr[1] && fogHdr[1] > fogHdr[0]);

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
        // (alpha.25) every look, PASTEL's lift and gain included, inverts exactly (fog and clear colours rely on it)
        for (int preset = 0; preset < ShadeLook.LOOKS; preset++) {
            look.setLookPreset(preset);
            look.update(frame, 0, 0.016f);
            float[] h = look.ldrToHdr(0.5f, 0.3f, 0.8f);
            float[] d = look.display(h);
            for (int i = 0; i < 3; i++) {
                float targetLin = (float) Math.pow(((i == 0 ? 0.5f : i == 1 ? 0.3f : 0.8f) + 0.055f) / 1.055f, 2.4);
                assertEquals(targetLin, d[i], 0.015f, "look " + preset + " channel " + i);
            }
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

        var endSkyRes = ShadeShaderPatcher.patch("minecraft:pipeline/end_sky", dummyVs, "main0", dummyFs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(endSkyRes.patched());
        assertTrue(endSkyRes.vsSource().contains("EndSkyOut"));
        assertTrue(endSkyRes.fsSource().contains("shadeEndSky("));

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
            long endVsLib = MetalNative.compileMslLibrary(ctx, endSkyRes.vsSource(), "test.endsky.vs", true, err);
            assertNotEquals(0L, endVsLib, () -> err.toString());
            MetalNative.libraryDestroy(endVsLib);
            long endFsLib = MetalNative.compileMslLibrary(ctx, endSkyRes.fsSource(), "test.endsky.fs", true, err);
            assertNotEquals(0L, endFsLib, () -> err.toString());
            MetalNative.libraryDestroy(endFsLib);
            long postLib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.postSource(), "test.post.dims", true, err);
            assertNotEquals(0L, postLib, () -> err.toString());
            long finalDimsFn = MetalNative.compileFunction(postLib, "shade_final_dims", false, 0, 0, err);
            assertNotEquals(0L, finalDimsFn, () -> err.toString());
            MetalNative.functionDestroy(finalDimsFn);
            MetalNative.libraryDestroy(postLib);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }

    @Test
    void shadeDimsUpdatesAndPacksNetherAndEndState() {
        ShadeSettings.Dimensions opts = new ShadeSettings.Dimensions(true, true, true);
        ShadeFrame frame = new ShadeFrame();
        frame.view.identity();
        frame.proj.perspective((float) Math.toRadians(70.0), 16f / 9f, 0.05f, 256f);
        frame.proj.mul(frame.view, frame.viewProj);
        frame.viewProj.invert(frame.invViewProj);
        frame.updateAtmosphere(0.016f, true);
        ShadeLook look = new ShadeLook();
        look.update(frame, 0, 0.016f);

        ByteBuffer fb = ByteBuffer.allocateDirect(ShadeFrame.SIZE).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer lb = ByteBuffer.allocateDirect(ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);

        frame.dimension = ShadeFrame.DIM_NETHER;
        frame.fogRenderStart = 32f;
        frame.fogRenderEnd = 128f;
        ShadeDims.update(frame, look, null, null, null, 0.016f, true, opts);
        assertTrue(ShadeDims.isLit());
        assertFalse(ShadeDims.endShadowsActive());
        frame.pack(fb);
        look.pack(lb, frame);
        ShadeDims.pack(lb, fb, frame, opts);
        assertNotEquals(0, ((int) fb.getFloat(ShadeFrame.SUN_PATH + 8)) & ShadeDims.FLAG_DIMS_LIT);
        assertNotEquals(0, lb.getInt(ShadeLook.TIER + 4) & ShadeDims.FEATURE_DIMS);
        assertNotEquals(0, lb.getInt(ShadeLook.TIER + 4) & ShadeDims.FEATURE_SHIMMER);
        assertTrue(lb.getFloat(ShadeLook.DIM_TINT) > 0f);
        assertEquals(1, ((int) lb.getFloat(ShadeLook.DIM_TINT + 12)) & 3);

        frame.dimension = ShadeFrame.DIM_END;
        ShadeDims.update(frame, look, null, null, null, 0.016f, true, opts);
        assertTrue(ShadeDims.isLit());
        assertTrue(ShadeDims.endShadowsActive());
        assertTrue(frame.sky.sunLight);
        assertTrue(frame.sky.light[0] > 0f);
        frame.pack(fb);
        look.pack(lb, frame);
        ShadeDims.pack(lb, fb, frame, opts);
        assertEquals(2, ((int) lb.getFloat(ShadeLook.DIM_TINT + 12)) & 3);
        assertEquals(frame.exposure, lb.getFloat(ShadeLook.EXPOSURE_REF), 1e-6f);
    }

    @Test
    void noShaderInvertsTheFogColourPerPixel() throws Exception {
        // (alpha.24) shadeLdrToHdr(fogColor) per fragment cost ~8 ms of the sky pass alone underwater at 3024x1742 (M1 Pro)
        for (String name : List.of("shade_m2.metal", "shade_dims.metal", "shade_water_terrain.metal", "shade_terrain.metal",
                "sky.fs.metal", "end_sky.fs.metal", "water.metal", "shade_entity.metal", "clouds.fs.metal",
                "celestial.fs.metal", "shade_post.metal")) {
            try (var in = ShadeP1Test.class.getResourceAsStream(dev.celestia.metal.shade.ShadeShaderPatcher.DEFAULT_PACK_SHADERS + name)) {
                assertNotNull(in, name);
                String src = new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
                assertFalse(src.matches("(?s).*shadeLdrToHdr\\(\\s*s?f\\.fogColor.*"), name + " converts the fog colour per pixel");
            }
        }
    }

    @Test
    void atmosphereShadersCompileAndCloudNoiseLoads() throws Exception {
        // (alpha.25) the Photon-style clouds: every atmosphere entry compiles, and the atlases wrap as clouds.metal expects
        long ctx = MetalNative.deviceCreate(true, false, "");
        assertNotEquals(0L, ctx);
        try {
            StringBuilder err = new StringBuilder();
            long lib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.atmosphereSource(), "test.atmosphere", true, err);
            assertNotEquals(0L, lib, () -> err.toString());
            for (String entry : List.of("shade_cloud_trace", "shade_cloud_resolve", "shade_cloud_dome", "shade_vl_march",
                    "shade_wx_noise_fs", "shade_aurora_pass")) {
                long fn = MetalNative.compileFunction(lib, entry, false, 0, 0, err);
                assertNotEquals(0L, fn, () -> entry + ": " + err);
                MetalNative.functionDestroy(fn);
            }
            MetalNative.libraryDestroy(lib);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
        // a 4^3 volume of distinct voxels into 2x2 tiles of 6^2: tile (z % 2, z / 2), border = the opposite edge
        int n = 4;
        byte[] vol = new byte[n * n * n];
        for (int i = 0; i < vol.length; i++) vol[i] = (byte) i;
        byte[] at = dev.celestia.metal.shade.atmosphere.ShadeCloudNoise.atlasForTest(vol, n, 1, 1, 2, 2);
        int aw = 12;
        int z = 3, ox = (z % 2) * 6, oy = (z / 2) * 6;
        assertEquals((z * n + 0) * n + 0, at[(oy + 1) * aw + ox + 1]);         // (0, 0) at texel (1, 1)
        assertEquals((z * n + 0) * n + (n - 1), at[(oy + 1) * aw + ox]);       // left gutter wraps to x = 3
        assertEquals((z * n + (n - 1)) * n + 0, at[oy * aw + ox + 1]);         // top gutter wraps to y = 3
        assertEquals((z * n + 0) * n + 0, at[(oy + 5) * aw + ox + 5] & 0xFF);  // bottom-right corner wraps to (0, 0)
        // the shipped files have the sizes the shader assumes, and the PNG's alpha (noise data) is read raw
        try (var in = ShadeP1Test.class.getResourceAsStream("/assets/celestiametal/textures/clouds/photon_worley.dat")) {
            assertEquals(64 * 64 * 64, in.readAllBytes().length);
        }
        try (var in = ShadeP1Test.class.getResourceAsStream("/assets/celestiametal/textures/clouds/photon_curl.dat")) {
            assertEquals(32 * 32 * 32 * 3, in.readAllBytes().length);
        }
        try (var in = ShadeP1Test.class.getResourceAsStream("/assets/celestiametal/textures/clouds/photon_noise.png")) {
            byte[] rgba = dev.celestia.metal.shade.atmosphere.ShadeCloudNoise.rgbaForTest(javax.imageio.ImageIO.read(in));
            assertEquals(512 * 512 * 4, rgba.length);
            int distinctAlpha = (int) java.util.stream.IntStream.range(0, 512 * 512).map(i -> rgba[i * 4 + 3] & 0xFF).distinct().count();
            assertTrue(distinctAlpha > 64, "alpha holds noise, not coverage: " + distinctAlpha + " distinct values");
        }
    }

    @Test
    void dailyCloudWeatherFollowsPhotonsTable() {
        float[] w = new float[8];
        // a fixed sky is that day's row; rain pushes toward overcast stratus
        dev.celestia.metal.shade.atmosphere.ShadeWeather.compute(12000L, 0f, 1f, 0, w);
        assertArrayEquals(new float[] {0.40f, 0.60f, 0.20f, 0.50f, 0.00f, 0.53f, 0f, 0f}, w, 1e-6f);
        dev.celestia.metal.shade.atmosphere.ShadeWeather.compute(12000L, 1f, 1f, 0, w);
        assertEquals(0.6f, w[0], 1e-6f);
        assertEquals(0.8f, w[1], 1e-6f);
        assertEquals(0.7f, w[7], 1e-6f);
        // congestus days stand in a cumulus; coverage scales every layer
        dev.celestia.metal.shade.atmosphere.ShadeWeather.compute(12000L, 0f, 0.5f, 2, w);
        assertEquals(0.225f, w[0], 1e-6f);
        assertEquals(1f, w[6], 1e-6f);
        // the daily cycle is deterministic and continuous across the dawn blend
        float[] a = new float[8], b = new float[8];
        dev.celestia.metal.shade.atmosphere.ShadeWeather.compute(5L * 24000L + 5999L, 0f, 1f, -1, a);
        dev.celestia.metal.shade.atmosphere.ShadeWeather.compute(5L * 24000L + 6001L, 0f, 1f, -1, b);
        for (int i = 0; i < 8; i++) assertEquals(a[i], b[i], 0.02f, "jump at noon in value " + i);
    }

    @Test
    void auroraModesPalettesAndUniformPackingWork() {
        var Aurora = dev.celestia.metal.shade.atmosphere.ShadeAurora.class;
        assertNotNull(Aurora);
        // Night curve ramps smoothly from dusk into full night; rain and day quench it.
        assertEquals(0f, dev.celestia.metal.shade.atmosphere.ShadeAurora.nightFactor(0.1f), 1e-6f);
        assertEquals(1f, dev.celestia.metal.shade.atmosphere.ShadeAurora.nightFactor(-0.5f), 1e-6f);
        assertEquals(0f, dev.celestia.metal.shade.atmosphere.ShadeAurora.computeWant(
            dev.celestia.metal.shade.atmosphere.ShadeAurora.MODE_OFF, 1f, 0L, -0.5f, 0f), 1e-6f);
        assertEquals(1f, dev.celestia.metal.shade.atmosphere.ShadeAurora.computeWant(
            dev.celestia.metal.shade.atmosphere.ShadeAurora.MODE_ALWAYS, 0f, 0L, -0.5f, 0f), 1e-6f);
        assertEquals(0f, dev.celestia.metal.shade.atmosphere.ShadeAurora.computeWant(
            dev.celestia.metal.shade.atmosphere.ShadeAurora.MODE_ALWAYS, 0f, 0L, -0.5f, 1f), 1e-6f);
        assertEquals(0.6f, dev.celestia.metal.shade.atmosphere.ShadeAurora.computeWant(
            dev.celestia.metal.shade.atmosphere.ShadeAurora.MODE_COLD_BIOMES, 0.6f, 0L, -0.5f, 0f), 1e-6f);

        // Noon-to-noon day boundary stays constant across midnight (17999 vs 18001).
        long beforeMidnight = dev.celestia.metal.shade.atmosphere.ShadeAurora.noonDayIndex(24000L + 17999L);
        long afterMidnight = dev.celestia.metal.shade.atmosphere.ShadeAurora.noonDayIndex(24000L + 18001L);
        assertEquals(beforeMidnight, afterMidnight);

        // All palettes produce valid positive linear RGB.
        float[] bot = new float[3], top = new float[3];
        for (int p : new int[] {
                dev.celestia.metal.shade.atmosphere.ShadeAurora.PALETTE_DAILY,
                dev.celestia.metal.shade.atmosphere.ShadeAurora.PALETTE_CLASSIC,
                dev.celestia.metal.shade.atmosphere.ShadeAurora.PALETTE_PASTEL}) {
            dev.celestia.metal.shade.atmosphere.ShadeAurora.selectPalette(p, 7L, bot, top);
            for (int c = 0; c < 3; c++) {
                assertTrue(bot[c] > 0f && bot[c] <= 1f);
                assertTrue(top[c] > 0f && top[c] <= 1f);
            }
        }

        // ShadeLook.NIGHT.z carries auroraStrength and ShadeDims sets SHADE_DIMS_AURORA_TEX bit (2) in dimTint.w.
        ShadeFrame frame = new ShadeFrame();
        frame.dimension = ShadeFrame.DIM_OVERWORLD;
        ShadeLook look = new ShadeLook();
        look.auroraStrength = 1.25f;
        look.auroraTexActive = true;
        ByteBuffer fb = ByteBuffer.allocateDirect(ShadeFrame.SIZE).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer lb = ByteBuffer.allocateDirect(ShadeLook.SIZE).order(ByteOrder.LITTLE_ENDIAN);
        frame.pack(fb);
        look.pack(lb, frame);
        ShadeDims.pack(lb, fb, frame, new ShadeSettings.Dimensions(true, true, true), 0f, true);
        assertEquals(1.25f, lb.getFloat(ShadeLook.NIGHT + 8), 1e-6f);
        assertNotEquals(0, (((int) lb.getFloat(ShadeLook.DIM_TINT + 12)) >> 2) & 2);
        ShadeDims.pack(lb, fb, frame, new ShadeSettings.Dimensions(true, true, true), 0f, false);
        assertEquals(0, (((int) lb.getFloat(ShadeLook.DIM_TINT + 12)) >> 2) & 2);
    }
}
