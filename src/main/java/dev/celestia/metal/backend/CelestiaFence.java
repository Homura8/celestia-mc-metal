package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.commands.GpuFence;

public final class CelestiaFence implements GpuFence {
    private final CelestiaMetalDevice device;
    private final CelestiaCommandEncoder encoder;
    private final long submitSerial;
    private boolean closed;

    CelestiaFence(CelestiaMetalDevice device, CelestiaCommandEncoder encoder, long submitSerial) {
        this.device = device;
        this.encoder = encoder;
        this.submitSerial = submitSerial;
    }

    @Override
    public boolean awaitCompletion(long timeoutNs) {
        if (closed || submitSerial <= 0L) return true;
        if (submitSerial > MetalNative.deviceNextSubmit(device.handle()) && MetalNative.cmdHasActive(device.handle())) {
            encoder.submit();
        }
        return MetalNative.waitSubmit(device.handle(), submitSerial, timeoutNs);
    }

    @Override
    public void close() {
        closed = true;
    }
}
