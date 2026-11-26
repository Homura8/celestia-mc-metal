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
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import net.minecraft.client.multiplayer.ClientLevel;
import org.slf4j.Logger;

/**
 * Coordinates P3a native MSL water rendering: 160-byte {@code ShadeWaterParams} ring buffer,
 * mipmapped wave/detail/swell textures baked via fullscreen passes, scene copy + 3-pass
 * {@code RG16Float} depth pyramid capture on switch to translucent terrain, and GPU SSR/Fresnel state.
 */
public final class ShadeWater {
    private static final Logger LOGGER = LogUtils.getLogger();

    public static final int PARAMS_BYTES = 160;
    private static final int RING_SLOTS = 4;
    private static final int SLOT_STRIDE = 256;

    private static final int WAVE_SIZE = 1024, WAVE_MIPS = 11;
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
    private boolean activeThisFrame;

    public boolean isActive() {
        return initialized && !failed && activeThisFrame;
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
            LOGGER.info("CelestiaShade P3a water module initialized (1024x1024 waves + 256x256 ripples/swell + RG16F depth pyramid)");
            return true;
        } catch (Throwable t) {
            failed = true;
            LOGGER.error("CelestiaWater initialization failed; water shaders disabled", t);
            close(ctx);
            return false;
        }
    }

    public void beginFrame(long ctx, int ringSlot, ShadeFrame frame, ClientLevel level,
                           double camX, double camY, double camZ) {
        if (!ensureInitialized(ctx)) {
            activeThisFrame = false;
            return;
        }
        WaterFrame.sprites(stillRect, flowRect);
        float surfaceAbove = frame.underwater ? WaterFrame.surfaceAbove(level, camX, camY, camZ) : 0f;
        int slot = Math.floorMod(ringSlot, RING_SLOTS);
        currentSlotOffset = (long) slot * SLOT_STRIDE;

        ByteBuffer b = paramsSeg.asSlice(currentSlotOffset, PARAMS_BYTES).asByteBuffer().order(ByteOrder.LITTLE_ENDIAN);
        packParams(b, stillRect, flowRect, false, surfaceAbove, frame.rain, true, true);

        capturedThisFrame = false;
        activeThisFrame = true;

        MetalNative.waterSetParams(ctx, paramsBuf, currentSlotOffset, wavesTex, detailTex, true);
        MetalNative.shadeSetResource(ctx, 15, swellTex);

        // Bake per-frame tiled waves, fine ripples, and bi-frame sea swell + mip chains.
        MetalNative.shadeFullscreenPass(ctx, psoBake, wavesTex, MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
        MetalNative.waterGenerateMipmaps(ctx, wavesTex);

        MetalNative.shadeFullscreenPass(ctx, psoBakeDetail, detailTex, MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
        MetalNative.waterGenerateMipmaps(ctx, detailTex);

        if ((swellCounter++ & 1) == 0) {
            MetalNative.shadeFullscreenPass(ctx, psoBakeSwell, swellTex, MemorySegment.NULL, 0, MemorySegment.NULL, 0, MemorySegment.NULL, 0);
            MetalNative.waterGenerateMipmaps(ctx, swellTex);
        }
    }

    public void disableFrame(long ctx) {
        capturedThisFrame = false;
        activeThisFrame = false;
        if (ctx != 0L) {
            MetalNative.waterSetParams(ctx, 0L, 0L, 0L, 0L, false);
        }
    }

    public boolean captureIfNeeded(long ctx) {
        if (!initialized || failed || !activeThisFrame || capturedThisFrame || ctx == 0L) return false;
        int ok = MetalNative.waterCapture(ctx, psoPyr, psoPyr2);
        if (ok != 0) {
            capturedThisFrame = true;
            // Mark scene/depth copies valid (state.x = 1) for all translucent terrain fragments rendered afterwards.
            paramsSeg.asSlice(currentSlotOffset, PARAMS_BYTES).asByteBuffer().order(ByteOrder.LITTLE_ENDIAN).putFloat(32, 1f);
            return true;
        }
        return false;
    }

    public static void packParams(ByteBuffer p, float[] still, float[] flow,
                                  boolean copyValid, float surfaceAbove, float wetness,
                                  boolean wavesReady, boolean swellReady) {
        for (int i = 0; i < 4; i++) p.putFloat(i * 4, still != null ? still[i] : 0f);
        for (int i = 0; i < 4; i++) p.putFloat(16 + i * 4, flow != null ? flow[i] : 0f);
        // state: x copies valid (0/1), y surfaceAbove (underwater), z wetness, w baked waves ready
        p.putFloat(32, copyValid ? 1f : 0f).putFloat(36, surfaceAbove).putFloat(40, wetness).putFloat(44, wavesReady ? 1f : 0f);
        // tune: x wave strength, y SSR max dist (blocks), z reflection strength, w caustics
        p.putFloat(48, 1f).putFloat(52, 512f).putFloat(56, 1f).putFloat(60, 1f);
        // swell: x strength, y masking k, z crest glow, w Fresnel share
        p.putFloat(64, 1.3f).putFloat(68, 0.45f).putFloat(72, 0.5f).putFloat(76, 1f);
        // swell2: x openFar (< 0 = full swell everywhere), y mirrorCalm, z long calm, w detail ripple scale
        p.putFloat(80, -1f).putFloat(84, 0.75f).putFloat(88, 0.55f).putFloat(92, 2.0f);
        // swell3: x swellRefl, y glitter, z glintSharp, w reflTemporal
        p.putFloat(96, 0.45f).putFloat(100, 1.5f).putFloat(104, 0.3f).putFloat(108, 0f);
        // rhist: inactive
        p.putFloat(112, 0f).putFloat(116, 0f).putFloat(120, 0f).putFloat(124, 0f);
        // mirror: x mirrorAA, y reflFilter, z reflPano, w causticGain
        p.putFloat(128, 0f).putFloat(132, 1f).putFloat(136, 0f).putFloat(140, 2.5f);
        // far: x dist, y band, z dev, w baked swell ready
        p.putFloat(144, 0f).putFloat(148, 0f).putFloat(152, 0f).putFloat(156, swellReady ? 1f : 0f);
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
        initialized = false;
    }
}
