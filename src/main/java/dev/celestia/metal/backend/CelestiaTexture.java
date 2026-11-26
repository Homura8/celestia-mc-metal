package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.backend.common.BaseGpuTexture;

public final class CelestiaTexture extends BaseGpuTexture {
    private final CelestiaMetalDevice device;
    private long handle;
    private boolean closed;

    CelestiaTexture(CelestiaMetalDevice device, int usage, String label, GpuFormat format,
                    int width, int height, int depthOrLayers, int mipLevels, long handle) {
        super(usage, label, format, width, height, depthOrLayers, mipLevels);
        this.device = device;
        this.handle = handle;
    }

    public long handle() {
        return handle;
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (handle != 0L) {
            MetalNative.textureDestroy(device.handle(), handle);
            handle = 0L;
        }
    }
}
