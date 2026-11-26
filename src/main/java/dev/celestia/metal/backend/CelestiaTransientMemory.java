package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.buffers.TransientMemory;
import com.mojang.renderpearl.backend.util.TransientBlockAllocator;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import org.lwjgl.system.MemoryUtil;

/**
 * Unified-memory transient allocator for Apple Silicon.
 * Staging and GPU buffers share {@code MTLStorageModeShared} memory so uploads require zero extra copy.
 */
public final class CelestiaTransientMemory implements TransientMemory {
    private static final long BLOCK_SIZE = 4L * 1024L * 1024L;
    private static final long MAX_CPU_ALIGN = 64L;
    private static final long MAX_GPU_ALIGN = 256L;
    private static final int DEFAULT_USAGE = GpuBuffer.USAGE_COPY_SRC | GpuBuffer.USAGE_COPY_DST
        | GpuBuffer.USAGE_VERTEX | GpuBuffer.USAGE_INDEX | GpuBuffer.USAGE_UNIFORM;

    private record MetalBlock(CelestiaBuffer buffer) implements TransientBlockAllocator.Allocator.Block {
        @Override
        public boolean suboptimal() {
            return buffer.isClosed();
        }
    }

    private final CelestiaMetalDevice device;
    private final CelestiaCommandEncoder encoder;
    private final TransientBlockAllocator<TransientBlockAllocator.Allocator.CpuBlock> cpuAllocator;
    private final TransientBlockAllocator<MetalBlock> sharedAllocator;

    CelestiaTransientMemory(CelestiaMetalDevice device, CelestiaCommandEncoder encoder) {
        this.device = device;
        this.encoder = encoder;
        this.cpuAllocator = new TransientBlockAllocator<>(
            BLOCK_SIZE, MAX_CPU_ALIGN,
            TransientBlockAllocator.Allocator.CpuBlock.memalloc()
        );
        this.sharedAllocator = new TransientBlockAllocator<>(
            BLOCK_SIZE, MAX_GPU_ALIGN,
            TransientBlockAllocator.Allocator.create(
                size -> new MetalBlock(device.createBufferInternal("TransientShared", DEFAULT_USAGE, size)),
                block -> encoder.runWhenSubmitDone(block.buffer()::close)
            )
        );
    }

    void beginSubmit() {
        // Nothing extra required; blocks rotate at endSubmit
    }

    void endSubmit() {
        Runnable cpuRotate = cpuAllocator.rotate();
        Runnable gpuRotate = sharedAllocator.rotate();
        encoder.runWhenSubmitDone(() -> {
            cpuRotate.run();
            gpuRotate.run();
        });
    }

    void close() {
        cpuAllocator.close();
        sharedAllocator.close();
    }

    @Override
    public ByteBuffer allocateCpu(long size, long alignment, long unusedOffset, long unusedStep) {
        var alloc = cpuAllocator.allocate(size, Math.max(1L, alignment), unusedOffset, unusedStep);
        return MemoryUtil.memByteBuffer(alloc.block().address() + alloc.offset(), (int) size);
    }

    @Override
    public GpuBufferSlice.MappedView allocateStaging(long size, long alignment, int usage, long unusedOffset, long unusedStep) {
        return allocateSharedMapped(size, alignment);
    }

    @Override
    public GpuBufferSlice allocateGpu(long size, long alignment, int usage, long unusedOffset, long unusedStep) {
        var alloc = sharedAllocator.allocate(size, Math.max(16L, alignment), unusedOffset, unusedStep);
        return alloc.block().buffer().slice(alloc.offset(), size);
    }

    @Override
    public GpuBufferSlice.MappedView allocateGpuMapped(long size, long alignment, int usage, long unusedOffset, long unusedStep) {
        return allocateSharedMapped(size, alignment);
    }

    private GpuBufferSlice.MappedView allocateSharedMapped(long size, long alignment) {
        var alloc = sharedAllocator.allocate(size, Math.max(16L, alignment), 0L, 0L);
        return alloc.block().buffer().map(alloc.offset(), size, true, true);
    }

    @Override
    public GpuBufferSlice uploadStaging(List<ByteBuffer> buffers, long alignment, int usage, long offset, long step) {
        return uploadShared(buffers, alignment);
    }

    @Override
    public GpuBufferSlice uploadGpu(List<ByteBuffer> buffers, long alignment, int usage, long offset, long step) {
        return uploadShared(buffers, alignment);
    }

    private GpuBufferSlice uploadShared(List<ByteBuffer> buffers, long alignment) {
        long total = 0L;
        for (ByteBuffer b : buffers) total += b.remaining();
        if (total == 0L) {
            return allocateGpu(16L, alignment, DEFAULT_USAGE, 0L, 0L);
        }
        var alloc = sharedAllocator.allocate(total, Math.max(16L, alignment), 0L, 0L);
        ByteBuffer dst = alloc.block().buffer().mappedSegment().asSlice(alloc.offset(), total).asByteBuffer().order(ByteOrder.nativeOrder());
        for (ByteBuffer src : buffers) {
            dst.put(src.duplicate());
        }
        return alloc.block().buffer().slice(alloc.offset(), total);
    }

    @Override
    public List<GpuBufferSlice> multiUploadStaging(List<ByteBuffer> buffers, long alignment, int usage) {
        return multiUploadShared(buffers, alignment);
    }

    @Override
    public List<GpuBufferSlice> multiUploadGpu(List<ByteBuffer> buffers, long alignment, int usage) {
        return multiUploadShared(buffers, alignment);
    }

    private List<GpuBufferSlice> multiUploadShared(List<ByteBuffer> buffers, long alignment) {
        long align = Math.max(16L, alignment);
        List<GpuBufferSlice> slices = new ArrayList<>(buffers.size());
        for (ByteBuffer src : buffers) {
            int len = src.remaining();
            var alloc = sharedAllocator.allocate(Math.max(16L, len), align, 0L, 0L);
            if (len > 0) {
                ByteBuffer dst = alloc.block().buffer().mappedSegment().asSlice(alloc.offset(), len).asByteBuffer().order(ByteOrder.nativeOrder());
                dst.put(src.duplicate());
            }
            slices.add(alloc.block().buffer().slice(alloc.offset(), len));
        }
        return slices;
    }
}
