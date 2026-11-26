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
    private static final Logger LOGGER = LogUtils.getLogger();
    private record Deferred(long submitSerial, Runnable action) {}

    private final CelestiaMetalDevice device;
    private final CelestiaTransientMemory transientMemory;
    private final ArrayDeque<Deferred> deferred = new ArrayDeque<>();
    private CelestiaRenderPass currentRenderPass;
    private boolean closed;

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

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment cViews = colorCount > 0 ? arena.allocate(8L * colorCount, 8) : MemorySegment.NULL;
            MemorySegment cFlags = colorCount > 0 ? arena.allocate(4L * colorCount, 4) : MemorySegment.NULL;
            MemorySegment cRgba = colorCount > 0 ? arena.allocate(16L * colorCount, 4) : MemorySegment.NULL;
            for (int i = 0; i < colorCount; i++) {
                var att = colors.get(i);
                long viewHandle = ((CelestiaTextureView) att.textureView()).handle();
                cViews.set(ValueLayout.JAVA_LONG, i * 8L, viewHandle);
                Optional<Vector4fc> clr = att.clearValue();
                if (clr != null && clr.isPresent()) {
                    Vector4fc v = clr.get();
                    cFlags.set(ValueLayout.JAVA_INT, i * 4L, 1);
                    cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L, v.x());
                    cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 4, v.y());
                    cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 8, v.z());
                    cRgba.set(ValueLayout.JAVA_FLOAT, i * 16L + 12, v.w());
                } else {
                    cFlags.set(ValueLayout.JAVA_INT, i * 4L, 0);
                }
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

            String lbl = desc.label() != null ? desc.label().get() : "RenderPass";
            int ax = area != null ? area.x() : 0;
            int ay = area != null ? area.y() : 0;
            int aw = area != null ? area.width() : 0;
            int ah = area != null ? area.height() : 0;

            MetalNative.passBegin(device.handle(), cViews, cFlags, cRgba, colorCount,
                depthViewHandle, depthHasClear, depthClearVal, ax, ay, aw, ah, lbl);
        }

        currentRenderPass = new CelestiaRenderPass(device, this, depthFmt);
        return currentRenderPass;
    }

    @Override
    public void submitRenderPass() {
        if (currentRenderPass != null) {
            MetalNative.passEnd(device.handle());
            currentRenderPass.closePass();
            currentRenderPass = null;
        }
    }

    @Override
    public void clearColorTexture(GpuTexture texture, Vector4fc color) {
        if (texture instanceof CelestiaTexture ct) {
            MetalNative.blitClearColor(device.handle(), ct.handle(), color.x(), color.y(), color.z(), color.w());
        }
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture colorTex, Vector4fc color, GpuTexture depthTex, double depth) {
        if (colorTex instanceof CelestiaTexture ct && depthTex instanceof CelestiaTexture dt) {
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
        GpuBufferSlice staging = transientMemory.uploadStaging(List.of(data), 16L, GpuBuffer.USAGE_COPY_SRC, 0L, 0L);
        if (staging.buffer() instanceof CelestiaBuffer src) {
            MetalNative.blitCopyBuffer(device.handle(), src.handle(), staging.offset(), dst.handle(), slice.offset(), len);
        }
    }

    @Override
    public void copyToBuffer(GpuBufferSlice srcSlice, GpuBufferSlice dstSlice) {
        if (srcSlice.buffer() instanceof CelestiaBuffer s && dstSlice.buffer() instanceof CelestiaBuffer d) {
            MetalNative.blitCopyBuffer(device.handle(), s.handle(), srcSlice.offset(),
                d.handle(), dstSlice.offset(), Math.min(srcSlice.length(), dstSlice.length()));
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
                                    GpuTexture dstTex, int mip, int slice, int dstX, int dstY, int w, int h) {
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
        long latest = MetalNative.deviceNextSubmit(device.handle());
        return new CelestiaFence(device, latest);
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
    }
}
