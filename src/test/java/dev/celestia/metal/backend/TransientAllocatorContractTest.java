package dev.celestia.metal.backend;

import com.mojang.renderpearl.backend.util.TransientBlockAllocator;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Regression for the black screen after the loading screen on heavily modded instances (Create, Alex's Caves): alpha.16
 * builds passed {@code minimumAllocation = 0, elementSize = 0} to RenderPearl's allocator, which divides by the element
 * size once an upload no longer fits the current block ("/ by zero" in TransientBlockAllocator.allocate while creating
 * animated sprite state). The resource reload failed, Minecraft never left the loading screen, and its startup guard
 * forced OpenGL on the next launch.
 */
class TransientAllocatorContractTest {
    private static final long BLOCK = 4096L;

    private static TransientBlockAllocator<TransientBlockAllocator.Allocator.CpuBlock> allocator() {
        return new TransientBlockAllocator<>(BLOCK, 64L, TransientBlockAllocator.Allocator.CpuBlock.memalloc());
    }

    @Test
    void zeroMinimumAndElementSizeNeverReachTheAllocator() {
        var a = allocator();
        try {
            // Fill most of the block, then ask for more than is left with the alpha.16 arguments (0, 0).
            CelestiaTransientMemory.allocate(a, BLOCK - 100L, 16L, 0L, 0L);
            // The crash itself: RenderPearl's allocator with the raw alpha.16 arguments.
            assertThrows(ArithmeticException.class, () -> a.allocate(1024L, 16L, 0L, 0L));
            var alloc = assertDoesNotThrow(() -> CelestiaTransientMemory.allocate(a, 1024L, 16L, 0L, 0L));
            // 0 means "all of size": the whole request is served (from a fresh block), never a short slice.
            assertEquals(1024L, CelestiaTransientMemory.usable(alloc, 1024L));
        } finally {
            a.close();
        }
    }

    @Test
    void partialAllocationsReportTheLengthTheyGot() {
        var a = allocator();
        try {
            CelestiaTransientMemory.allocate(a, BLOCK - 512L, 16L, 0L, 0L);
            // At least 128 bytes, in 64-byte elements: the allocator may hand out the block's remainder instead of 2048.
            var alloc = CelestiaTransientMemory.allocate(a, 2048L, 16L, 128L, 64L);
            long usable = CelestiaTransientMemory.usable(alloc, 2048L);
            assertTrue(usable >= 128L && usable <= 2048L, () -> "usable " + usable);
            assertEquals(0L, usable % 64L);
            assertTrue(alloc.offset() + usable <= BLOCK, "the slice handed out must stay inside its block");
            // A minimum above the request is clamped to it.
            var big = CelestiaTransientMemory.allocate(a, 256L, 16L, 10_000L, 1L);
            assertEquals(256L, CelestiaTransientMemory.usable(big, 256L));
        } finally {
            a.close();
        }
    }
}
