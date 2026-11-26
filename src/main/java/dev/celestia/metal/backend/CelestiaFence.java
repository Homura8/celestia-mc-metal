package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.commands.GpuFence;

public final class CelestiaFence implements GpuFence {
    private final CelestiaMetalDevice device;
    private final long submitSerial;
    private boolean closed;

    CelestiaFence(CelestiaMetalDevice device, long submitSerial) {
        this.device = device;
        this.submitSerial = submitSerial;
    }

    @Override
    public boolean awaitCompletion(long timeoutNs) {
        if (closed || submitSerial <= 0L) return true;
        return MetalNative.waitSubmit(device.handle(), submitSerial, timeoutNs);
    }

    @Override
    public void close() {
        closed = true;
    }
}
