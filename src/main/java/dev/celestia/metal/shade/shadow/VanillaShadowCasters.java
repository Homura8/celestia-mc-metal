package dev.celestia.metal.shade.shadow;

import dev.celestia.metal.backend.CelestiaBuffer;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.mixin.ViewAreaAccessor;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import net.minecraft.client.Minecraft;
import net.minecraft.client.RotatingSectionStorage;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.ViewArea;
import net.minecraft.client.renderer.chunk.ChunkSectionLayer;
import net.minecraft.client.renderer.chunk.SectionMesh;
import net.minecraft.client.renderer.chunk.SectionRenderDispatcher;
import net.minecraft.core.BlockPos;

/**
 * Vanilla Minecraft 26.3 terrain shadow caster collector reading {@link ViewArea} and
 * {@link SectionRenderDispatcher} uber-buffer allocations without requiring Sodium.
 */
public final class VanillaShadowCasters implements ShadowCasterSource {
    private static final int DRAW_STRIDE = 40; // CMShadowVanillaDraw

    private final long lib;
    private final long vsSolidFn, vsCutoutFn, fsCutoutFn;
    private final long psoSolid, psoCutout;

    private final MemorySegment cascadeSeg = Arena.global().allocate(80, 16);
    private MemorySegment solidDrawsSeg = Arena.global().allocate(1024L * DRAW_STRIDE, 8);
    private MemorySegment cutoutDrawsSeg = Arena.global().allocate(512L * DRAW_STRIDE, 8);
    private int solidCap = 1024;
    private int cutoutCap = 512;

    public VanillaShadowCasters(long ctx, int depthFmt) {
        StringBuilder err = new StringBuilder();
        lib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.shadowVanillaSource(), "CelestiaShadow.Vanilla", true, err);
        if (lib == 0L) throw new IllegalStateException("shadow_vanilla.metal compile failed: " + err);
        vsSolidFn = MetalNative.compileFunction(lib, "shadow_vanilla_vs", false, 0, 0, err);
        vsCutoutFn = MetalNative.compileFunction(lib, "shadow_vanilla_cutout_vs", false, 0, 0, err);
        fsCutoutFn = MetalNative.compileFunction(lib, "shadow_vanilla_cutout_fs", false, 0, 0, err);
        if (vsSolidFn == 0L || vsCutoutFn == 0L || fsCutoutFn == 0L) {
            close(ctx);
            throw new IllegalStateException("shadow_vanilla.metal entry points missing: " + err);
        }
        psoSolid = ShadowCasterSource.createDepthPso(ctx, vsSolidFn, 0L, depthFmt, "CelestiaShadow.VanillaSolid", err);
        psoCutout = ShadowCasterSource.createDepthPso(ctx, vsCutoutFn, fsCutoutFn, depthFmt, "CelestiaShadow.VanillaCutout", err);
        if (psoSolid == 0L || psoCutout == 0L) {
            close(ctx);
            throw new IllegalStateException("Vanilla shadow pipeline creation failed: " + err);
        }
    }

    @Override
    public String name() {
        return "Vanilla";
    }

    @Override
    public int renderCascade(long ctx, long shadowTex, int layer, int resolution,
                             ShadowCascade cascade, float[] viewProj, float depthBias,
                             double camX, double camY, double camZ, double[] lightDir,
                             boolean farCascade, long atlasTex, long atlasSamp,
                             float slopeScale, float clamp, boolean loadExisting) {
        packCascade(viewProj, depthBias);
        Minecraft mc = Minecraft.getInstance();
        LevelRenderer lr = mc != null ? mc.levelRenderer : null;
        ViewArea viewArea = lr != null ? lr.viewArea() : null;
        SectionRenderDispatcher dispatcher = lr != null ? lr.sectionRenderDispatcher() : null;
        if (viewArea == null || dispatcher == null) {
            MetalNative.shadowRenderVanilla(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                cascadeSeg, 80, MemorySegment.NULL, 0, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
            return 0;
        }

        RotatingSectionStorage<SectionRenderDispatcher.RenderSection> sections =
            ((ViewAreaAccessor) viewArea).celestiametal$sections();
        int solidCount = 0;
        int cutoutCount = 0;
        int totalQuads = 0;

        for (SectionRenderDispatcher.RenderSection section : sections) {
            if (section == null) continue;
            BlockPos origin = section.getRenderOrigin();
            int ox = origin.getX(), oy = origin.getY(), oz = origin.getZ();
            if (!cascade.casts(ox, oy, oz, ox + 16.0, oy + 16.0, oz + 16.0)) continue;

            SectionMesh mesh = section.getSectionMesh();
            if (mesh == null || !mesh.hasRenderableLayers()) continue;

            float rx = (float) (ox - camX);
            float ry = (float) (oy - camY);
            float rz = (float) (oz - camZ);

            SectionMesh.SectionDraw solidDraw = mesh.getSectionDraw(ChunkSectionLayer.SOLID);
            if (solidDraw != null && solidDraw.indexCount() >= 6 && !solidDraw.hasCustomIndexBuffer()) {
                SectionRenderDispatcher.RenderSectionBufferSlice slice =
                    dispatcher.getRenderSectionSlice(mesh, ChunkSectionLayer.SOLID);
                if (slice != null && slice.vertexBuffer() instanceof CelestiaBuffer cb && !cb.isClosed() && cb.handle() != 0L) {
                    int quads = solidDraw.indexCount() / 6;
                    ensureSolidCap(solidCount + 1);
                    writeDraw(solidDrawsSeg, solidCount++, cb.handle(), slice.vertexBufferOffset(), quads, 0, rx, ry, rz);
                    totalQuads += quads;
                }
            }

            SectionMesh.SectionDraw cutDraw = mesh.getSectionDraw(ChunkSectionLayer.CUTOUT);
            if (cutDraw != null && cutDraw.indexCount() >= 6 && !cutDraw.hasCustomIndexBuffer()) {
                SectionRenderDispatcher.RenderSectionBufferSlice slice =
                    dispatcher.getRenderSectionSlice(mesh, ChunkSectionLayer.CUTOUT);
                if (slice != null && slice.vertexBuffer() instanceof CelestiaBuffer cb && !cb.isClosed() && cb.handle() != 0L) {
                    int quads = cutDraw.indexCount() / 6;
                    if (farCascade) {
                        ensureSolidCap(solidCount + 1);
                        writeDraw(solidDrawsSeg, solidCount++, cb.handle(), slice.vertexBufferOffset(), quads, 0, rx, ry, rz);
                    } else {
                        ensureCutoutCap(cutoutCount + 1);
                        writeDraw(cutoutDrawsSeg, cutoutCount++, cb.handle(), slice.vertexBufferOffset(), quads, 1, rx, ry, rz);
                    }
                    totalQuads += quads;
                }
            }
        }

        int totalDraws = solidCount + cutoutCount;
        if (totalDraws == 0) {
            MetalNative.shadowRenderVanilla(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
                cascadeSeg, 80, MemorySegment.NULL, 0, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
            return 0;
        }

        ensureSolidCap(totalDraws);
        if (cutoutCount > 0) {
            MemorySegment.copy(cutoutDrawsSeg, 0L, solidDrawsSeg, (long) solidCount * DRAW_STRIDE, (long) cutoutCount * DRAW_STRIDE);
        }
        MetalNative.shadowRenderVanilla(ctx, shadowTex, layer, resolution, psoSolid, psoCutout,
            cascadeSeg, 80, solidDrawsSeg, totalDraws, atlasTex, atlasSamp, slopeScale, clamp, loadExisting);
        return totalQuads;
    }

    private static void writeDraw(MemorySegment seg, int idx, long vtxBuf, long vtxByteOff, int quads, int kind,
                                  float rx, float ry, float rz) {
        long off = (long) idx * DRAW_STRIDE;
        seg.set(ValueLayout.JAVA_LONG, off, vtxBuf);
        seg.set(ValueLayout.JAVA_LONG, off + 8, vtxByteOff);
        seg.set(ValueLayout.JAVA_INT, off + 16, quads);
        seg.set(ValueLayout.JAVA_INT, off + 20, kind);
        seg.set(ValueLayout.JAVA_FLOAT, off + 24, rx);
        seg.set(ValueLayout.JAVA_FLOAT, off + 28, ry);
        seg.set(ValueLayout.JAVA_FLOAT, off + 32, rz);
        seg.set(ValueLayout.JAVA_FLOAT, off + 36, 0f);
    }

    private void packCascade(float[] viewProj, float depthBias) {
        ByteBuffer bb = cascadeSeg.asByteBuffer().order(ByteOrder.LITTLE_ENDIAN);
        for (int i = 0; i < 16; i++) bb.putFloat(i * 4, viewProj[i]);
        bb.putFloat(64, depthBias).putFloat(68, 0f).putFloat(72, 0f).putFloat(76, 0f);
    }

    private void ensureSolidCap(int count) {
        if (solidCap >= count) return;
        int next = Math.max(count, solidCap * 2);
        MemorySegment ns = Arena.global().allocate((long) next * DRAW_STRIDE, 8);
        MemorySegment.copy(solidDrawsSeg, 0L, ns, 0L, (long) solidCap * DRAW_STRIDE);
        solidDrawsSeg = ns;
        solidCap = next;
    }

    private void ensureCutoutCap(int count) {
        if (cutoutCap >= count) return;
        int next = Math.max(count, cutoutCap * 2);
        MemorySegment ns = Arena.global().allocate((long) next * DRAW_STRIDE, 8);
        MemorySegment.copy(cutoutDrawsSeg, 0L, ns, 0L, (long) cutoutCap * DRAW_STRIDE);
        cutoutDrawsSeg = ns;
        cutoutCap = next;
    }

    @Override
    public void close(long ctx) {
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
