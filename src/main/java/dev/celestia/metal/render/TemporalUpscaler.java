package dev.celestia.metal.render;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.logging.LogUtils;
import dev.celestia.metal.backend.CelestiaTexture;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import org.joml.Matrix4f;
import org.slf4j.Logger;

/** Jitters only the world projection and resolves before the 2D GUI is drawn. */
public final class TemporalUpscaler implements AutoCloseable {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final int PARAM_BYTES = 208;
    private static final int JITTER_PHASES = 16;
    private final long ctx;
    private final Arena scratch = Arena.ofShared();
    private final MemorySegment params = scratch.allocate(PARAM_BYTES, 16);
    private final ByteBuffer bytes = params.asByteBuffer().order(ByteOrder.nativeOrder());
    private final MemorySegment inputs = scratch.allocate(4 * 8L, 8);
    private final Matrix4f current = new Matrix4f();
    private final Matrix4f inverse = new Matrix4f();
    private final Matrix4f previous = new Matrix4f();
    private final Matrix4f reproject = new Matrix4f();
    private final long[] history = new long[2];

    private long resolvePso, outputRgba, outputBgra;
    private long worldDepth;
    private CelestiaTexture handDepth;
    private int inputW, inputH, outputW, outputH, historyIndex, phase;
    private double x, y, z, lastX, lastY, lastZ;
    private float jitterX, jitterY;
    private long lastResolve;
    private ClientLevel lastLevel;
    private boolean enabled, failed, projectionReady, depthReady;
    private boolean historyValid;

    public TemporalUpscaler(long ctx) {
        this.ctx = ctx;
    }

    public void begin(RenderTarget world, RenderTarget output, ClientLevel level) {
        projectionReady = depthReady = false;
        handDepth = null;
        enabled = level != null && world.getDepthTexture() instanceof CelestiaTexture depth
            && MetalConst.toNativeFormat(depth.getFormat()) == MetalConst.FMT_D32_FLOAT
            && output.getColorTexture() instanceof CelestiaTexture destination
            && supportedOutput(MetalConst.toNativeFormat(destination.getFormat()))
            && initialize() && ensureTargets(world.width, world.height, output.width, output.height);
        if (level != lastLevel || System.nanoTime() - lastResolve > 500_000_000L || !enabled) historyValid = false;
        lastLevel = level;
    }

    public void disable() {
        enabled = historyValid = false;
        lastLevel = null;
        handDepth = null;
    }

    public boolean jitter(Matrix4f projection, CameraRenderState camera) {
        if (!enabled || camera.isPanoramicMode) return false;
        x = camera.pos.x;
        y = camera.pos.y;
        z = camera.pos.z;
        double dx = x - lastX, dy = y - lastY, dz = z - lastZ;
        if (dx * dx + dy * dy + dz * dz > 64.0) historyValid = false;
        phase = historyValid ? (phase + 1) % JITTER_PHASES : 0;
        jitterX = (halton(phase + 1, 2) - 0.5f) / inputW;
        jitterY = (halton(phase + 1, 3) - 0.5f) / inputH;
        current.set(projection).mul(camera.viewRotationMatrix);
        reproject.set(previous).translate((float) dx, (float) dy, (float) dz);
        projection.translateLocal(2f * jitterX, 2f * jitterY, 0f);
        inverse.set(projection).mul(camera.viewRotationMatrix).invert();
        projectionReady = true;
        return true;
    }

    public float jitterNdcX() { return 2f * jitterX; }
    public float jitterNdcY() { return 2f * jitterY; }

    public void captureDepth(RenderTarget world, RenderTarget hand) {
        if (!enabled || !projectionReady || hand == null || !(world.getDepthTexture() instanceof CelestiaTexture depth)
            || !(hand.getDepthTexture() instanceof CelestiaTexture handTarget)) return;
        MetalNative.blitCopyTextureFull(ctx, depth.handle(), worldDepth);
        handDepth = handTarget;
        depthReady = true;
    }

    public boolean resolve(CelestiaTexture src, CelestiaTexture dst) {
        if (!enabled || !depthReady) {
            historyValid = false;
            return false;
        }
        int write = 1 - historyIndex;
        inverse.get(0, bytes);
        reproject.get(64, bytes);
        previous.get(128, bytes);
        bytes.putFloat(192, jitterX).putFloat(196, jitterY)
            .putFloat(200, historyValid ? 1f : 0f);
        inputs.setAtIndex(ValueLayout.JAVA_LONG, 0, src.handle());
        inputs.setAtIndex(ValueLayout.JAVA_LONG, 1, worldDepth);
        inputs.setAtIndex(ValueLayout.JAVA_LONG, 2, history[historyIndex]);
        inputs.setAtIndex(ValueLayout.JAVA_LONG, 3, handDepth.handle());
        MetalNative.shadeFullscreenPass(ctx, resolvePso, history[write], inputs, 4,
            MemorySegment.NULL, 0, params, PARAM_BYTES);
        inputs.setAtIndex(ValueLayout.JAVA_LONG, 0, history[write]);
        long output = MetalConst.toNativeFormat(dst.getFormat()) == MetalConst.FMT_BGRA8_UNORM ? outputBgra : outputRgba;
        MetalNative.shadeFullscreenPass(ctx, output, dst.handle(), inputs, 1,
            MemorySegment.NULL, 0, MemorySegment.NULL, 0);

        previous.set(current);
        lastX = x;
        lastY = y;
        lastZ = z;
        lastResolve = System.nanoTime();
        historyIndex = write;
        historyValid = true;
        return true;
    }

    private static boolean supportedOutput(int format) {
        return format == MetalConst.FMT_RGBA8_UNORM || format == MetalConst.FMT_BGRA8_UNORM;
    }

    private boolean initialize() {
        if (failed) return false;
        if (resolvePso != 0L) return true;
        StringBuilder error = new StringBuilder();
        long library = 0L, vertex = 0L, resolve = 0L, output = 0L;
        try {
            library = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.resource("taa.metal"), "Celestia TAAU", false, error);
            if (library == 0L) throw new IllegalStateException(error.toString());
            vertex = MetalNative.compileFunction(library, "taa_vs", false, 0, 0, error);
            resolve = MetalNative.compileFunction(library, "taa_resolve", false, 0, 0, error);
            output = MetalNative.compileFunction(library, "taa_output", false, 0, 0, error);
            resolvePso = CelestiaShade.createFullscreenPso(ctx, vertex, resolve, MetalConst.FMT_RGBA16_FLOAT, "TAAU Resolve", error);
            outputRgba = CelestiaShade.createFullscreenPso(ctx, vertex, output, MetalConst.FMT_RGBA8_UNORM, "TAAU Output RGBA", error);
            outputBgra = CelestiaShade.createFullscreenPso(ctx, vertex, output, MetalConst.FMT_BGRA8_UNORM, "TAAU Output BGRA", error);
            return true;
        } catch (RuntimeException e) {
            failed = true;
            LOGGER.warn("TAAU unavailable, using spatial upscaling", e);
            return false;
        } finally {
            if (resolve != 0L) MetalNative.functionDestroy(resolve);
            if (output != 0L) MetalNative.functionDestroy(output);
            if (vertex != 0L) MetalNative.functionDestroy(vertex);
            if (library != 0L) MetalNative.libraryDestroy(library);
        }
    }

    private boolean ensureTargets(int iw, int ih, int ow, int oh) {
        if (iw == inputW && ih == inputH && ow == outputW && oh == outputH) {
            return worldDepth != 0L;
        }
        releaseTargets();
        inputW = iw; inputH = ih; outputW = ow; outputH = oh;
        worldDepth = MetalNative.textureCreate(ctx, MetalConst.FMT_D32_FLOAT, iw, ih, 1, 1,
            false, false, true, false, "TAAU World Depth");
        for (int i = 0; i < 2; i++) {
            history[i] = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, ow, oh, 1, 1,
                false, true, true, false, "TAAU History " + i);
        }
        if (worldDepth != 0L && history[0] != 0L && history[1] != 0L) return true;
        releaseTargets();
        return false;
    }

    static float halton(int index, int base) {
        float result = 0f;
        for (float factor = 1f / base; index > 0; factor /= base, index /= base) {
            result += factor * (index % base);
        }
        return result;
    }

    private void releaseTargets() {
        if (worldDepth != 0L) MetalNative.textureDestroy(ctx, worldDepth);
        worldDepth = 0L;
        for (int i = 0; i < 2; i++) {
            if (history[i] != 0L) MetalNative.textureDestroy(ctx, history[i]);
            history[i] = 0L;
        }
        historyValid = false;
    }

    @Override
    public void close() {
        releaseTargets();
        if (resolvePso != 0L) MetalNative.pipelineDestroy(ctx, resolvePso);
        if (outputRgba != 0L) MetalNative.pipelineDestroy(ctx, outputRgba);
        if (outputBgra != 0L) MetalNative.pipelineDestroy(ctx, outputBgra);
        scratch.close();
    }
}
