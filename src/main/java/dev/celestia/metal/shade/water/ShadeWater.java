// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/water/ShadeWater.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.water;

import com.mojang.logging.LogUtils;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import dev.celestia.metal.shade.ShadeSettings;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.slf4j.Logger;

/**
 * Coordinates P3a native MSL water rendering: 176-byte {@code ShadeWaterParams} ring buffer,
 * mipmapped wave/detail/swell textures baked via fullscreen passes, scene copy + 3-pass
 * {@code RG16Float} depth pyramid capture on switch to translucent terrain, and GPU SSR/Fresnel state.
 */
public final class ShadeWater {
    private static final Logger LOGGER = LogUtils.getLogger();

    public static final int PARAMS_BYTES = 176;
    private static final int RING_SLOTS = 4;
    private static final int SLOT_STRIDE = 256;

    private static final int WAVE_SIZE = 512, WAVE_MIPS = Integer.SIZE - Integer.numberOfLeadingZeros(WAVE_SIZE);
    private static final int DETAIL_SIZE = 256, DETAIL_MIPS = 9;
    private static final int SWELL_SIZE = 256, SWELL_MIPS = 9;

    private long paramsBuf;
    private MemorySegment paramsSeg;
    private long wavesTex, detailTex, swellTex;
    private long waterLib;
    private long fsVsFn, bakeFn, bakeDetailFn, bakeSwellFn, pyrFn, pyr2Fn;
    private long psoBake, psoBakeDetail, psoBakeSwell, psoPyr, psoPyr2;

    private final float[] stillRect = new float[4];
    private final float[] flowRect = new float[4];
    private long currentSlotOffset;
    private int swellCounter;
    private boolean initialized;
    private boolean failed;
    private boolean capturedThisFrame;
    private boolean wavesReady, swellReady;
    private boolean activeThisFrame;
    private boolean screenReflections;

    public boolean isActive() {
        return initialized && !failed && capturedThisFrame;
    }

    public boolean ensureInitialized(long ctx) {
        if (initialized) return true;
        if (failed || ctx == 0L) return false;
        try {
            paramsBuf = MetalNative.bufferCreate(ctx, (long) RING_SLOTS * SLOT_STRIDE, null, "CelestiaWater.Params");
            if (paramsBuf == 0L) throw new IllegalStateException("Failed creating ShadeWaterParams buffer");
            paramsSeg = MemorySegment.ofAddress(MetalNative.bufferContents(paramsBuf))
                .reinterpret((long) RING_SLOTS * SLOT_STRIDE);

            wavesTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, WAVE_SIZE, WAVE_SIZE, 1, WAVE_MIPS,
                false, true, true, false, "CelestiaWater.Waves");
            detailTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, DETAIL_SIZE, DETAIL_SIZE, 1, DETAIL_MIPS,
                false, true, true, false, "CelestiaWater.Detail");
            swellTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, SWELL_SIZE, SWELL_SIZE, 1, SWELL_MIPS,
                false, true, true, false, "CelestiaWater.Swell");
            if (wavesTex == 0L || detailTex == 0L || swellTex == 0L) {
                throw new IllegalStateException("Failed creating ShadeWater wave textures");
            }

            StringBuilder err = new StringBuilder();
            waterLib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.waterBakeSource(), "CelestiaWater.Bake", true, err);
            if (waterLib == 0L) throw new IllegalStateException("Water MSL bake compile failed: " + err);

            fsVsFn = MetalNative.compileFunction(waterLib, "shade_fs_vs", false, 0, 0, err);
            bakeFn = MetalNative.compileFunction(waterLib, "shade_water_bake_fs", false, 0, 0, err);
            bakeDetailFn = MetalNative.compileFunction(waterLib, "shade_water_bake_detail_fs", false, 0, 0, err);
            bakeSwellFn = MetalNative.compileFunction(waterLib, "shade_water_bake_swell_fs", false, 0, 0, err);
            pyrFn = MetalNative.compileFunction(waterLib, "shade_water_pyr_fs", false, 0, 0, err);
            pyr2Fn = MetalNative.compileFunction(waterLib, "shade_water_pyr2_fs", false, 0, 0, err);

            psoBake = CelestiaShade.createFullscreenPso(ctx, fsVsFn, bakeFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaWater.BakeWaves", err);
            psoBakeDetail = CelestiaShade.createFullscreenPso(ctx, fsVsFn, bakeDetailFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaWater.BakeDetail", err);
            psoBakeSwell = CelestiaShade.createFullscreenPso(ctx, fsVsFn, bakeSwellFn, MetalConst.FMT_RGBA16_FLOAT, "CelestiaWater.BakeSwell", err);
            psoPyr = CelestiaShade.createFullscreenPso(ctx, fsVsFn, pyrFn, MetalConst.FMT_RG16_FLOAT, "CelestiaWater.Pyr8", err);
            psoPyr2 = CelestiaShade.createFullscreenPso(ctx, fsVsFn, pyr2Fn, MetalConst.FMT_RG16_FLOAT, "CelestiaWater.PyrReduce", err);

            initialized = true;
            LOGGER.info("CelestiaShade P3a water module initialized (512x512 waves + 256x256 ripples/swell + RG16F depth pyramid)");
            return true;
        } catch (Throwable t) {
            failed = true;
            LOGGER.error("CelestiaWater initialization failed; water shaders disabled", t);
            close(ctx);
            return false;
        }
    }

    public void beginFrame(long ctx, int ringSlot, ShadeFrame frame, ShadeSettings.Water options, boolean weather) {
        if (!ensureInitialized(ctx)) {
            disableFrame(ctx);
            return;
        }
        WaterFrame.sprites(stillRect, flowRect);
        int slot = Math.floorMod(ringSlot, RING_SLOTS);
        currentSlotOffset = (long) slot * SLOT_STRIDE;

        // Capture is only known after the world starts drawing. Keep the last bake available
        // when translucent terrain reappears, then update it on the next frame.
        boolean wavesEnabled = options.waves() && options.waveStrength() > 0f;
        boolean swellEnabled = options.swell() > 0f && !frame.underwater;
        boolean bakeWaves = wavesEnabled && (capturedThisFrame || !wavesReady);
        boolean bakeSwell = swellEnabled && (!swellReady || (capturedThisFrame && (++swellCounter & 1) != 0));
        if (bakeWaves) {
            MetalNative.shadeFullscreenPass(ctx, psoBake, wavesTex,
                MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            MetalNative.shadeFullscreenPass(ctx, psoBakeDetail, detailTex,
                MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            wavesReady = true;
        }
        if (bakeSwell) {
            MetalNative.shadeFullscreenPass(ctx, psoBakeSwell, swellTex,
                MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            swellReady = true;
        }
        if (bakeWaves || bakeSwell) {
            MetalNative.waterGenerateMipmaps(ctx, bakeWaves ? wavesTex : 0L, bakeWaves ? detailTex : 0L,
                bakeSwell ? swellTex : 0L);
        }

        ByteBuffer b = paramsSeg.asSlice(currentSlotOffset, PARAMS_BYTES).asByteBuffer().order(ByteOrder.nativeOrder());
        packParams(b, stillRect, flowRect, false, frame.waterSurfaceAbove, weather ? frame.rain : 0f,
            wavesEnabled && wavesReady, swellEnabled && swellReady, options);

        capturedThisFrame = false;
        activeThisFrame = true;
        screenReflections = options.screenReflections();
        MetalNative.waterSetParams(ctx, paramsBuf, currentSlotOffset, wavesTex, detailTex, true);
        MetalNative.shadeSetResource(ctx, 15, swellEnabled && swellReady ? swellTex : 0L);
    }

    public void disableFrame(long ctx) {
        capturedThisFrame = false;
        activeThisFrame = false;
        if (ctx != 0L) {
            MetalNative.waterSetParams(ctx, 0L, 0L, 0L, 0L, false);
            MetalNative.shadeSetResource(ctx, 15, 0L);
        }
    }

    public boolean captureIfNeeded(long ctx) {
        if (!initialized || failed || !activeThisFrame || capturedThisFrame || ctx == 0L) return false;
        int ok = MetalNative.waterCapture(ctx, screenReflections ? psoPyr : 0L, screenReflections ? psoPyr2 : 0L);
        if (ok != 0) {
            capturedThisFrame = true;
            // Mark scene/depth copies valid (state.x = 1) for all translucent terrain fragments rendered afterwards.
            paramsSeg.asSlice(currentSlotOffset, PARAMS_BYTES).asByteBuffer().order(ByteOrder.nativeOrder()).putFloat(32, 1f);
            return true;
        }
        return false;
    }

    public static void packParams(ByteBuffer p, float[] still, float[] flow,
                                  boolean copyValid, float surfaceAbove, float wetness,
                                  boolean wavesReady, boolean swellReady, ShadeSettings.Water options) {
        for (int i = 0; i < 4; i++) p.putFloat(i * 4, still != null ? still[i] : 0f);
        for (int i = 0; i < 4; i++) p.putFloat(16 + i * 4, flow != null ? flow[i] : 0f);
        // state: x copies valid (0/1), y surfaceAbove (underwater), z wetness, w baked waves ready
        p.putFloat(32, copyValid ? 1f : 0f).putFloat(36, surfaceAbove).putFloat(40, wetness).putFloat(44, wavesReady ? 1f : 0f);
        // tune: x wave strength, y SSR max dist (blocks), z reflection strength, w caustics
        p.putFloat(48, options.waveStrength()).putFloat(52, options.screenReflections() ? options.ssrDistance() : 0f)
            .putFloat(56, options.reflectionStrength()).putFloat(60, options.caustics());
        // swell: x strength, y masking k, z crest glow, w Fresnel share
        p.putFloat(64, options.swell()).putFloat(68, 0.45f).putFloat(72, 0.5f).putFloat(76, 1f);
        // swell2: x openFar (< 0 = full swell everywhere), y mirrorCalm, z long calm, w detail ripple scale
        p.putFloat(80, -1f).putFloat(84, 0.75f).putFloat(88, 0.55f).putFloat(92, 2.0f);
        // swell3: x swellRefl, y glitter, z glintSharp, w reflTemporal
        p.putFloat(96, 0.45f).putFloat(100, 1.5f).putFloat(104, 0.3f).putFloat(108, 0f);
        // rhist: inactive
        p.putFloat(112, 0f).putFloat(116, 0f).putFloat(120, 0f).putFloat(124, 0f);
        // mirror: x mirrorAA, y reflFilter, z reflPano, w causticGain
        p.putFloat(128, 0f).putFloat(132, 1f).putFloat(136, 0f).putFloat(140, 2.5f);
        // far: x dist, y band, z dev, w baked swell ready
        p.putFloat(144, 176f).putFloat(148, 64f).putFloat(152, (float) Integer.getInteger("celestiametal.shade.water.devSsr", 0)).putFloat(156, swellReady ? 1f : 0f);
        int budget = Math.clamp(Integer.getInteger("celestiametal.shade.water.ssrBudget", options.ssrBudget()), 8, 32);
        // quality: x SSR budget, y physical Snell's window from below (0 = Photon's default: the world above, no TIR)
        p.putInt(160, budget).putInt(164, options.snellWindow() ? 1 : 0).putInt(168, 0).putInt(172, 0);
    }

    public void close(long ctx) {
        activeThisFrame = false;
        capturedThisFrame = false;
        if (ctx != 0L) {
            MetalNative.waterSetParams(ctx, 0L, 0L, 0L, 0L, false);
            MetalNative.shadeSetResource(ctx, 15, 0L);
            if (psoBake != 0L) MetalNative.pipelineDestroy(ctx, psoBake);
            if (psoBakeDetail != 0L) MetalNative.pipelineDestroy(ctx, psoBakeDetail);
            if (psoBakeSwell != 0L) MetalNative.pipelineDestroy(ctx, psoBakeSwell);
            if (psoPyr != 0L) MetalNative.pipelineDestroy(ctx, psoPyr);
            if (psoPyr2 != 0L) MetalNative.pipelineDestroy(ctx, psoPyr2);
            if (wavesTex != 0L) MetalNative.textureDestroy(ctx, wavesTex);
            if (detailTex != 0L) MetalNative.textureDestroy(ctx, detailTex);
            if (swellTex != 0L) MetalNative.textureDestroy(ctx, swellTex);
            if (paramsBuf != 0L) MetalNative.bufferDestroy(ctx, paramsBuf);
        }
        if (fsVsFn != 0L) MetalNative.functionDestroy(fsVsFn);
        if (bakeFn != 0L) MetalNative.functionDestroy(bakeFn);
        if (bakeDetailFn != 0L) MetalNative.functionDestroy(bakeDetailFn);
        if (bakeSwellFn != 0L) MetalNative.functionDestroy(bakeSwellFn);
        if (pyrFn != 0L) MetalNative.functionDestroy(pyrFn);
        if (pyr2Fn != 0L) MetalNative.functionDestroy(pyr2Fn);
        if (waterLib != 0L) MetalNative.libraryDestroy(waterLib);
        psoBake = psoBakeDetail = psoBakeSwell = psoPyr = psoPyr2 = 0L;
        wavesTex = detailTex = swellTex = paramsBuf = 0L;
        fsVsFn = bakeFn = bakeDetailFn = bakeSwellFn = pyrFn = pyr2Fn = waterLib = 0L;
        paramsSeg = null;
        wavesReady = swellReady = false;
        swellCounter = 0;
        initialized = false;
    }
}
