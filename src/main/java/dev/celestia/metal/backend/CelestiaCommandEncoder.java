package dev.celestia.metal.backend;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.buffers.TransientMemory;
import com.mojang.renderpearl.api.commands.GpuFence;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.commands.RenderPass;
import com.mojang.renderpearl.api.commands.RenderPassDescriptor;
import com.mojang.renderpearl.api.device.GpuDeviceLossException;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.RenderPassBackend;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.util.ArrayDeque;
import java.util.List;
import java.util.Optional;
import java.util.OptionalDouble;
import org.joml.Vector4fc;
import org.slf4j.Logger;

public final class CelestiaCommandEncoder implements CommandEncoderBackend {
    /** CELESTIA_GPU_PROFILE=1 (cm_profiler.m): pass labels are sent so the profiler can split RenderPearl's passes by name. */
    private static final boolean GPU_PROFILE = "1".equals(System.getenv("CELESTIA_GPU_PROFILE"));

    private static final Logger LOGGER = LogUtils.getLogger();
    private record Deferred(long submitSerial, Runnable action) {}

    private final CelestiaMetalDevice device;
    private final CelestiaTransientMemory transientMemory;
    private final ArrayDeque<Deferred> deferred = new ArrayDeque<>();
    // Reusable off-heap scratch memory for per-pass / per-draw FFM arguments (render thread only).
    private final Arena scratchArena = Arena.ofShared();
    private final MemorySegment passScratch = scratchArena.allocate(PASS_SCRATCH_BYTES, 16);
    private final Scratch drawScratch = new Scratch();
    private final MemorySegment statsScratch = scratchArena.allocate(8L * MetalConst.STAT_COUNT, 8);
    private final long[] prevStats = new long[MetalConst.STAT_COUNT];
    private volatile long[] lastFrameStats = new long[MetalConst.STAT_COUNT];
    // Rolling one-second window of frames submitted / shown on screen / dropped, for the F3 line.
    private long windowStartNs = System.nanoTime();
    private final long[] windowStart = new long[MetalConst.STAT_COUNT];
    private volatile long[] presentRates = new long[3];
    private volatile double[] waitRates = new double[3];
    private CelestiaRenderPass currentRenderPass;
    private boolean closed;

    // passScratch layout: 8 x int64 color views | 8 x int32 clear flags | 8 x float4 clear colors
    private static final long PASS_VIEWS_OFF = 0L;
    private static final long PASS_FLAGS_OFF = 64L;
    private static final long PASS_RGBA_OFF = 96L;
    private static final long PASS_SCRATCH_BYTES = 224L;
    private static final int MAX_COLOR_ATTACHMENTS = 8;

    /** Grow-only off-heap scratch buffer; contents are only valid until the next {@link #get} call. */
    static final class Scratch {
        private Arena arena;
        private MemorySegment segment = MemorySegment.NULL;

        MemorySegment get(long bytes) {
            if (segment.byteSize() < bytes) {
                if (arena != null) arena.close();
                arena = Arena.ofShared();
                segment = arena.allocate(Math.max(bytes, Math.max(4096L, segment.byteSize() * 2L)), 16);
            }
            return segment;
        }

        void close() {
            if (arena != null) {
                arena.close();
                arena = null;
                segment = MemorySegment.NULL;
            }
        }
    }

    Scratch drawScratch() {
        return drawScratch;
    }

    /** Serial the currently recording command buffer will receive when submitted. */
    private long recordingSerial() {
        return MetalNative.deviceNextSubmit(device.handle()) + 1L;
    }

    /**
     * Waits until submit {@code serial} has completed on the GPU, submitting the recording command buffer first
     * when it contains that work. Used to give CPU reads of GPU-written buffers OpenGL-like implicit sync.
     */
    void awaitSerial(long serial) {
        if (serial <= 0L || serial <= MetalNative.deviceCompletedSubmit(device.handle())) return;
        if (serial > MetalNative.deviceNextSubmit(device.handle())) {
            if (currentRenderPass != null) {
                LOGGER.warn("Buffer mapped for read while a render pass is open; GPU writes may not be visible yet");
                return;
            }
            submit();
        }
        if (!MetalNative.waitSubmit(device.handle(), serial, 5_000_000_000L)) {
            LOGGER.warn("Timed out waiting for GPU writes before buffer map (serial {})", serial);
        }
    }

    private void sampleFrameStats() {
        MetalNative.deviceStats(device.handle(), statsScratch, MetalConst.STAT_COUNT);
        long[] delta = new long[MetalConst.STAT_COUNT];
        for (int i = 0; i < MetalConst.STAT_COUNT; i++) {
            long cur = statsScratch.getAtIndex(ValueLayout.JAVA_LONG, i);
            delta[i] = cur - prevStats[i];
            prevStats[i] = cur;
        }
        lastFrameStats = delta;
        long now = System.nanoTime();
        if (now - windowStartNs >= 1_000_000_000L) {
            double secs = (now - windowStartNs) / 1e9;
            presentRates = new long[] {
                Math.round((prevStats[MetalConst.STAT_FRAMES_SUBMITTED] - windowStart[MetalConst.STAT_FRAMES_SUBMITTED]) / secs),
                Math.round((prevStats[MetalConst.STAT_PRESENTS_SHOWN] - windowStart[MetalConst.STAT_PRESENTS_SHOWN]) / secs),
                Math.round((prevStats[MetalConst.STAT_FRAMES_DROPPED] - windowStart[MetalConst.STAT_FRAMES_DROPPED]) / secs),
            };
            waitRates = new double[] {
                (prevStats[MetalConst.STAT_WAIT_THROTTLE_US] - windowStart[MetalConst.STAT_WAIT_THROTTLE_US]) / 1000.0 / secs,
                (prevStats[MetalConst.STAT_WAIT_FENCE_US] - windowStart[MetalConst.STAT_WAIT_FENCE_US]) / 1000.0 / secs,
                (prevStats[MetalConst.STAT_WAIT_SLOT_US] - windowStart[MetalConst.STAT_WAIT_SLOT_US]) / 1000.0 / secs,
            };
            System.arraycopy(prevStats, 0, windowStart, 0, MetalConst.STAT_COUNT);
            windowStartNs = now;
        }
    }

    /** Milliseconds per second the CPU spent blocked on {in-flight frame cap, fences, present slots}. */
    public double[] waitRates() {
        return waitRates;
    }

    /** {frames submitted, frames shown on screen, frames dropped} per second over the last full second. */
    public long[] presentRates() {
        return presentRates;
    }

    /** Native encoder counters for the most recently presented frame, indexed by {@code MetalConst.STAT_*}. */
    public long[] lastFrameStats() {
        return lastFrameStats;
    }

    CelestiaCommandEncoder(CelestiaMetalDevice device) {
        this.device = device;
        this.transientMemory = new CelestiaTransientMemory(device, this);
    }

    public void runWhenSubmitDone(Runnable action) {
        long targetSerial = MetalNative.deviceNextSubmit(device.handle()) + 1L;
        synchronized (deferred) {
            deferred.addLast(new Deferred(targetSerial, action));
        }
    }

    void onPresentedBySurface() {
        sampleFrameStats();
        device.applyEncoderOptions();
        transientMemory.endSubmit();
        runCompletedCallbacks();
        checkDeviceHealth();
    }

    private void runCompletedCallbacks() {
        long completed = MetalNative.deviceCompletedSubmit(device.handle());
        while (true) {
            Deferred d;
            synchronized (deferred) {
                if (deferred.isEmpty() || deferred.peekFirst().submitSerial() > completed) break;
                d = deferred.pollFirst();
            }
            if (d != null) {
                d.action().run();
            }
        }
    }

    private void checkDeviceHealth() {
        String err = MetalNative.deviceDrainErrors(device.handle());
        if (!err.isEmpty()) {
            LOGGER.error("Metal GPU error: {}", err);
        }
        if (MetalNative.deviceIsLost(device.handle())) {
            throw new GpuDeviceLossException("Metal GPU device lost: " + err);
        }
    }

    @Override
    public void submit() {
        if (closed) return;
        if (currentRenderPass != null) {
            submitRenderPass();
        }
        transientMemory.endSubmit();
        int maxInFlight = CelestiaConfig.get().appleSilicon.lowLatencyQueue ? 2 : 3;
        MetalNative.cmdSubmit(device.handle(), maxInFlight);
        runCompletedCallbacks();
        checkDeviceHealth();
    }

    @Override
    public TransientMemory transientMemory() {
        return transientMemory;
    }

    @Override
    public RenderPassBackend createRenderPass(RenderPassDescriptor desc) {
        if (currentRenderPass != null) {
            throw new IllegalStateException("Render pass already active");
        }
        List<RenderPassDescriptor.Attachment<Optional<Vector4fc>>> colors = desc.colorAttachments();
        int colorCount = colors.size();
        RenderPassDescriptor.Attachment<OptionalDouble> depthAtt = desc.depthAttachment();
        GpuFormat depthFmt = depthAtt != null && depthAtt.textureView() != null
            ? depthAtt.textureView().texture().getFormat()
            : null;
        RenderPass.RenderArea area = desc.renderArea();
        if (colorCount > MAX_COLOR_ATTACHMENTS) {
            throw new IllegalArgumentException("Too many color attachments: " + colorCount);
        }

        CelestiaShade shade = device.shade();
        int passColorOverride = CelestiaPipeline.NO_COLOR_OVERRIDE;
        ShadeShaderPatcher.Variant passVariant = ShadeShaderPatcher.Variant.BASE;
        {
            MemorySegment cViews = colorCount > 0 ? passScratch.asSlice(PASS_VIEWS_OFF, 8L * colorCount) : MemorySegment.NULL;
            MemorySegment cFlags = colorCount > 0 ? passScratch.asSlice(PASS_FLAGS_OFF, 4L * colorCount) : MemorySegment.NULL;
            MemorySegment cRgba = colorCount > 0 ? passScratch.asSlice(PASS_RGBA_OFF, 16L * colorCount) : MemorySegment.NULL;
            boolean redirectedMain = false;
            for (int i = 0; i < colorCount; i++) {
                var att = colors.get(i);
                GpuTexture attTex = att.textureView().texture();
                boolean redirectThis = shade != null && shade.shouldRedirect(attTex);
                if (redirectThis) redirectedMain = true;
                long viewHandle = redirectThis
                    ? shade.redirectColorViewHandle(att.textureView())
                    : ((CelestiaTextureView) att.textureView()).handle();
                cViews.set(ValueLayout.JAVA_LONG, i * 8L, viewHandle);
                Optional<Vector4fc> clr = att.clearValue();
                if (clr != null && clr.isPresent()) {
                    Vector4fc v = clr.get();
                    cFlags.set(ValueLayout.JAVA_INT, i * 4L, 1);
                    if (redirectThis) {
                        float[] hdrClr = shade.transformClearColorToHdr(v.x(), v.y(), v.z(), v.w());
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L, hdrClr[0]);
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 4, hdrClr[1]);
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 8, hdrClr[2]);
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 12, hdrClr[3]);
                    } else {
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L, v.x());
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 4, v.y());
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 8, v.z());
                        cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 12, v.w());
                    }
                } else {
                    cFlags.set(ValueLayout.JAVA_INT, i * 4L, 0);
                }
            }
            if (redirectedMain) {
                passColorOverride = MetalConst.FMT_RGBA16_FLOAT;
                passVariant = ShadeShaderPatcher.Variant.HDR_WORLD;
            } else if (shade != null && shade.isHandPassActive() && colorCount == 1) {
                GpuTexture attTex = colors.get(0).textureView().texture();
                passColorOverride = MetalConst.toNativeFormat(attTex.getFormat());
                passVariant = ShadeShaderPatcher.Variant.HDR_HAND;
            }

            long depthViewHandle = 0L;
            boolean depthHasClear = false;
            double depthClearVal = 0.0;
            if (depthAtt != null && depthAtt.textureView() != null) {
                depthViewHandle = ((CelestiaTextureView) depthAtt.textureView()).handle();
                if (depthAtt.clearValue() != null && depthAtt.clearValue().isPresent()) {
                    depthHasClear = true;
                    depthClearVal = depthAtt.clearValue().getAsDouble();
                }
            }

            // Labels are only consumed natively when debug labels are on; skip the string + arena otherwise.
            String lbl = device.isDebuggingEnabled() || GPU_PROFILE
                ? (desc.label() != null ? desc.label().get() : "RenderPass")
                : null;
            int ax = area != null ? area.x() : 0;
            int ay = area != null ? area.y() : 0;
            int aw = area != null ? area.width() : 0;
            int ah = area != null ? area.height() : 0;

            MetalNative.passBegin(device.handle(), cViews, cFlags, cRgba, colorCount,
                depthViewHandle, depthHasClear, depthClearVal, ax, ay, aw, ah, lbl);
        }

        currentRenderPass = new CelestiaRenderPass(device, this, passColorOverride, depthFmt, passVariant);
        return currentRenderPass;
    }

    @Override
    public void submitRenderPass() {
        if (currentRenderPass != null) {
            MetalNative.passFinish(device.handle());
            currentRenderPass.closePass();
            currentRenderPass = null;
        }
    }

    @Override
    public void clearColorTexture(GpuTexture texture, Vector4fc color) {
        if (texture instanceof CelestiaTexture ct) {
            CelestiaShade shade = device.shade();
            if (shade != null && shade.shouldRedirect(ct)) {
                float[] hdr = shade.transformClearColorToHdr(color.x(), color.y(), color.z(), color.w());
                MetalNative.blitClearColor(device.handle(), shade.redirectColorTextureHandle(ct), hdr[0], hdr[1], hdr[2], hdr[3]);
                return;
            }
            MetalNative.blitClearColor(device.handle(), ct.handle(), color.x(), color.y(), color.z(), color.w());
        }
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture colorTex, Vector4fc color, GpuTexture depthTex, double depth) {
        if (colorTex instanceof CelestiaTexture ct && depthTex instanceof CelestiaTexture dt) {
            CelestiaShade shade = device.shade();
            if (shade != null && shade.shouldRedirect(ct)) {
                float[] hdr = shade.transformClearColorToHdr(color.x(), color.y(), color.z(), color.w());
                MetalNative.blitClearColorDepth(device.handle(), shade.redirectColorTextureHandle(ct),
                    hdr[0], hdr[1], hdr[2], hdr[3], dt.handle(), depth);
                return;
            }
            MetalNative.blitClearColorDepth(device.handle(), ct.handle(),
                color.x(), color.y(), color.z(), color.w(), dt.handle(), depth);
        }
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture colorTex, Vector4fc color, GpuTexture depthTex, double depth,
                                           int rx, int ry, int rw, int rh, int mip) {
        // Fallback to full clear when region clear is requested on Metal attachment
        clearColorAndDepthTextures(colorTex, color, depthTex, depth);
    }

    @Override
    public void clearDepthTexture(GpuTexture depthTex, double depth) {
        if (depthTex instanceof CelestiaTexture dt) {
            MetalNative.blitClearDepth(device.handle(), dt.handle(), depth);
        }
    }

    @Override
    public void writeToBuffer(GpuBufferSlice slice, ByteBuffer data) {
        if (!(slice.buffer() instanceof CelestiaBuffer dst) || data == null || !data.hasRemaining()) return;
        int len = data.remaining();
        // Stage via transient unified-memory buffer and ordered blit so writes never race in-flight GPU reads
        GpuBufferSlice staging = transientMemory.uploadStaging(List.of(data), 16L, GpuBuffer.USAGE_COPY_SRC, len, 1L);
        if (staging.buffer() instanceof CelestiaBuffer src) {
            MetalNative.blitCopyBuffer(device.handle(), src.handle(), staging.offset(), dst.handle(), slice.offset(), len);
            dst.markGpuWrite(recordingSerial());
        }
    }

    @Override
    public void copyToBuffer(GpuBufferSlice srcSlice, GpuBufferSlice dstSlice) {
        if (srcSlice.buffer() instanceof CelestiaBuffer s && dstSlice.buffer() instanceof CelestiaBuffer d) {
            MetalNative.blitCopyBuffer(device.handle(), s.handle(), srcSlice.offset(),
                d.handle(), dstSlice.offset(), Math.min(srcSlice.length(), dstSlice.length()));
            d.markGpuWrite(recordingSerial());
        }
    }

    @Override
    public void writeToTexture(GpuTexture tex, ByteBuffer data, int mip, int slice, int x, int y, int w, int h) {
        if (!(tex instanceof CelestiaTexture ct) || data == null || w <= 0 || h <= 0) return;
        int len = data.remaining();
        int rowBytes = w * ct.getFormat().blockSize();
        if (data.isDirect()) {
            MetalNative.blitWriteTexture(device.handle(), ct.handle(), MemorySegment.ofBuffer(data), len,
                rowBytes, mip, slice, x, y, w, h);
        } else {
            try (Arena arena = Arena.ofConfined()) {
                byte[] tmp = new byte[len];
                data.duplicate().get(tmp);
                MemorySegment seg = arena.allocate(len);
                MemorySegment.copy(tmp, 0, seg, ValueLayout.JAVA_BYTE, 0, len);
                MetalNative.blitWriteTexture(device.handle(), ct.handle(), seg, len,
                    rowBytes, mip, slice, x, y, w, h);
            }
        }
    }

    @Override
    public void copyBufferToTexture(GpuBufferSlice srcSlice, int srcX, int srcY,
                                    int srcRowLengthPixels, int srcImageHeight,
                                    GpuTexture dstTex, int dstX, int dstY, int w, int h, int mip, int slice) {
        if (srcSlice.buffer() instanceof CelestiaBuffer cb && dstTex instanceof CelestiaTexture ct) {
            int bpp = ct.getFormat().blockSize();
            int stridePixels = srcRowLengthPixels > 0 ? srcRowLengthPixels : w;
            long pixelOffset = srcX + (long) stridePixels * srcY;
            long byteOffset = srcSlice.offset() + pixelOffset * bpp;
            int rowBytes = stridePixels * bpp;
            MetalNative.blitCopyBufferToTexture(device.handle(), cb.handle(), byteOffset, rowBytes,
                ct.handle(), mip, slice, dstX, dstY, w, h);
        }
    }

    @Override
    public void copyTextureToBuffer(GpuTexture srcTex, GpuBuffer dstBuf, long dstOffset, Runnable onComplete, int mip) {
        if (srcTex instanceof CelestiaTexture ct) {
            copyTextureToBuffer(srcTex, dstBuf, dstOffset, onComplete, mip, 0, 0, ct.getWidth(mip), ct.getHeight(mip));
        }
    }

    @Override
    public void copyTextureToBuffer(GpuTexture srcTex, GpuBuffer dstBuf, long dstOffset, Runnable onComplete,
                                    int mip, int x, int y, int w, int h) {
        if (srcTex instanceof CelestiaTexture ct && dstBuf instanceof CelestiaBuffer cb) {
            int rowBytes = w * ct.getFormat().blockSize();
            MetalNative.blitCopyTextureToBuffer(device.handle(), ct.handle(), mip, 0, x, y, w, h,
                cb.handle(), dstOffset, rowBytes);
            cb.markGpuWrite(recordingSerial());
            if (onComplete != null) {
                runWhenSubmitDone(onComplete);
            }
        }
    }

    @Override
    public void copyTextureToTexture(GpuTexture srcTex, GpuTexture dstTex, int srcMip,
                                     int dstX, int dstY, int srcX, int srcY, int w, int h) {
        if (srcTex instanceof CelestiaTexture st && dstTex instanceof CelestiaTexture dt) {
            MetalNative.blitCopyTexture(device.handle(), st.handle(), srcMip, 0, srcX, srcY,
                dt.handle(), srcMip, 0, dstX, dstY, w, h);
        }
    }

    @Override
    public GpuFence createFence() {
        long serial = MetalNative.deviceNextSubmit(device.handle());
        if (MetalNative.cmdHasActive(device.handle())) {
            serial += 1L;
        }
        return new CelestiaFence(device, this, serial);
    }

    @Override
    public void writeTimestamp(GpuQueryPool pool, int index) {
        if (pool instanceof CelestiaQueryPool cqp) {
            long gpuNs = MetalNative.deviceLastGpuNs(device.handle());
            if (gpuNs > 0L) cqp.record(index, gpuNs);
        }
    }

    void close() {
        if (closed) return;
        closed = true;
        MetalNative.deviceWaitIdle(device.handle());
        runCompletedCallbacks();
        transientMemory.close();
        drawScratch.close();
        scratchArena.close();
    }
}
