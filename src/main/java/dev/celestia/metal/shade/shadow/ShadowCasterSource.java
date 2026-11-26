package dev.celestia.metal.shade.shadow;

import com.mojang.renderpearl.api.pipeline.CompareOp;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import java.lang.foreign.MemorySegment;

/**
 * Backend abstraction supplying terrain shadow casters into a depth-only cascade pass.
 * Implementations exist for both Sodium 0.9.x ({@link SodiumShadowCasters}, isolated and never
 * class-loaded unless Sodium is present) and vanilla Minecraft 26.3 sections ({@link VanillaShadowCasters}).
 */
public interface ShadowCasterSource {
    static long createDepthPso(long ctx, long vsFn, long fsFn, int depthFmt, String label, StringBuilder err) {
        return MetalNative.renderPipelineCreate(ctx, vsFn, fsFn,
            MemorySegment.NULL, 0, MemorySegment.NULL, 0,
            MemorySegment.NULL, 0, depthFmt, MetalConst.TOPO_TRIANGLES,
            0, false, true, MetalConst.toNativeCompare(CompareOp.GREATER_THAN_OR_EQUAL),
            true, 0f, 0f, label, err);
    }

    String name();

    /**
     * Renders one cascade into slice {@code layer} of {@code shadowTex}.
     *
     * @return number of quads submitted, or {@code < 0} if this caster source encountered an unrecoverable error
     */
    int renderCascade(long ctx, long shadowTex, int layer, int resolution,
                      ShadowCascade cascade, float[] viewProj, float depthBias,
                      double camX, double camY, double camZ, double[] lightDir,
                      boolean farCascade, long atlasTex, long atlasSamp,
                      float slopeScale, float clamp, boolean loadExisting);

    void close(long ctx);
}
