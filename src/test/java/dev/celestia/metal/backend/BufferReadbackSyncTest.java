package dev.celestia.metal.backend;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.jupiter.api.Test;

/**
 * Regression test for OpenGL-style implicit synchronization on {@code GpuBuffer.map(read = true)}.
 *
 * <p>Xaero's World Map (and the minimap tiles it feeds) reads {@code copyTextureToBuffer} results by mapping the
 * destination buffer straight away, relying on OpenGL's implicit wait. Without it the mod cached stale bytes
 * and later re-uploaded them as corrupted map tiles.
 */
class BufferReadbackSyncTest {
    private static final int INTS = 1024;

    @Test
    void mapForReadWaitsForQueuedGpuWrites() {
        MetalNative.ProbeInfo probe = MetalNative.probeDevice();
        assertTrue(probe.supported(), "Apple7+ GPU required");
        CelestiaMetalDevice device = new CelestiaMetalDevice(probe, null);
        try {
            ByteBuffer pattern = ByteBuffer.allocateDirect(INTS * 4).order(ByteOrder.nativeOrder());
            for (int i = 0; i < INTS; i++) pattern.putInt(0x5EED0000 + i);
            pattern.flip();
            GpuBuffer src = device.createBuffer(() -> "ReadbackSrc", GpuBuffer.USAGE_COPY_SRC, pattern);
            GpuBuffer dst = device.createBuffer(() -> "ReadbackDst",
                GpuBuffer.USAGE_COPY_DST | GpuBuffer.USAGE_MAP_READ, INTS * 4L);
            CommandEncoderBackend encoder = device.createCommandEncoder();

            for (int round = 0; round < 4; round++) {
                // GPU write queued in the still-recording command buffer; no submit, fence or callback.
                encoder.copyToBuffer(src.slice(), dst.slice());
                try (GpuBufferSlice.MappedView view = dst.map(0L, INTS * 4L, true, false)) {
                    ByteBuffer data = view.data();
                    for (int i = 0; i < INTS; i++) {
                        assertEquals(0x5EED0000 + i, data.getInt(i * 4), "word " + i + " in round " + round);
                    }
                }
                // Change the source on the CPU so every round needs a fresh GPU copy to pass.
                for (int i = 0; i < INTS; i++) {
                    pattern.putInt(i * 4, 0x5EED0000 + i);
                }
                ByteBuffer cleared = ByteBuffer.allocateDirect(INTS * 4).order(ByteOrder.nativeOrder());
                encoder.writeToBuffer(dst.slice(), cleared);
                try (GpuBufferSlice.MappedView view = dst.map(0L, INTS * 4L, true, false)) {
                    assertEquals(0, view.data().getInt(0), "writeToBuffer must also be visible to read maps");
                }
            }
            src.close();
            dst.close();
        } finally {
            device.close();
        }
    }
}
