// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/ShadeBindings.java, ShadeFrameUpdater.java & ShadePost.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.pipeline.CompareOp;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.CelestiaPipeline;
import dev.celestia.metal.backend.CelestiaTexture;
import dev.celestia.metal.backend.CelestiaTextureView;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.atmosphere.ShadeAtmosphere;
import dev.celestia.metal.shade.light.ColorLights;
import dev.celestia.metal.shade.light.DynLightConfig;
import dev.celestia.metal.shade.light.DynLights;
import dev.celestia.metal.shade.shadow.ShadowPass;
import dev.celestia.metal.shade.water.ShadeWater;
import dev.celestia.metal.shade.water.WaterFrame;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.fog.FogData;
import net.minecraft.client.renderer.state.GameRenderState;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.material.FogType;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector4f;
import org.slf4j.Logger;

/**
 * Coordinates P1 native shader-suite state on {@link CelestiaMetalDevice}: 4-slot ring buffers for
 * {@link ShadeFrame} and {@link ShadeLook}, persistent {@code ShadeGpu} exposure state, sky-view LUT,
 * Milky Way bake, {@code RGBA16Float} HDR world render target redirection, 6-level bloom pyramid,
 * GPU histogram/exposure reduction, and Lottes filmic display transform.
 */
public final class CelestiaShade {
    private static final Logger LOGGER = LogUtils.getLogger();

    private static final int RING_SLOTS = 4;
    private static final int LOOK_OFFSET = 1024; // 1024 B ShadeFrame
    private static final int RING_SLOT_STRIDE = 2304; // >= 1024 + 1136 (multiple of 256)
    private static final int RES_SLOT_STRIDE = 256; // >= 128 (ShadeResources 16 x uint64)
    private static final int GPU_BUF_SIZE = 512;
    private static final int LUT_WIDTH = 128, LUT_HEIGHT = 80;
    private static final int MILKY_WAY_W = 1024, MILKY_WAY_H = 512;
    private static final int BLOOM_LEVELS = 6;
    private static final int BLOOM_FORMAT = MetalConst.FMT_RG11B10_FLOAT;
    private static final boolean SSAO = !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.ssao"));

    private static final float[] MOON_BRIGHTNESS = {1f, 0.75f, 0.5f, 0.25f, 0f, 0.25f, 0.5f, 0.75f};

    private static volatile CelestiaShade activeInstance;

    private final CelestiaMetalDevice device;
    private final ShadeFrame frame = new ShadeFrame();
    private final ShadeLook look = new ShadeLook();
    private final ShadowPass shadowPass = new ShadowPass();
    private final ShadeWater water = new ShadeWater();
    private final ShadeAtmosphere atmosphere = new ShadeAtmosphere();
    private ShadeSettings settings;

    private final Matrix4f pendingProjection = new Matrix4f();
    private boolean projectionSet;
    private float pendingJitterX, pendingJitterY;
    private final Matrix4f previousViewProj = new Matrix4f();
    private double prevCamX, prevCamY, prevCamZ;
    private boolean hasPrevious;
    private long lastNanos;
    private double waterClock, skyClock;
    private int lastDimension = -1;
    private int moonPhaseIndex;
    private int ringSlot;
    private int frameCounter;

    // Native handles
    private long ringBuf;
    private MemorySegment ringSeg;
    private long resBuf;
    private long gpuBuf;
    private ByteBuffer gpuView;
    private long dummyShadowTex;
    private long skyLutTex;
    private long milkyWayTex;
    private long shadowCompareSamp;
    private long linearClampSamp;

    private long lutLib, lutVsFn, lutFsFn, psoSkyLut;
    private long postLib, fsVsFn, bloomDown0Fn, bloomDownFn, bloomUpFn, finalFn, finalDimsFn, histFn, expFn, milkyWayFn, motionFn;
    private long psoBloomDown0, psoBloomDown, psoBloomUp, psoFinalRgba8, psoFinalBgra8, psoFinalDimsRgba8, psoFinalDimsBgra8, psoHist, psoExp, psoMotion;

    private long psoAo, aoTexture;
    private int aoW, aoH;
    private boolean aoActive;

    private long hdrWorldTex;
    private long hdrWorldView;
    private long prevHdrWorldTex;
    private long motionTex;
    private int motionWidth, motionHeight;
    private boolean hasPrevHdrWorld;
    private boolean motionEligible;
    private int hdrWidth, hdrHeight;
    private final long[] bloomDownTex = new long[BLOOM_LEVELS];
    private final long[] bloomAccumTex = new long[BLOOM_LEVELS];
    private int bloomWidth, bloomHeight;
    private int activeBloomLevels;

    private GpuTexture worldMainColor;
    private GpuTexture worldDepth;
    private boolean worldRedirectActive;
    private boolean handPassActive;
    private boolean initialized;
    private boolean failed;
    /** ShadeShaderPatcher.epoch() the compiled world shaders came from; a different one means the world pack changed. */
    private int shaderEpoch = ShadeShaderPatcher.epoch();
    /** ShadeGpu across a world-pack rebuild: sky irradiance, sun at camera, exposure and the histogram converge over frames. */
    private byte[] carriedGpu;

    private final double[] dirScratch = new double[3];
    private final MemorySegment pushSeg = Arena.global().allocate(128, 16);
    private final MemorySegment texArgSeg = Arena.global().allocate(8 * 8L, 8);
    private final MemorySegment sampArgSeg = Arena.global().allocate(8 * 4L, 8);

    public CelestiaShade(CelestiaMetalDevice device) {
        this.device = device;
        activeInstance = this;
    }

    public static CelestiaShade current() {
        return activeInstance;
    }

    private volatile boolean snapRequested;

    /**
     * Makes the next frame jump to its targets instead of easing toward them: exposure, the atmosphere's smoothing and the
     * temporal histories (as after a dimension change). For scripted cuts such as the QA harness's scene changes
     * (tools/qa), so a screenshot or a timing window needs no multi-second adaptation wait.
     */
    public void requestSnap() {
        this.snapRequested = true;
    }

    /** Selects a shader debug view (ShadeFrame.debug: 0 off; see shade_terrain.metal / shade_water_terrain.metal). */
    public void setDebugView(int view) {
        this.frame.debug = view;
    }

    public static boolean isEnabled() {
        return appliedSettings() != null;
    }

    private static ShadeSettings appliedSettings() {
        if ("false".equalsIgnoreCase(System.getProperty("celestiametal.shade", "true"))) {
            return null;
        }
        return ShaderPipelineManager.get().worldSettings();
    }

    public boolean isReady() {
        return initialized && !failed;
    }

    public boolean isWorldRedirectActive() {
        return worldRedirectActive && isReady() && hdrWorldTex != 0L;
    }

    public boolean isHandPassActive() {
        return handPassActive && isReady();
    }

    /** Called inside {@code GameRendererMixin} during {@code renderLevel} before world draws start. */
    public static void recordProjection(Matrix4fc proj, float jitterX, float jitterY) {
        CelestiaShade s = activeInstance;
        if (s == null || !isEnabled()) return;
        s.pendingProjection.set(proj);
        s.pendingJitterX = jitterX;
        s.pendingJitterY = jitterY;
        s.projectionSet = true;
    }

    /** Called by {@code ShadeFaceShadeMixin} to neutralize vanilla's directional face shading when active. */
    public static boolean shouldFlattenVanillaFaceShade() {
        CelestiaShade s = activeInstance;
        return s != null && s.isReady() && isEnabled();
    }

    private synchronized boolean ensureInitialized() {
        if (initialized) return true;
        if (failed) return false;
        long ctx = device.handle();
        if (ctx == 0L) return false;
        try {
            long startNs = System.nanoTime();
            ringBuf = MetalNative.bufferCreate(ctx, (long) RING_SLOTS * RING_SLOT_STRIDE, null, "CelestiaShade.Ring");
            resBuf = MetalNative.bufferCreate(ctx, (long) RING_SLOTS * RES_SLOT_STRIDE, null, "CelestiaShade.Resources");
            gpuBuf = MetalNative.bufferCreate(ctx, GPU_BUF_SIZE, null, "CelestiaShade.Gpu");
            if (ringBuf == 0L || resBuf == 0L || gpuBuf == 0L) {
                throw new IllegalStateException("Failed to allocate CelestiaShade buffers");
            }
            ringSeg = MemorySegment.ofAddress(MetalNative.bufferContents(ringBuf))
                .reinterpret((long) RING_SLOTS * RING_SLOT_STRIDE);
            gpuView = MemorySegment.ofAddress(MetalNative.bufferContents(gpuBuf))
                .reinterpret(GPU_BUF_SIZE).asByteBuffer().order(ByteOrder.nativeOrder());
            gpuView.putFloat(176, 1f).putFloat(180, 1f).putFloat(184, 1f).putFloat(188, 0f);
            if (carriedGpu != null) {
                gpuView.put(0, carriedGpu);
                carriedGpu = null;
            }
            for (int i = 0; i < RING_SLOTS; i++) {
                ByteBuffer slotBb = ringSeg.asSlice((long) i * RING_SLOT_STRIDE, RING_SLOT_STRIDE)
                    .asByteBuffer().order(ByteOrder.nativeOrder());
                frame.pack(slotBb);
                look.pack(slotBb.slice(LOOK_OFFSET, ShadeLook.SIZE).order(ByteOrder.nativeOrder()), frame);
            }

            dummyShadowTex = MetalNative.textureCreate(ctx, MetalConst.FMT_D32_FLOAT, 1, 1, 2, 1,
                false, true, true, false, "CelestiaShade.DummyShadow");
            skyLutTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, LUT_WIDTH, LUT_HEIGHT, 1, 1,
                false, true, true, false, "CelestiaShade.SkyLut");
            milkyWayTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, MILKY_WAY_W, MILKY_WAY_H, 1, 1,
                false, true, true, false, "CelestiaShade.MilkyWay");
            shadowCompareSamp = MetalNative.samplerCreate(ctx, 1, 1, 1, 1, 0, 1,
                true, MetalConst.toNativeCompare(CompareOp.GREATER_THAN_OR_EQUAL));
            linearClampSamp = MetalNative.samplerCreate(ctx, 1, 1, 1, 1, 0, 1, false, 0);
            if (dummyShadowTex == 0L || skyLutTex == 0L || milkyWayTex == 0L
                || shadowCompareSamp == 0L || linearClampSamp == 0L) {
                throw new IllegalStateException("Failed to create CelestiaShade base textures/samplers");
            }

            StringBuilder err = new StringBuilder();
            lutLib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.skyLutSource(), "CelestiaShade.SkyLut", true, err);
            if (lutLib == 0L) throw new IllegalStateException("Sky LUT MSL compile failed: " + err);
            lutVsFn = MetalNative.compileFunction(lutLib, "shade_lut_vs", false, 0, 0, err);
            lutFsFn = MetalNative.compileFunction(lutLib, "shade_lut_fs", false, 0, 0, err);
            psoSkyLut = createFullscreenPso(ctx, lutVsFn, lutFsFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaShade.SkyLut", err);

            postLib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.postSource(), "CelestiaShade.Post", true, err);
            if (postLib == 0L) throw new IllegalStateException("Post MSL compile failed: " + err);
            fsVsFn = MetalNative.compileFunction(postLib, "shade_fs_vs", false, 0, 0, err);
            bloomDown0Fn = MetalNative.compileFunction(postLib, "shade_bloom_down0", false, 0, 0, err);
            bloomDownFn = MetalNative.compileFunction(postLib, "shade_bloom_down", false, 0, 0, err);
            bloomUpFn = MetalNative.compileFunction(postLib, "shade_bloom_up", false, 0, 0, err);
            finalFn = MetalNative.compileFunction(postLib, "shade_final", false, 0, 0, err);
            finalDimsFn = MetalNative.compileFunction(postLib, "shade_final_dims", false, 0, 0, err);
            histFn = MetalNative.compileFunction(postLib, "shade_histogram", false, 0, 0, err);
            expFn = MetalNative.compileFunction(postLib, "shade_exposure", false, 0, 0, err);
            milkyWayFn = MetalNative.compileFunction(postLib, "shade_milkyway_bake", false, 0, 0, err);
            motionFn = MetalNative.compileFunction(postLib, "shade_motion_fs", false, 0, 0, err);

            psoBloomDown0 = createFullscreenPso(ctx, fsVsFn, bloomDown0Fn, BLOOM_FORMAT, "CelestiaShade.BloomDown0", err);
            psoBloomDown = createFullscreenPso(ctx, fsVsFn, bloomDownFn, BLOOM_FORMAT, "CelestiaShade.BloomDown", err);
            psoBloomUp = createFullscreenPso(ctx, fsVsFn, bloomUpFn, BLOOM_FORMAT, "CelestiaShade.BloomUp", err);
            psoFinalRgba8 = createFullscreenPso(ctx, fsVsFn, finalFn, MetalConst.FMT_RGBA8_UNORM, "CelestiaShade.FinalRGBA8", err);
            psoFinalBgra8 = createFullscreenPso(ctx, fsVsFn, finalFn, MetalConst.FMT_BGRA8_UNORM, "CelestiaShade.FinalBGRA8", err);
            psoFinalDimsRgba8 = createFullscreenPso(ctx, fsVsFn, finalDimsFn, MetalConst.FMT_RGBA8_UNORM, "CelestiaShade.FinalDimsRGBA8", err);
            psoFinalDimsBgra8 = createFullscreenPso(ctx, fsVsFn, finalDimsFn, MetalConst.FMT_BGRA8_UNORM, "CelestiaShade.FinalDimsBGRA8", err);
            psoMotion = createFullscreenPso(ctx, fsVsFn, motionFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaShade.MotionBlur", err);
            if (SSAO) {
                long aoFn = MetalNative.compileFunction(postLib, "shade_ambient_occlusion", false, 0, 0, err);
                try {
                    psoAo = createFullscreenPso(ctx, fsVsFn, aoFn, MetalConst.FMT_RG16_FLOAT, "CelestiaShade.SSAO", err);
                } catch (RuntimeException e) {
                    LOGGER.warn("CelestiaShade SSAO pipeline unavailable", e);
                } finally {
                    if (aoFn != 0L) MetalNative.functionDestroy(aoFn);
                }
            }
            psoHist = MetalNative.computePipelineCreate(ctx, histFn, "CelestiaShade.Histogram", err);
            psoExp = MetalNative.computePipelineCreate(ctx, expFn, "CelestiaShade.Exposure", err);
            long psoMw = createFullscreenPso(ctx, fsVsFn, milkyWayFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaShade.MilkyWayBake", err);
            if (psoHist == 0L || psoExp == 0L || psoMw == 0L) {
                throw new IllegalStateException("Compute/MilkyWay pipeline creation failed: " + err);
            }

            publishGlobals(0);
            MetalNative.blitClearDepth(ctx, dummyShadowTex, 1.0);
            MetalNative.shadeFullscreenPass(ctx, psoMw, milkyWayTex, MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            MetalNative.pipelineDestroy(ctx, psoMw);
            MetalNative.shadeSetResource(ctx, 0, milkyWayTex);
            if (DynLights.ON) DynLights.ensureBindings(ctx);
            if (ColorLights.ON) ColorLights.fallback(ctx);

            initialized = true;
            double ms = (System.nanoTime() - startNs) / 1_000_000.0;
            LOGGER.info("CelestiaShade P1 initialized in {} ms (Sky LUT + HDR post + auto-exposure)", String.format(java.util.Locale.ROOT, "%.1f", ms));
            return true;
        } catch (Throwable t) {
            failed = true;
            LOGGER.error("CelestiaShade initialization failed; staying on standard rendering", t);
            close();
            return false;
        }
    }

    public static long createFullscreenPso(long ctx, long vsFn, long fsFn, int colorFmt, String label, StringBuilder err) {
        if (vsFn == 0L || fsFn == 0L) throw new IllegalStateException("Null function for " + label + ": " + err);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment col = arena.allocate(36, 4);
            col.set(ValueLayout.JAVA_INT, 0, colorFmt);
            col.set(ValueLayout.JAVA_INT, 4, 0);
            col.set(ValueLayout.JAVA_INT, 32, 15);
            long pso = MetalNative.renderPipelineCreate(ctx, vsFn, fsFn,
                MemorySegment.NULL, 0, MemorySegment.NULL, 0,
                col, 1, CelestiaPipeline.NO_DEPTH, MetalConst.TOPO_TRIANGLES,
                0, false, false, 0, false, 0f, 0f, label, err);
            if (pso == 0L) throw new IllegalStateException("Failed creating PSO " + label + ": " + err);
            return pso;
        }
    }

    private void publishGlobals(int slot) {
        long frameOff = (long) slot * RING_SLOT_STRIDE;
        long lookOff = frameOff + LOOK_OFFSET;
        long resOff = (long) slot * RES_SLOT_STRIDE;
        long activeShadowTex = (shadowPass != null && shadowPass.isActive()) ? shadowPass.texture() : dummyShadowTex;
        MetalNative.shadeSetGlobals(device.handle(),
            ringBuf, frameOff,
            ringBuf, lookOff,
            gpuBuf, 0L,
            resBuf, resOff,
            activeShadowTex, skyLutTex,
            shadowCompareSamp, linearClampSamp);
        MetalNative.shadeSetResource(device.handle(), 0, milkyWayTex);
        MetalNative.shadeSetResource(device.handle(), 1, hasPrevHdrWorld && prevHdrWorldTex != 0L ? prevHdrWorldTex : 0L);
    }

    /** Called at {@code LevelRenderer.render} HEAD to update uniforms, bake Sky LUT, and open HDR redirect. */
    public void beginWorld(CameraRenderState camera) {
        ShadeSettings applied = appliedSettings();
        if (applied == null) {
            settings = null;
            hasPrevHdrWorld = false;
            worldRedirectActive = false;
            handPassActive = false;
            MetalNative.shadeSetEnabled(device.handle(), false);
            return;
        }
        if (shaderEpoch != ShadeShaderPatcher.epoch()) reloadShaders();
        if (!ensureInitialized()) return;

        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.gameRenderer == null) return;
        RenderTarget main = mc.gameRenderer.mainRenderTarget();
        if (main == null || main.getColorTexture() == null) return;

        GpuTexture color = main.getColorTexture();
        int w = Math.max(1, color.getWidth(0));
        int h = Math.max(1, color.getHeight(0));
        ensureHdrTarget(w, h);
        ensureBloomTargets(w, h);

        ClientLevel level = mc.level;
        GameRenderState game = mc.gameRenderer.gameRenderState();
        LevelRenderState state = game.levelRenderState;
        SkyRenderState sky = state.skyRenderState;
        float partial = state.worldPartialTicks;

        frame.view.set(camera.viewRotationMatrix);
        frame.proj.set(projectionSet ? pendingProjection : camera.projectionMatrix);
        frame.prevJitterX = frame.jitterX;
        frame.prevJitterY = frame.jitterY;
        frame.jitterX = projectionSet ? pendingJitterX : 0f;
        frame.jitterY = projectionSet ? pendingJitterY : 0f;
        projectionSet = false;
        frame.proj.mul(frame.view, frame.viewProj);
        frame.viewProj.invert(frame.invViewProj);

        double x = camera.pos.x, y = camera.pos.y, z = camera.pos.z;
        boolean hadPrev = hasPrevious;
        if (hasPrevious && Math.abs(x - prevCamX) + Math.abs(y - prevCamY) + Math.abs(z - prevCamZ) < 64.0) {
            previousViewProj.translate((float) (x - prevCamX), (float) (y - prevCamY), (float) (z - prevCamZ), frame.prevViewProj);
        } else {
            frame.prevViewProj.set(frame.viewProj);
        }
        previousViewProj.set(frame.viewProj);
        prevCamX = x; prevCamY = y; prevCamZ = z;
        hasPrevious = true;
        frame.cameraX = x; frame.cameraY = y; frame.cameraZ = z;
        frame.width = w; frame.height = h;
        frame.mipScale = 1f;
        frame.renderScale = 1f;

        frame.dimension = sky.skybox == DimensionType.Skybox.OVERWORLD ? ShadeFrame.DIM_OVERWORLD
            : sky.skybox == DimensionType.Skybox.END ? ShadeFrame.DIM_END : ShadeFrame.DIM_NETHER;
        if (frame.dimension == ShadeFrame.DIM_OVERWORLD) {
            double sunAngle = sky.sunAngle;
            ShadeSky.celestial(sunAngle, dirScratch);
            frame.sunDir.set((float) dirScratch[0], (float) dirScratch[1], (float) dirScratch[2]);
            ShadeSky.celestial(sky.moonAngle, dirScratch);
            frame.moonDir.set((float) dirScratch[0], (float) dirScratch[1], (float) dirScratch[2]);
            int phase = sky.moonPhase != null ? sky.moonPhase.index() : 0;
            frame.moonPhase = MOON_BRIGHTNESS[Math.floorMod(phase, 8)];
            moonPhaseIndex = phase;
            frame.starBrightness = sky.starBrightness;
            frame.dayTime = (float) (sunAngle / (2.0 * Math.PI) - Math.floor(sunAngle / (2.0 * Math.PI)));
        } else {
            frame.sunDir.set(0f, 1f, 0f);
            frame.moonDir.set(0f, -1f, 0f);
            frame.starBrightness = 0f;
        }

        frame.rain = level != null ? level.getRainLevel(partial) : 0f;
        frame.thunder = level != null ? level.getThunderLevel(partial) : 0f;
        frame.gameTimeSeconds = ((state.gameTime % 72000L) + partial) / 20f;
        frame.partialTick = partial;

        FogData fog = camera.fogData;
        FogType fogType = camera.fogType;
        frame.fogType = fogType == FogType.WATER ? ShadeFrame.FOG_WATER
            : fogType == FogType.LAVA ? ShadeFrame.FOG_LAVA
            : fogType == FogType.POWDER_SNOW ? ShadeFrame.FOG_POWDER_SNOW : ShadeFrame.FOG_AIR;
        frame.underwater = fogType == FogType.WATER;
        frame.waterSurfaceAbove = frame.underwater && frame.dimension == ShadeFrame.DIM_OVERWORLD && applied.water().enabled()
            ? WaterFrame.surfaceAbove(level, x, y, z) : 0f;
        Vector4f fogColor = fog.color;
        frame.fogColor[0] = fogColor.x;
        frame.fogColor[1] = fogColor.y;
        frame.fogColor[2] = fogColor.z;
        frame.fogColor[3] = (frame.fogType != ShadeFrame.FOG_AIR || frame.dimension != ShadeFrame.DIM_OVERWORLD)
            ? 1f : Math.min(Math.max((64f - fog.environmentalEnd) / 32f, 0f), 1f);
        frame.fogEnvStart = fog.environmentalStart;
        frame.fogEnvEnd = fog.environmentalEnd;
        frame.fogRenderStart = fog.renderDistanceStart;
        frame.fogRenderEnd = fog.renderDistanceEnd;
        frame.fogSkyEnd = fog.skyEnd;
        frame.fogCloudEnd = fog.cloudEnd;

        frame.eyeSkyLight = level != null ? level.getBrightness(LightLayer.SKY, camera.blockPos) : 15;
        var lightmap = game.lightmapRenderState;
        frame.nightVision = lightmap.nightVisionEffectIntensity;
        frame.minAmbient = 0.0025f + 0.02f * lightmap.brightness + 0.25f * frame.nightVision;

        frame.frameIndex = ++frameCounter;
        long now = System.nanoTime();
        float dt = lastNanos == 0L ? 0f : (now - lastNanos) / 1e9f;
        lastNanos = now;
        boolean snap = lastDimension != frame.dimension || dt > 1f || !applied.equals(settings) || snapRequested;
        snapRequested = false;
        settings = applied;
        double clampedDt = Math.min(Math.max(dt, 0f), 0.25);
        motionEligible = hadPrev && !snap && clampedDt > 0.0 && clampedDt <= 0.1
            && !frame.viewProj.equals(frame.prevViewProj, 1e-5f);
        waterClock = (waterClock + clampedDt) % 4096.0;
        skyClock = (skyClock + clampedDt) % 65536.0;
        frame.waterTime = (float) waterClock;
        frame.skyTime = (float) skyClock;
        lastDimension = frame.dimension;

        look.setOptions(settings);
        frame.updateAtmosphere((float) clampedDt, snap);
        if (snap) {
            hasPrevHdrWorld = false;
            look.snapExposure();
        }
        look.setHasPrevScene(hasPrevHdrWorld && prevHdrWorldTex != 0L);
        look.update(frame, moonPhaseIndex, (float) clampedDt);
        ShadeDims.update(frame, look, level, sky, camera.blockPos, (float) clampedDt, snap, applied.dimensions());
        shadowPass.prepare(device.handle(), camera, sky, frame, applied.shadows());
        // The fog colour in HDR once per frame (was shadeLdrToHdr per fragment: ~13 pow per pixel on every surface and the sky
        // whenever fog applies, ~8 ms of the sky pass alone underwater at 3024x1742 on an M1 Pro)
        float[] fogHdr = look.ldrToHdr(frame.fogColor[0], frame.fogColor[1], frame.fogColor[2]);
        System.arraycopy(fogHdr, 0, frame.fogColorHdr, 0, 3);
        atmosphere.prepare(device.handle(), level, camera, frame, look, mc.options.getCloudStatus(), state.cloudHeight,
            (float) clampedDt, snap, w, h, settings.atmosphere(), settings.sky());

        ringSlot = (ringSlot + 1) % RING_SLOTS;
        ByteBuffer slotBb = ringSeg.asSlice((long) ringSlot * RING_SLOT_STRIDE, RING_SLOT_STRIDE)
            .asByteBuffer().order(ByteOrder.nativeOrder());
        frame.pack(slotBb);
        ByteBuffer lookBb = slotBb.slice(LOOK_OFFSET, ShadeLook.SIZE).order(ByteOrder.nativeOrder());
        look.pack(lookBb, frame);
        ShadeDims.pack(lookBb, slotBb, frame, applied.dimensions(), applied.post().exposureEv(), look.auroraTexActive);

        publishGlobals(ringSlot);
        MetalNative.shadeSetEnabled(device.handle(), true);

        // Bake per-frame sky-view LUT before sky and terrain passes draw.
        MetalNative.shadeFullscreenPass(device.handle(), psoSkyLut, skyLutTex,
            MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);

        atmosphere.renderClouds(device.handle(), frameCounter, texArgSeg);

        if (frame.dimension == ShadeFrame.DIM_OVERWORLD && settings.water().enabled()) {
            water.beginFrame(device.handle(), ringSlot, frame, settings.water(), settings.atmosphere().weather());
        } else {
            water.disableFrame(device.handle());
        }

        // Dynamic lights (P6a): gather + pack this frame's lights and encode the visibility / irradiance volumes on the
        // frame's command buffer before any world pass draws (every dimension, like upstream).
        if (DynLights.ON) {
            ShadeSettings.Lights lights = settings.lights();
            if (lights.dynamic() && lights.strength() > 0f) {
                DynLightConfig.applyLive(lights.count(), DynLightConfig.RANGE, lights.strength() * DynLightConfig.STRENGTH,
                    DynLightConfig.HAND, lights.entities() && DynLightConfig.OTHERS, DynLightConfig.FLICKER);
                DynLights.frame(device.handle(), device.handle(), camera, level, partial);
            } else {
                DynLights.disable(device.handle());
            }
        }
        if (ColorLights.ON) {
            ShadeSettings.Lights lights = settings.lights();
            boolean colour = lights.colored() && lights.coloredStrength() > 0f;
            if (colour || lights.smoothBlock()) {
                // Coloured block light (P6b) and smooth block light: reads, spread and uploads before the world passes.
                boolean activeDim = frame.dimension == ShadeFrame.DIM_OVERWORLD || ShadeDims.isLit();
                ColorLights.applyLive(colour && activeDim, lights.coloredStrength(), lights.coloredGlow(), lights.smoothBlock() && activeDim);
                ColorLights.frame(device.handle(), level, camera.pos.x, camera.pos.y, camera.pos.z);
            } else {
                ColorLights.disable(device.handle());
            }
        }

        worldMainColor = color;
        worldDepth = main.getDepthTexture();
        worldRedirectActive = true;
        handPassActive = false;
    }

    /** Encodes shadow depth cascades just before the main frame graph executes. */
    public void renderShadows() {
        if (!isEnabled() || !isReady()) return;
        shadowPass.render(device.handle());
    }

    /** Captures opaque HDR color + depth and builds the SSR depth pyramid before translucent terrain draws. */
    public ShadeShaderPatcher.Variant onTranslucentTerrainBind() {
        if (isWorldRedirectActive() && frame.dimension == ShadeFrame.DIM_OVERWORLD && settings.water().enabled()) {
            water.captureIfNeeded(device.handle());
            if (!frame.underwater) return ShadeShaderPatcher.Variant.HDR_WORLD_WATER_ABOVE;
        }
        return ShadeShaderPatcher.Variant.HDR_WORLD;
    }

    /** Called before {@code render3dHud} (or {@code FogRenderer.endFrame}): bloom + auto-exposure + tonemap to mainColor. */
    public void finishWorld(RenderTarget main) {
        if (!worldRedirectActive) return;
        worldRedirectActive = false;
        if (!isReady() || worldMainColor == null) {
            MetalNative.shadeSetEnabled(device.handle(), false);
            return;
        }
        long ctx = device.handle();
        GpuTexture outTex = main != null && main.getColorTexture() != null ? main.getColorTexture() : worldMainColor;
        if (!(outTex instanceof CelestiaTexture ct)) {
            MetalNative.shadeSetEnabled(ctx, false);
            return;
        }
        GpuTexture depthGpu = worldDepth != null ? worldDepth : (main != null ? main.getDepthTexture() : null);
        long depthPtr = (depthGpu instanceof CelestiaTexture dt) ? dt.handle() : dummyShadowTex;

        if (prevHdrWorldTex != 0L) {
            MetalNative.blitCopyTextureFull(ctx, hdrWorldTex, prevHdrWorldTex);
            hasPrevHdrWorld = true;
        }

        long sceneTex = hdrWorldTex;
        if (motionEligible && psoMotion != 0L && settings.post().motionBlur()
            && settings.post().motionBlurStrength() > 0f && depthGpu instanceof CelestiaTexture) {
            ensureMotionTarget(hdrWidth, hdrHeight);
            if (motionTex != 0L) {
                ByteBuffer mp = pushSeg.asSlice(0, 32).asByteBuffer().order(ByteOrder.nativeOrder());
                mp.putFloat(0, settings.post().motionBlurStrength());
                mp.putFloat(4, 1f);
                mp.putFloat(8, 1f);
                mp.putFloat(12, (frame.jitterX != 0f || frame.jitterY != 0f) ? 1f : 0f);
                mp.putFloat(16, hdrWidth);
                mp.putFloat(20, hdrHeight);
                mp.putFloat(24, 0f);
                mp.putFloat(28, 0f);
                texArgSeg.set(ValueLayout.JAVA_LONG, 0, hdrWorldTex);
                texArgSeg.set(ValueLayout.JAVA_LONG, 8, depthPtr);
                MetalNative.shadeFullscreenPass(ctx, psoMotion, motionTex,
                    texArgSeg, 2, MemorySegment.NULL, 0, pushSeg, 32);
                sceneTex = motionTex;
            }
        }

        int n = activeBloomLevels;
        float w0 = 0f, bloomNorm = 0f;
        float bloomShift = n > 0 ? Math.max(0f, (float) (Math.log(1964.0 / Math.max(bloomHeight, 1)) / Math.log(2.0))) : 0f;
        int levelsUsed = n > 4 ? Math.max(4, Math.min(n, n - Math.round(bloomShift))) : n;

        boolean bloom = settings.post().bloom() && settings.post().bloomStrength() > 0f;
        if (!bloom) levelsUsed = Math.min(levelsUsed, 3); // Retain the exposure meter input.
        if (levelsUsed > 0) {
            ByteBuffer dp = pushSeg.asSlice(0, 16).asByteBuffer().order(ByteOrder.nativeOrder());
            dp.putFloat(0, 1f).putFloat(4, 1f).putFloat(8, 0f).putFloat(12, 0f);
            texArgSeg.set(ValueLayout.JAVA_LONG, 0, sceneTex);
            MetalNative.shadeFullscreenPass(ctx, psoBloomDown0, bloomDownTex[0],
                texArgSeg, 1, MemorySegment.NULL, 0, pushSeg, 16);

            for (int i = 1; i < levelsUsed; i++) {
                texArgSeg.set(ValueLayout.JAVA_LONG, 0, bloomDownTex[i - 1]);
                MetalNative.shadeFullscreenPass(ctx, psoBloomDown, bloomDownTex[i],
                    texArgSeg, 1, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            }
        }
        if (bloom && levelsUsed > 0) {
            float spectrum = look.bloomSpectrum();
            float sum = 0f;
            if (levelsUsed >= 3) {
                float wLast = (float) Math.pow(levelsUsed + bloomShift, spectrum);
                sum += wLast;
                for (int i = levelsUsed - 2; i >= 1; i--) {
                    float wi = (float) Math.pow(i + 1 + bloomShift, spectrum);
                    sum += wi;
                    ByteBuffer upP = pushSeg.asSlice(0, 16).asByteBuffer().order(ByteOrder.nativeOrder());
                    upP.putFloat(0, wi).putFloat(4, i == levelsUsed - 2 ? wLast : 1f).putFloat(8, 0f).putFloat(12, 0f);
                    texArgSeg.set(ValueLayout.JAVA_LONG, 0, bloomDownTex[i]);
                    texArgSeg.set(ValueLayout.JAVA_LONG, 8, i == levelsUsed - 2 ? bloomDownTex[levelsUsed - 1] : bloomAccumTex[i + 1]);
                    MetalNative.shadeFullscreenPass(ctx, psoBloomUp, bloomAccumTex[i],
                        texArgSeg, 2, MemorySegment.NULL, 0, pushSeg, 16);
                }
            } else {
                for (int i = levelsUsed - 1; i >= 1; i--) {
                    float wi = (float) Math.pow(i + 1 + bloomShift, spectrum);
                    sum += wi;
                    ByteBuffer upP = pushSeg.asSlice(0, 16).asByteBuffer().order(ByteOrder.nativeOrder());
                    upP.putFloat(0, wi).putFloat(4, i == levelsUsed - 1 ? 0f : 1f).putFloat(8, 0f).putFloat(12, 0f);
                    texArgSeg.set(ValueLayout.JAVA_LONG, 0, bloomDownTex[i]);
                    texArgSeg.set(ValueLayout.JAVA_LONG, 8, i == levelsUsed - 1 ? bloomDownTex[i] : bloomAccumTex[i + 1]);
                    MetalNative.shadeFullscreenPass(ctx, psoBloomUp, bloomAccumTex[i],
                        texArgSeg, 2, MemorySegment.NULL, 0, pushSeg, 16);
                }
            }
            w0 = (float) Math.pow(1 + bloomShift, spectrum);
            sum += w0;
            bloomNorm = 1f / Math.max(sum, 1e-4f);
        }

        long volumeTex = atmosphere.renderVolume(ctx, depthGpu instanceof CelestiaTexture ? depthPtr : 0L, texArgSeg);
        long ao = depthGpu instanceof CelestiaTexture && frame.fogType == ShadeFrame.FOG_AIR
            ? renderAo(ctx, depthPtr) : 0L;
        aoActive = ao != 0L;

        // ShadeFinalParams: 6 x float4 = 96 B
        ByteBuffer fp = pushSeg.asSlice(0, 96).asByteBuffer().order(ByteOrder.nativeOrder());
        fp.putFloat(0, bloomNorm).putFloat(4, bloom && levelsUsed > 1 ? 1f : 0f).putFloat(8, frameCounter & 0xffff).putFloat(12, frame.debug);
        fp.putFloat(16, w0).putFloat(20, 1f).putFloat(24, 1.6f).putFloat(28, 0.4f);
        fp.putFloat(32, volumeTex != 0L ? 1f : 0f).putFloat(36, ao != 0L ? settings.shadows().ssaoStrength() : 0f).putFloat(40, 1f).putFloat(44, 1f);
        fp.putFloat(48, hdrWidth).putFloat(52, hdrHeight).putFloat(56, 0f).putFloat(60, 0f);
        fp.putFloat(64, 0f).putFloat(68, 1f).putFloat(72, 1f).putFloat(76, 1f);
        fp.putFloat(80, 0f).putFloat(84, 0f).putFloat(88, 0f).putFloat(92, 0f);

        texArgSeg.set(ValueLayout.JAVA_LONG, 0, sceneTex);
        texArgSeg.set(ValueLayout.JAVA_LONG, 8, bloom && levelsUsed > 1 ? bloomAccumTex[1] : sceneTex);
        texArgSeg.set(ValueLayout.JAVA_LONG, 16, depthPtr);
        texArgSeg.set(ValueLayout.JAVA_LONG, 24, levelsUsed > 0 ? bloomDownTex[0] : sceneTex);
        texArgSeg.set(ValueLayout.JAVA_LONG, 32, volumeTex != 0L ? volumeTex : sceneTex);

        texArgSeg.set(ValueLayout.JAVA_LONG, 40, ao != 0L ? ao : sceneTex);
        int outFmt = MetalConst.toNativeFormat(outTex.getFormat());
        boolean useDimsFinal = ShadeDims.isLit()
            || frame.fogType == ShadeFrame.FOG_LAVA
            || frame.fogType == ShadeFrame.FOG_POWDER_SNOW;
        long psoFinal = useDimsFinal
            ? ((outFmt == MetalConst.FMT_BGRA8_UNORM) ? psoFinalDimsBgra8 : psoFinalDimsRgba8)
            : ((outFmt == MetalConst.FMT_BGRA8_UNORM) ? psoFinalBgra8 : psoFinalRgba8);
        MetalNative.shadeFullscreenPass(ctx, psoFinal, ct.handle(),
            texArgSeg, 6, MemorySegment.NULL, 0, pushSeg, 96);

        // Update auto-exposure histogram & exposure scalar for next frame
        if (levelsUsed > 2) {
            int hw = Math.max(1, hdrWidth >> 3);
            int hh = Math.max(1, hdrHeight >> 3);
            int gx = Math.max(1, (hw / 2 + 7) / 8);
            int gy = Math.max(1, (hh / 2 + 7) / 8);
            long lookOff = (long) ringSlot * RING_SLOT_STRIDE + LOOK_OFFSET;
            MetalNative.shadeExposureRun(ctx, psoHist, psoExp, bloomDownTex[2],
                gpuBuf, 0L, ringBuf, lookOff, gx, gy);
        }

        // Disable shader globals for post/GUI passes unless hand pass re-enables them
        MetalNative.shadeSetEnabled(ctx, false);
    }

    private long renderAo(long ctx, long depth) {
        if (psoAo == 0L || (frame.dimension != ShadeFrame.DIM_OVERWORLD && !ShadeDims.isLit())
            || !settings.shadows().ssao() || settings.shadows().ssaoStrength() == 0f) return 0L;
        int w = (hdrWidth + 1) / 2, h = (hdrHeight + 1) / 2;
        if (aoTexture == 0L || aoW != w || aoH != h) {
            if (aoTexture != 0L) MetalNative.textureDestroy(ctx, aoTexture);
            aoTexture = MetalNative.textureCreate(ctx, MetalConst.FMT_RG16_FLOAT, w, h, 1, 1,
                false, true, true, false, "CelestiaShade.SSAO");
            aoW = w;
            aoH = h;
        }
        if (aoTexture != 0L) {
            texArgSeg.setAtIndex(ValueLayout.JAVA_LONG, 0, depth);
            MetalNative.shadeFullscreenPass(ctx, psoAo, aoTexture, texArgSeg, 1,
                MemorySegment.NULL, 0, MemorySegment.NULL, 0);
        }
        return aoTexture;
    }

    public void beforeHand(RenderTarget main) {
        finishWorld(main);
        if (isReady() && isEnabled()) {
            handPassActive = true;
            MetalNative.shadeSetEnabled(device.handle(), true);
        }
    }

    public void afterHand() {
        handPassActive = false;
        if (device.handle() != 0L) {
            MetalNative.shadeSetEnabled(device.handle(), false);
        }
    }

    public void onFrameEnd() {
        worldRedirectActive = false;
        handPassActive = false;
        worldMainColor = null;
        worldDepth = null;
        if (device.handle() != 0L) {
            MetalNative.shadeSetEnabled(device.handle(), false);
        }
    }

    /** Returns {@code true} when a render pass's color attachment targets the redirected world main color. */
    public boolean shouldRedirect(GpuTexture colorTex) {
        return isWorldRedirectActive() && worldMainColor != null && colorTex == worldMainColor;
    }

    public long redirectColorViewHandle(GpuTextureView originalView) {
        if (originalView != null && shouldRedirect(originalView.texture())) {
            return hdrWorldView;
        }
        return (originalView instanceof CelestiaTextureView ctv) ? ctv.handle() : 0L;
    }

    public long redirectColorTextureHandle(GpuTexture tex) {
        if (shouldRedirect(tex)) {
            return hdrWorldTex;
        }
        return (tex instanceof CelestiaTexture ct) ? ct.handle() : 0L;
    }

    public float[] transformClearColorToHdr(float r, float g, float b, float a) {
        float[] hdrRgb = look.ldrToHdr(r, g, b);
        return new float[] {hdrRgb[0], hdrRgb[1], hdrRgb[2], a};
    }

    public String statusSummary() {
        if (!isEnabled()) return "Off";
        if (failed) return "Fallback (init failed)";
        if (!initialized) return "Pending";
        float ex = gpuView != null ? gpuView.getFloat(176) : 1.0f;
        String waterMode = water.isActive() && settings != null
            ? (settings.water().screenReflections() ? " | Water SSR" : " | Water") : "";
        String effects = waterMode
            + (atmosphere.hasClouds() ? " | Clouds" : "")
            + (atmosphere.hasAurora() ? " | Aurora" : "")
            + (atmosphere.hasVolume() ? " | Volumetrics" : "")
            + (aoActive ? " | SSAO" : "")
            + (settings != null && settings.post().motionBlur() && settings.post().motionBlurStrength() > 0f ? " | Motion Blur" : "")
            + (DynLights.activeCount() > 0 ? " | Lights " + DynLights.activeCount() : "")
            + (ColorLights.activeSlots() > 0 ? " | Colour " + ColorLights.activeSlots() : "");
        if (shadowPass.isActive()) {
            return String.format(java.util.Locale.ROOT,
                "P6 HDR (%dx%d) | Shadows %d %s (%dk/%dk q)%s | ev x%.2f | elev %.0f deg",
                hdrWidth, hdrHeight, shadowPass.resolution(), shadowPass.sourceName(),
                shadowPass.lastNearQuads() / 1000, shadowPass.lastFarQuads() / 1000, effects, ex, look.elevation);
        }
        return String.format(java.util.Locale.ROOT, "P6 HDR (%dx%d)%s | ev x%.2f | elev %.0f deg",
            hdrWidth, hdrHeight, effects, ex, look.elevation);
    }

    private void ensureHdrTarget(int w, int h) {
        if (hdrWorldTex != 0L && prevHdrWorldTex != 0L && hdrWidth == w && hdrHeight == h) return;
        long ctx = device.handle();
        if (hdrWorldView != 0L) { MetalNative.textureViewDestroy(ctx, hdrWorldView); hdrWorldView = 0L; }
        if (hdrWorldTex != 0L) { MetalNative.textureDestroy(ctx, hdrWorldTex); hdrWorldTex = 0L; }
        if (prevHdrWorldTex != 0L) { MetalNative.textureDestroy(ctx, prevHdrWorldTex); prevHdrWorldTex = 0L; }
        if (motionTex != 0L) { MetalNative.textureDestroy(ctx, motionTex); motionTex = 0L; motionWidth = motionHeight = 0; }
        hasPrevHdrWorld = false;
        motionEligible = false;
        hdrWorldTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, w, h, 1, 1,
            false, true, true, false, "CelestiaShade.HdrWorld");
        hdrWorldView = MetalNative.textureViewCreate(ctx, hdrWorldTex, 0, 1);
        prevHdrWorldTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, w, h, 1, 1,
            false, false, true, false, "CelestiaShade.PrevHdrWorld");
        hdrWidth = w;
        hdrHeight = h;
    }

    private void ensureMotionTarget(int w, int h) {
        if (motionTex != 0L && motionWidth == w && motionHeight == h) return;
        long ctx = device.handle();
        if (motionTex != 0L) { MetalNative.textureDestroy(ctx, motionTex); motionTex = 0L; }
        motionTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, w, h, 1, 1,
            false, true, true, false, "CelestiaShade.MotionBlur");
        motionWidth = w;
        motionHeight = h;
    }

    private void ensureBloomTargets(int w, int h) {
        if (bloomWidth == w && bloomHeight == h && activeBloomLevels > 0) return;
        long ctx = device.handle();
        for (int i = 0; i < BLOOM_LEVELS; i++) {
            if (bloomDownTex[i] != 0L) { MetalNative.textureDestroy(ctx, bloomDownTex[i]); bloomDownTex[i] = 0L; }
            if (bloomAccumTex[i] != 0L) { MetalNative.textureDestroy(ctx, bloomAccumTex[i]); bloomAccumTex[i] = 0L; }
        }
        int bw = Math.max(1, w >> 1), bh = Math.max(1, h >> 1);
        int count = 0;
        for (int i = 0; i < BLOOM_LEVELS; i++) {
            bloomDownTex[i] = MetalNative.textureCreate(ctx, BLOOM_FORMAT, bw, bh, 1, 1,
                false, true, true, false, "CelestiaShade.BloomDown" + i);
            if (i >= 1 && i < BLOOM_LEVELS - 1) {
                bloomAccumTex[i] = MetalNative.textureCreate(ctx, BLOOM_FORMAT, bw, bh, 1, 1,
                    false, true, true, false, "CelestiaShade.BloomAccum" + i);
            }
            count++;
            if (bw <= 2 || bh <= 2) break;
            bw = Math.max(1, bw >> 1);
            bh = Math.max(1, bh >> 1);
        }
        activeBloomLevels = count;
        bloomWidth = w;
        bloomHeight = h;
    }

    /**
     * The world pack's MSL changed (pack switch, a recompile option, reload): tear every world-renderer library, pipeline and
     * target down (natively retired, so in-flight frames keep theirs) and initialize again from the new sources on this frame.
     * A pack that fails to compile leaves the world on standard rendering, as a failed first initialization does.
     */
    private synchronized void reloadShaders() {
        int target = ShadeShaderPatcher.epoch();
        LOGGER.info("CelestiaShade: world pack sources changed ({}), rebuilding the world renderer", ShadeShaderPatcher.worldPackKey());
        if (gpuView != null && initialized) {
            // Drain first: the last submitted frame may still be writing it.
            MetalNative.deviceWaitIdle(device.handle());
            carriedGpu = new byte[GPU_BUF_SIZE];
            gpuView.get(0, carriedGpu);
        }
        close();
        activeInstance = this;
        failed = false;
        water.resetFailure();
        atmosphere.resetFailure();
        hasPrevHdrWorld = false;
        hasPrevious = false;
        snapRequested = true;
        shaderEpoch = target;
    }

    public synchronized void close() {
        if (activeInstance == this) activeInstance = null;
        worldRedirectActive = false;
        handPassActive = false;
        long ctx = device.handle();
        shadowPass.close(ctx);
        water.close(ctx);
        DynLights.close(ctx);
        ColorLights.close(ctx);
        atmosphere.close(ctx);
        if (ctx != 0L) {
            MetalNative.shadeSetEnabled(ctx, false);
            MetalNative.shadeSetGlobals(ctx, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
            MetalNative.shadeSetResource(ctx, 0, 0L);
            MetalNative.shadeSetResource(ctx, 1, 0L);
            if (hdrWorldView != 0L) { MetalNative.textureViewDestroy(ctx, hdrWorldView); hdrWorldView = 0L; }
            if (hdrWorldTex != 0L) { MetalNative.textureDestroy(ctx, hdrWorldTex); hdrWorldTex = 0L; }
            if (prevHdrWorldTex != 0L) { MetalNative.textureDestroy(ctx, prevHdrWorldTex); prevHdrWorldTex = 0L; }
            if (motionTex != 0L) { MetalNative.textureDestroy(ctx, motionTex); motionTex = 0L; }
            hasPrevHdrWorld = false;
            motionEligible = false;
            motionWidth = motionHeight = 0;
            for (int i = 0; i < BLOOM_LEVELS; i++) {
                if (bloomDownTex[i] != 0L) { MetalNative.textureDestroy(ctx, bloomDownTex[i]); bloomDownTex[i] = 0L; }
                if (bloomAccumTex[i] != 0L) { MetalNative.textureDestroy(ctx, bloomAccumTex[i]); bloomAccumTex[i] = 0L; }
            }
            if (psoAo != 0L) MetalNative.pipelineDestroy(ctx, psoAo);
            if (aoTexture != 0L) MetalNative.textureDestroy(ctx, aoTexture);
            psoAo = aoTexture = 0L;
            if (psoSkyLut != 0L) MetalNative.pipelineDestroy(ctx, psoSkyLut);
            if (psoBloomDown0 != 0L) MetalNative.pipelineDestroy(ctx, psoBloomDown0);
            if (psoBloomDown != 0L) MetalNative.pipelineDestroy(ctx, psoBloomDown);
            if (psoBloomUp != 0L) MetalNative.pipelineDestroy(ctx, psoBloomUp);
            if (psoFinalRgba8 != 0L) MetalNative.pipelineDestroy(ctx, psoFinalRgba8);
            if (psoFinalBgra8 != 0L) MetalNative.pipelineDestroy(ctx, psoFinalBgra8);
            if (psoFinalDimsRgba8 != 0L) MetalNative.pipelineDestroy(ctx, psoFinalDimsRgba8);
            if (psoFinalDimsBgra8 != 0L) MetalNative.pipelineDestroy(ctx, psoFinalDimsBgra8);
            if (psoMotion != 0L) MetalNative.pipelineDestroy(ctx, psoMotion);
            if (psoHist != 0L) MetalNative.computePipelineDestroy(ctx, psoHist);
            if (psoExp != 0L) MetalNative.computePipelineDestroy(ctx, psoExp);
            if (dummyShadowTex != 0L) MetalNative.textureDestroy(ctx, dummyShadowTex);
            if (skyLutTex != 0L) MetalNative.textureDestroy(ctx, skyLutTex);
            if (milkyWayTex != 0L) MetalNative.textureDestroy(ctx, milkyWayTex);
            if (shadowCompareSamp != 0L) MetalNative.samplerDestroy(ctx, shadowCompareSamp);
            if (linearClampSamp != 0L) MetalNative.samplerDestroy(ctx, linearClampSamp);
            if (ringBuf != 0L) MetalNative.bufferDestroy(ctx, ringBuf);
            if (resBuf != 0L) MetalNative.bufferDestroy(ctx, resBuf);
            if (gpuBuf != 0L) MetalNative.bufferDestroy(ctx, gpuBuf);
        }
        if (lutVsFn != 0L) MetalNative.functionDestroy(lutVsFn);
        if (lutFsFn != 0L) MetalNative.functionDestroy(lutFsFn);
        if (lutLib != 0L) MetalNative.libraryDestroy(lutLib);
        if (fsVsFn != 0L) MetalNative.functionDestroy(fsVsFn);
        if (bloomDown0Fn != 0L) MetalNative.functionDestroy(bloomDown0Fn);
        if (bloomDownFn != 0L) MetalNative.functionDestroy(bloomDownFn);
        if (bloomUpFn != 0L) MetalNative.functionDestroy(bloomUpFn);
        if (finalFn != 0L) MetalNative.functionDestroy(finalFn);
        if (finalDimsFn != 0L) MetalNative.functionDestroy(finalDimsFn);
        if (motionFn != 0L) MetalNative.functionDestroy(motionFn);
        if (histFn != 0L) MetalNative.functionDestroy(histFn);
        if (expFn != 0L) MetalNative.functionDestroy(expFn);
        if (milkyWayFn != 0L) MetalNative.functionDestroy(milkyWayFn);
        if (postLib != 0L) MetalNative.libraryDestroy(postLib);
        psoSkyLut = psoBloomDown0 = psoBloomDown = psoBloomUp = psoFinalRgba8 = psoFinalBgra8 = psoFinalDimsRgba8 = psoFinalDimsBgra8 = psoMotion = psoHist = psoExp = 0L;
        dummyShadowTex = skyLutTex = milkyWayTex = shadowCompareSamp = linearClampSamp = 0L;
        ringBuf = resBuf = gpuBuf = 0L;
        lutVsFn = lutFsFn = lutLib = fsVsFn = bloomDown0Fn = bloomDownFn = bloomUpFn = finalFn = finalDimsFn = motionFn = histFn = expFn = milkyWayFn = postLib = 0L;
        initialized = false;
    }
}
