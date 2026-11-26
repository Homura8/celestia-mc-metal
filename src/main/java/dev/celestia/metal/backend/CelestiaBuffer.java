package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.backend.common.BaseGpuBuffer;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;

public final class CelestiaBuffer extends BaseGpuBuffer {
    private final CelestiaMetalDevice device;
    private long handle;
    private final MemorySegment mappedSegment;
    private boolean closed;
    private final boolean pooled;

    CelestiaBuffer(CelestiaMetalDevice device, int usage, long size, long handle, boolean pooled) {
        super(usage, size);
        this.device = device;
        this.handle = handle;
        this.pooled = pooled;
        long ptr = MetalNative.bufferContents(handle);
        this.mappedSegment = ptr != 0L
            ? MemorySegment.ofAddress(ptr).reinterpret(Math.max(16L, size))
            : MemorySegment.NULL;
    }

    public long handle() {
        return handle;
    }

    public MemorySegment mappedSegment() {
        return mappedSegment;
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public GpuBufferSlice.MappedView map(long offset, long length, boolean read, boolean write) {
        checkCanBeUsed();
        if (offset < 0 || length < 0 || offset + length > size()) {
            throw new IndexOutOfBoundsException("Map range [" + offset + ", " + (offset + length) + ") out of bounds for size " + size());
        }
        ByteBuffer view = mappedSegment.asSlice(offset, length).asByteBuffer();
        return new GpuBufferSlice.MappedView(slice(offset, length), view, () -> {});
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (handle != 0L) {
            if (pooled) {
                device.recycleBuffer(handle, size());
            } else {
                MetalNative.bufferDestroy(device.handle(), handle);
            }
            handle = 0L;
        }
    }
}
