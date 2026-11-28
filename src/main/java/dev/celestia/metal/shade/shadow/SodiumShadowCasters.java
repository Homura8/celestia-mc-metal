// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/shadow/ShadowCasters.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.shadow;

import com.mojang.logging.LogUtils;
import dev.celestia.metal.backend.CelestiaBuffer;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.Map;
import org.slf4j.Logger;

/**
 * Optional Sodium 0.9.x terrain shadow caster collector. Reads Sodium's section geometry arenas and
 * per-facing vertex ranges strictly via cached reflection {@link MethodHandle}s so Celestia Metal has zero
 * hard link-time dependency on Sodium.
 */
public final class SodiumShadowCasters implements ShadowCasterSource {
    private static final Logger LOGGER = LogUtils.getLogger();

    private static final int CHUNK_QUADS = 32;
    public static final int RING_SLOTS = 16;
    private static final int DRAW_STRIDE = 24;
    private static final int CHUNK_STRIDE = 8;
    private static final int REGION_STRIDE = 16;
    private static final int FACING_UNASSIGNED = 6;
    private static final int SECTION_COUNT = 256;
    private static final int FACING_COUNT = 7;

    // Reflected Sodium handles (all return Objects/primitives from Sodium 0.9.x runtime types)
    private final MethodHandle mhInstanceNullable;
    private final MethodHandle mhGetRenderSectionManager;
    private final MethodHandle mhGetRegions;
    private final MethodHandle mhGetLoadedRegions;
    private final MethodHandle mhGetOriginX;
    private final MethodHandle mhGetOriginY;
    private final MethodHandle mhGetOriginZ;
    private final MethodHandle mhGetResources;
    private final MethodHandle mhGetGeometryBuffer;
    private final MethodHandle mhGetStorage;
    private final MethodHandle mhGetDataPointer;
    private final MethodHandle mhGetSliceMask;
    private final MethodHandle mhGetBaseVertex;
    private final MethodHandle mhGetFacingList;
    private final MethodHandle mhGetVertexCount;
    private final Object passSolid;
    private final Object passCutout;

    private final long lib;
    private final long vsSolidFn, vsCutoutFn, fsCutoutFn;
    private final long psoSolid, psoCutout;

    private final long[] chunkBufs = new long[RING_SLOTS];
    private final MemorySegment[] chunkSegs = new MemorySegment[RING_SLOTS];
    private final long[] chunkCaps = new long[RING_SLOTS];
    private final long[] regionBufs = new long[RING_SLOTS];
    private final MemorySegment[] regionSegs = new MemorySegment[RING_SLOTS];
    private final long[] regionCaps = new long[RING_SLOTS];
    private int ringCursor;

    private final MemorySegment cascadeSeg = Arena.global().allocate(80, 16);
    private MemorySegment drawsSeg = Arena.global().allocate(256L * DRAW_STRIDE, 8);
    private int drawsCap = 256;

    // Reusable per-(kind, arena) chunk arrays to avoid GC churn
    private final Map<Long, ChunkRun> solidRuns = new LinkedHashMap<>();
    private final Map<Long, ChunkRun> cutoutRuns = new LinkedHashMap<>();

    private static final class ChunkRun {
        final long arenaPtr;
        int[] data = new int[512]; // { firstVertex, packed } pairs
        int count;

        ChunkRun(long arenaPtr) {
            this.arenaPtr = arenaPtr;
        }

        void add(int firstVertex, int packed) {
            int pos = count * 2;
            if (pos + 2 > data.length) {
                data = java.util.Arrays.copyOf(data, data.length * 2);
            }
            data[pos] = firstVertex;
            data[pos + 1] = packed;
            count++;
        }
    }

    public SodiumShadowCasters(long ctx, int depthFmt) {
        try {
            MethodHandles.Lookup l = MethodHandles.lookup();
            Class<?> cWorld = Class.forName("net.caffeinemc.mods.sodium.client.render.SodiumWorldRenderer");
            Class<?> cMgr = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.RenderSectionManager");
            Class<?> cRegMgr = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.region.RenderRegionManager");
            Class<?> cReg = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.region.RenderRegion");
            Class<?> cRes = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.region.RenderRegion$DeviceResources");
            Class<?> cStore = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.data.SectionRenderDataStorage");
            Class<?> cUnsafe = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.data.SectionRenderDataUnsafe");
            Class<?> cPasses = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.terrain.DefaultTerrainRenderPasses");
            Class<?> cPass = Class.forName("net.caffeinemc.mods.sodium.client.render.chunk.terrain.TerrainRenderPass");

            mhInstanceNullable = unreflectMethod(l, cWorld, "instanceNullable");
            mhGetRenderSectionManager = unreflectField(l, cWorld, "renderSectionManager");
            mhGetRegions = unreflectField(l, cMgr, "regions");
            mhGetLoadedRegions = unreflectMethod(l, cRegMgr, "getLoadedRegions");
            mhGetOriginX = unreflectMethod(l, cReg, "getOriginX");
            mhGetOriginY = unreflectMethod(l, cReg, "getOriginY");
            mhGetOriginZ = unreflectMethod(l, cReg, "getOriginZ");
            mhGetResources = unreflectMethod(l, cReg, "getResources");
            mhGetGeometryBuffer = unreflectMethod(l, cRes, "getGeometryBuffer");
            mhGetStorage = unreflectMethod(l, cReg, "getStorage", cPass);
            mhGetDataPointer = unreflectMethod(l, cStore, "getDataPointer", int.class);
            mhGetSliceMask = unreflectMethod(l, cUnsafe, "getSliceMask", long.class);
            mhGetBaseVertex = unreflectMethod(l, cUnsafe, "getBaseVertex", long.class);
            mhGetFacingList = unreflectMethod(l, cUnsafe, "getFacingList", long.class);
            mhGetVertexCount = unreflectMethod(l, cUnsafe, "getVertexCount", long.class, int.class);
            passSolid = cPasses.getField("SOLID").get(null);
            passCutout = cPasses.getField("CUTOUT").get(null);
        } catch (Throwable t) {
            throw new IllegalStateException("Sodium 0.9.x reflection binding failed", t);
        }

        StringBuilder err = new StringBuilder();
        lib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.shadowSodiumSource(), "CelestiaShadow.Sodium", true, err);
        if (lib == 0L) throw new IllegalStateException("shadow_sodium.metal compile failed: " + err);
        vsSolidFn = MetalNative.compileFunction(lib, "shadow_vs", false, 0, 0, err);
        vsCutoutFn = MetalNative.compileFunction(lib, "shadow_cutout_vs", false, 0, 0, err);
        fsCutoutFn = MetalNative.compileFunction(lib, "shadow_cutout_fs", false, 0, 0, err);
        if (vsSolidFn == 0L || vsCutoutFn == 0L || fsCutoutFn == 0L) {
            close(ctx);
            throw new IllegalStateException("shadow_sodium.metal entry points missing: " + err);
        }
        psoSolid = ShadowCasterSource.createDepthPso(ctx, vsSolidFn, 0L, depthFmt, "CelestiaShadow.SodiumSolid", err);
        psoCutout = ShadowCasterSource.createDepthPso(ctx, vsCutoutFn, fsCutoutFn, depthFmt, "CelestiaShadow.SodiumCutout", err);
        if (psoSolid == 0L || psoCutout == 0L) {
            close(ctx);
            throw new IllegalStateException("Sodium shadow pipeline creation failed: " + err);
        }
    }

    private static MethodHandle unreflectMethod(MethodHandles.Lookup l, Class<?> owner, String name, Class<?>... params)
        throws Exception {
        Method m = owner.getDeclaredMethod(name, params);
        m.setAccessible(true);
        return l.unreflect(m);
    }

    private static MethodHandle unreflectField(MethodHandles.Lookup l, Class<?> owner, String name) throws Exception {
        Field f = owner.getDeclaredField(name);
        f.setAccessible(true);
        return l.unreflectGetter(f);
    }

    @Override
    public String name() {
        return "Sodium";
    }

    @Override
    public int renderCascade(long ctx, long shadowTex, int layer, int resolution,
                             ShadowCascade cascade, float[] viewProj, float depthBias,
                             double camX, double camY, double camZ, double[] lightDir,
                             boolean farCascade, long atlasTex, long atlasSamp,
                             float slopeScale, float clamp, boolean loadExisting) {
        try {
            Object worldRenderer = mhInstanceNullable.invoke();
            if (worldRenderer == null) {
                packCascade(viewProj, depthBias);
                MetalNative.shadowRenderSodium(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                    cascadeSeg, 80, 0L, 0L, 0L, 0L, MemorySegment.NULL, 0, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
                return 0;
            }
            Object sectionMgr = mhGetRenderSectionManager.invoke(worldRenderer);
            if (sectionMgr == null) return 0;
            Object regionMgr = mhGetRegions.invoke(sectionMgr);
            @SuppressWarnings("unchecked")
            Collection<Object> regions = (Collection<Object>) mhGetLoadedRegions.invoke(regionMgr);
            if (regions == null || regions.isEmpty()) {
                packCascade(viewProj, depthBias);
                MetalNative.shadowRenderSodium(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                    cascadeSeg, 80, 0L, 0L, 0L, 0L, MemorySegment.NULL, 0, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
                return 0;
            }

            solidRuns.clear();
            cutoutRuns.clear();
            int faceMask = faceMask(lightDir);
            int slot = (ringCursor++) & (RING_SLOTS - 1);
            ensureRegionCap(ctx, slot, regions.size());
            MemorySegment rSeg = regionSegs[slot];
            int regionSlotCount = 0;
            int totalChunks = 0;
            int totalQuads = 0;

            for (Object region : regions) {
                Object res = mhGetResources.invoke(region);
                if (res == null) continue;
                Object geo = mhGetGeometryBuffer.invoke(res);
                if (!(geo instanceof CelestiaBuffer cb) || cb.isClosed() || cb.handle() == 0L) continue;
                long arenaPtr = cb.handle();

                int ox = (int) mhGetOriginX.invoke(region);
                int oy = (int) mhGetOriginY.invoke(region);
                int oz = (int) mhGetOriginZ.invoke(region);
                if (!cascade.casts(ox, oy, oz, ox + 128.0, oy + 64.0, oz + 128.0)) continue;

                int regId = -1;
                Object solidStorage = mhGetStorage.invoke(region, passSolid);
                if (solidStorage != null) {
                    regId = ensureRegionRecorded(rSeg, regId, regionSlotCount, ox, oy, oz, camX, camY, camZ);
                    if (regId == regionSlotCount) regionSlotCount++;
                    ChunkRun run = solidRuns.computeIfAbsent(arenaPtr, ChunkRun::new);
                    long added = collectStorage(solidStorage, cascade, ox, oy, oz, faceMask, regId, false, run);
                    totalChunks += (int) (added >>> 32);
                    totalQuads += (int) added;
                }

                Object cutoutStorage = mhGetStorage.invoke(region, passCutout);
                if (cutoutStorage != null) {
                    regId = ensureRegionRecorded(rSeg, regId, regionSlotCount, ox, oy, oz, camX, camY, camZ);
                    if (regId == regionSlotCount) regionSlotCount++;
                    if (farCascade) {
                        // In the far cascade, axis-aligned cutout geometry can be depth-only without alpha test,
                        // and unassigned grass/flowers are skipped cleanly.
                        ChunkRun solidRun = solidRuns.computeIfAbsent(arenaPtr, ChunkRun::new);
                        long added = collectStorage(cutoutStorage, cascade, ox, oy, oz,
                            faceMask & ~(1 << FACING_UNASSIGNED), regId, true, solidRun);
                        totalChunks += (int) (added >>> 32);
                        totalQuads += (int) added;
                    } else {
                        ChunkRun cutRun = cutoutRuns.computeIfAbsent(arenaPtr, ChunkRun::new);
                        long added = collectStorage(cutoutStorage, cascade, ox, oy, oz, faceMask, regId, false, cutRun);
                        totalChunks += (int) (added >>> 32);
                        totalQuads += (int) added;
                    }
                }
            }

            packCascade(viewProj, depthBias);
            if (totalChunks == 0) {
                MetalNative.shadowRenderSodium(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                    cascadeSeg, 80, 0L, 0L, 0L, 0L, MemorySegment.NULL, 0, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
                return 0;
            }

            ensureChunkCap(ctx, slot, totalChunks);
            MemorySegment cSeg = chunkSegs[slot];
            int runCount = 0;
            for (ChunkRun r : solidRuns.values()) if (r.count > 0) runCount++;
            for (ChunkRun r : cutoutRuns.values()) if (r.count > 0) runCount++;
            ensureDrawCap(runCount);

            int chunkCursor = 0;
            int drawIdx = 0;
            chunkCursor = packRuns(solidRuns, 0, cSeg, chunkCursor, drawIdx);
            for (ChunkRun r : solidRuns.values()) if (r.count > 0) drawIdx++;
            chunkCursor = packRuns(cutoutRuns, 1, cSeg, chunkCursor, drawIdx);
            for (ChunkRun r : cutoutRuns.values()) if (r.count > 0) drawIdx++;

            MetalNative.shadowRenderSodium(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                cascadeSeg, 80,
                chunkBufs[slot], 0L,
                regionBufs[slot], 0L,
                drawsSeg, drawIdx,
                atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
            return totalQuads;
        } catch (Throwable t) {
            LOGGER.warn("Sodium shadow collection failed; falling back to vanilla terrain casters", t);
            return -1;
        }
    }

    private long collectStorage(Object storage, ShadowCascade cascade, int ox, int oy, int oz,
                                int faceMask, int regionId, boolean onlyAligned,
                                ChunkRun targetRun) throws Throwable {
        int chunksAdded = 0;
        int quadsAdded = 0;
        int regPacked = regionId << 6;
        for (int sec = 0; sec < SECTION_COUNT; sec++) {
            long ptr = (long) mhGetDataPointer.invoke(storage, sec);
            if (ptr == 0L) continue;
            int mask = (int) mhGetSliceMask.invoke(ptr);
            if ((mask & faceMask) == 0) continue;

            int sx = ox + ((sec >> 5) & 7) * 16;
            int sy = oy + (sec & 3) * 16;
            int sz = oz + ((sec >> 2) & 7) * 16;
            if (!cascade.casts(sx, sy, sz, sx + 16.0, sy + 16.0, sz + 16.0)) continue;

            long facingList = (long) mhGetFacingList.invoke(ptr);
            long baseVertex = (long) mhGetBaseVertex.invoke(ptr);
            for (int i = 0; i < FACING_COUNT; i++) {
                long vCount = (long) mhGetVertexCount.invoke(ptr, i);
                if (vCount <= 0L) continue;
                int facing = (int) ((facingList >>> (i * 8)) & 0xFFL);
                boolean keep = (faceMask & (1 << facing)) != 0;
                if (onlyAligned && facing == FACING_UNASSIGNED) keep = false;
                if (keep) {
                    int quads = (int) (vCount >>> 2);
                    int vOff = (int) baseVertex;
                    while (quads > 0) {
                        int q = Math.min(quads, CHUNK_QUADS);
                        targetRun.add(vOff, ((q - 1) & 63) | regPacked);
                        chunksAdded++;
                        quadsAdded += q;
                        vOff += q * 4;
                        quads -= q;
                    }
                }
                baseVertex += vCount;
            }
        }
        return ((long) chunksAdded << 32) | (quadsAdded & 0xFFFFFFFFL);
    }

    private static int ensureRegionRecorded(MemorySegment rSeg, int regId, int nextId,
                                            int ox, int oy, int oz, double camX, double camY, double camZ) {
        if (regId >= 0) return regId;
        long off = (long) nextId * REGION_STRIDE;
        rSeg.set(ValueLayout.JAVA_FLOAT, off, (float) (ox - camX));
        rSeg.set(ValueLayout.JAVA_FLOAT, off + 4, (float) (oy - camY));
        rSeg.set(ValueLayout.JAVA_FLOAT, off + 8, (float) (oz - camZ));
        rSeg.set(ValueLayout.JAVA_FLOAT, off + 12, 0f);
        return nextId;
    }

    private int packRuns(Map<Long, ChunkRun> runs, int kind, MemorySegment cSeg, int chunkCursor, int drawStart) {
        int di = drawStart;
        for (ChunkRun run : runs.values()) {
            if (run.count <= 0) continue;
            for (int i = 0; i < run.count; i++) {
                long off = (long) (chunkCursor + i) * CHUNK_STRIDE;
                cSeg.set(ValueLayout.JAVA_INT, off, run.data[i * 2]);
                cSeg.set(ValueLayout.JAVA_INT, off + 4, run.data[i * 2 + 1]);
            }
            long doff = (long) di * DRAW_STRIDE;
            drawsSeg.set(ValueLayout.JAVA_LONG, doff, run.arenaPtr);
            drawsSeg.set(ValueLayout.JAVA_INT, doff + 8, chunkCursor);
            drawsSeg.set(ValueLayout.JAVA_INT, doff + 12, run.count);
            drawsSeg.set(ValueLayout.JAVA_INT, doff + 16, kind);
            drawsSeg.set(ValueLayout.JAVA_INT, doff + 20, 0);
            chunkCursor += run.count;
            di++;
        }
        return chunkCursor;
    }

    private void packCascade(float[] viewProj, float depthBias) {
        ByteBuffer bb = cascadeSeg.asByteBuffer().order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < 16; i++) bb.putFloat(i * 4, viewProj[i]);
        bb.putFloat(64, depthBias).putFloat(68, 0f).putFloat(72, 0f).putFloat(76, 0f);
    }

    private void ensureRegionCap(long ctx, int slot, int regions) {
        long needed = (long) Math.max(16, regions) * REGION_STRIDE;
        if (regionBufs[slot] != 0L && regionCaps[slot] >= needed) return;
        if (regionBufs[slot] != 0L) MetalNative.bufferDestroy(ctx, regionBufs[slot]);
        long cap = Math.max(needed, Math.max(64L * REGION_STRIDE, regionCaps[slot] * 2L));
        regionBufs[slot] = MetalNative.bufferCreate(ctx, cap, null, "CelestiaShadow.Regions" + slot);
        regionSegs[slot] = MemorySegment.ofAddress(MetalNative.bufferContents(regionBufs[slot])).reinterpret(cap);
        regionCaps[slot] = cap;
    }

    private void ensureChunkCap(long ctx, int slot, int chunks) {
        long needed = (long) Math.max(64, chunks) * CHUNK_STRIDE;
        if (chunkBufs[slot] != 0L && chunkCaps[slot] >= needed) return;
        if (chunkBufs[slot] != 0L) MetalNative.bufferDestroy(ctx, chunkBufs[slot]);
        long cap = Math.max(needed, Math.max(4096L * CHUNK_STRIDE, chunkCaps[slot] * 2L));
        chunkBufs[slot] = MetalNative.bufferCreate(ctx, cap, null, "CelestiaShadow.Chunks" + slot);
        chunkSegs[slot] = MemorySegment.ofAddress(MetalNative.bufferContents(chunkBufs[slot])).reinterpret(cap);
        chunkCaps[slot] = cap;
    }

    private void ensureDrawCap(int runs) {
        if (drawsCap >= runs) return;
        drawsCap = Math.max(runs, drawsCap * 2);
        drawsSeg = Arena.global().allocate((long) drawsCap * DRAW_STRIDE, 8);
    }

    static int faceMask(double[] l) {
        final double eps = 1e-4;
        int mask = 1 << FACING_UNASSIGNED;
        if (l[0] > eps) mask |= 1;
        if (l[1] > eps) mask |= 1 << 1;
        if (l[2] > eps) mask |= 1 << 2;
        if (l[0] < -eps) mask |= 1 << 3;
        if (l[1] < -eps) mask |= 1 << 4;
        if (l[2] < -eps) mask |= 1 << 5;
        return mask;
    }

    @Override
    public void close(long ctx) {
        for (int i = 0; i < RING_SLOTS; i++) {
            if (ctx != 0L && chunkBufs[i] != 0L) MetalNative.bufferDestroy(ctx, chunkBufs[i]);
            if (ctx != 0L && regionBufs[i] != 0L) MetalNative.bufferDestroy(ctx, regionBufs[i]);
            chunkBufs[i] = 0L;
            regionBufs[i] = 0L;
        }
        if (ctx != 0L) {
            if (psoSolid != 0L) MetalNative.pipelineDestroy(ctx, psoSolid);
            if (psoCutout != 0L) MetalNative.pipelineDestroy(ctx, psoCutout);
        }
        if (vsSolidFn != 0L) MetalNative.functionDestroy(vsSolidFn);
        if (vsCutoutFn != 0L) MetalNative.functionDestroy(vsCutoutFn);
        if (fsCutoutFn != 0L) MetalNative.functionDestroy(fsCutoutFn);
        if (lib != 0L) MetalNative.libraryDestroy(lib);
    }
}
