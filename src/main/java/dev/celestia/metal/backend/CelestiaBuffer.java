package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.backend.common.BaseGpuBuffer;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

public final class CelestiaBuffer extends BaseGpuBuffer {
    private final CelestiaMetalDevice device;
    private long handle;
    private final MemorySegment mappedSegment;
    private boolean closed;
    private final boolean pooled;
    // Submit serial of the command buffer holding the most recent GPU write into this buffer
    // (copyTextureToBuffer / copyToBuffer / writeToBuffer destination).
    private volatile long pendingGpuWriteSerial;

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

    void markGpuWrite(long submitSerial) {
        if (submitSerial > pendingGpuWriteSerial) {
            pendingGpuWriteSerial = submitSerial;
        }
    }

    long pendingGpuWriteSerial() {
        return pendingGpuWriteSerial;
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
        if (read) {
            // Match OpenGL's implicit synchronization: mapping for read waits until queued GPU writes into this
            // buffer have executed. Mods such as Xaero's World Map read back copyTextureToBuffer results this way
            // without fencing; returning the pointer early hands them stale bytes. Write-only maps stay
            // unsynchronized so fence-managed ring buffers never stall.
            device.awaitGpuWrites(this);
        }
        ByteBuffer view = mappedSegment.asSlice(offset, length).asByteBuffer().order(ByteOrder.nativeOrder());
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
