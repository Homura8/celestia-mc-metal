package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.backend.common.BaseGpuTextureView;

public final class CelestiaTextureView extends BaseGpuTextureView {
    private final CelestiaMetalDevice device;
    private long handle;
    private boolean closed;

    CelestiaTextureView(CelestiaMetalDevice device, GpuTexture texture, int baseMip, int mipCount, long handle) {
        super(texture, baseMip, mipCount);
        this.device = device;
        this.handle = handle;
    }

    public long handle() {
        return handle;
    }

    @Override
    public boolean isClosed() {
        return closed || texture().isClosed();
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (handle != 0L) {
            MetalNative.textureViewDestroy(device.handle(), handle);
            handle = 0L;
        }
    }
}
