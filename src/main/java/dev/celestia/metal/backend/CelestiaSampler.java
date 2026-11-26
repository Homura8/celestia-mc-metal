package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.textures.AddressMode;
import com.mojang.renderpearl.api.textures.FilterMode;
import com.mojang.renderpearl.api.textures.GpuSampler;
import java.util.OptionalDouble;

public final class CelestiaSampler implements GpuSampler {
    private final CelestiaMetalDevice device;
    private final AddressMode u;
    private final AddressMode v;
    private final FilterMode minFilter;
    private final FilterMode magFilter;
    private final int maxAnisotropy;
    private final OptionalDouble maxLod;
    private long handle;
    private boolean closed;

    CelestiaSampler(CelestiaMetalDevice device, AddressMode u, AddressMode v,
                    FilterMode minFilter, FilterMode magFilter,
                    int maxAnisotropy, OptionalDouble maxLod, long handle) {
        this.device = device;
        this.u = u;
        this.v = v;
        this.minFilter = minFilter;
        this.magFilter = magFilter;
        this.maxAnisotropy = maxAnisotropy;
        this.maxLod = maxLod != null ? maxLod : OptionalDouble.empty();
        this.handle = handle;
    }

    public long handle() {
        return handle;
    }

    @Override public AddressMode getAddressModeU() { return u; }
    @Override public AddressMode getAddressModeV() { return v; }
    @Override public FilterMode getMinFilter() { return minFilter; }
    @Override public FilterMode getMagFilter() { return magFilter; }
    @Override public int getMaxAnisotropy() { return maxAnisotropy; }
    @Override public OptionalDouble getMaxLod() { return maxLod; }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (handle != 0L) {
            MetalNative.samplerDestroy(device.handle(), handle);
            handle = 0L;
        }
    }
}
