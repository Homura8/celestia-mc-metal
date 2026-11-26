package dev.celestia.metal.backend;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.device.DeviceFeatures;
import com.mojang.renderpearl.api.device.DeviceInfo;
import com.mojang.renderpearl.api.device.DeviceLimits;
import com.mojang.renderpearl.api.device.DeviceType;
import com.mojang.renderpearl.api.device.GpuDebugOptions;
import com.mojang.renderpearl.api.device.HintsAndWorkarounds;
import com.mojang.renderpearl.api.textures.AddressMode;
import com.mojang.renderpearl.api.textures.FilterMode;
import com.mojang.renderpearl.api.textures.GpuSampler;
import com.mojang.renderpearl.api.textures.GpuTexture;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.GpuDeviceBackend;
import com.mojang.renderpearl.backend.api.GpuSurfaceBackend;
import dev.celestia.metal.perf.CelestiaConfig;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.OptionalDouble;
import java.util.Set;
import java.util.function.BooleanSupplier;
import java.util.function.Supplier;
import org.slf4j.Logger;

public final class CelestiaMetalDevice implements GpuDeviceBackend {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final long POOL_CAP_BYTES = 256L << 20;
    private static final long POOL_MAX_BUFFER_BYTES = 32L << 20;

    public static volatile CelestiaMetalDevice current;

    private record PooledBuffer(long handle, long completedWhenAfter) {}
    private record SamplerKey(AddressMode u, AddressMode v, FilterMode min, FilterMode mag, int aniso, OptionalDouble lodBias) {}

    private final long handle;
    private final boolean metal4;
    private final boolean debugLabels;
    private final DeviceInfo deviceInfo;
    private final MetalNative.ProbeInfo probeInfo;
    private final CelestiaCommandEncoder commandEncoder;
    private final Map<Long, ArrayDeque<PooledBuffer>> bufferPool = new HashMap<>();
    private final Map<SamplerKey, CelestiaSampler> samplerCache = new HashMap<>();
    private long bufferPoolBytes;
    private boolean closed;

    CelestiaMetalDevice(MetalNative.ProbeInfo probe, GpuDebugOptions debugOptions) {
        CelestiaConfig cfg = CelestiaConfig.get();
        boolean preferMetal4 = switch (cfg.appleSilicon.metalMode) {
            case METAL_3 -> false;
            case AUTO_METAL_4, METAL_4 -> true;
        };
        String archivePath = cfg.shaders.binaryPipelineCache
            ? Path.of("config", "celestia-metal-pipelines.metallibcache").toAbsolutePath().toString()
            : "";

        this.probeInfo = probe;
        this.debugLabels = debugOptions != null && debugOptions.useLabels();
        this.handle = MetalNative.deviceCreate(preferMetal4, this.debugLabels, archivePath);
        if (this.handle == 0L) {
            throw new IllegalStateException("Failed to initialize Metal device");
        }
        this.metal4 = MetalNative.deviceIsMetal4(this.handle);
        applyEncoderOptions();
        this.commandEncoder = new CelestiaCommandEncoder(this);

        DeviceLimits limits = new DeviceLimits(
            probe.maxAnisotropy(),
            256,
            probe.maxTextureSize(),
            probe.recommendedMaxWorkingSetBytes(),
            65536,
            8,
            65536
        );
        DeviceFeatures features = new DeviceFeatures(
            true,  // wireframeFillMode
            true,  // shaderDrawParameters
            true,  // multiDrawDirectInterleaved
            true,  // multiDrawDirectSeparate
            true,  // multiDrawIndirect
            true,  // drawIndirect
            true,  // nonZeroFirstInstance
            true   // persistentMapping
        );
        HintsAndWorkarounds hints = new HintsAndWorkarounds(
            false, // writeToBufferIsSlow (unified memory!)
            false, // anisotropyHasKnownIssues
            true,  // isExplicitDepthRequired
            false  // multiDrawIndirectHasKnownIssues
        );
        String apiName = this.metal4 ? "Metal 4 (Celestia Metal)" : "Metal 3 (Celestia Metal)";
        this.deviceInfo = new DeviceInfo(
            probe.gpuName(),
            "Apple",
            "Apple" + probe.appleGpuFamily() + " / " + (this.metal4 ? "Metal 4" : "Metal 3"),
            true,
            apiName,
            1.0f,
            limits,
            features,
            Set.of("metal_unified_memory", this.metal4 ? "metal_4" : "metal_3", "metalfx"),
            hints,
            DeviceType.INTEGRATED
        );
        current = this;
        LOGGER.info("Initialized Celestia Metal device: {} ({}, {} Hz, EDR {}x)",
            probe.gpuName(), apiName, probe.maxRefreshRateHz(), String.format("%.2f", probe.edrHeadroom()));
    }

    public long handle() {
        return handle;
    }

    public boolean isMetal4() {
        return metal4;
    }

    public MetalNative.ProbeInfo probeInfo() {
        return probeInfo;
    }

    private static long bucketSize(long size) {
        long s = Math.max(256L, size);
        long p = Long.highestOneBit(s - 1L) << 1;
        return p > 0 ? p : s;
    }

    CelestiaBuffer createBufferInternal(String label, int usage, long size) {
        long aligned = bucketSize(size);
        long pooledHandle = 0L;
        if (aligned <= POOL_MAX_BUFFER_BYTES && CelestiaConfig.get().performance.bufferPooling) {
            long completed = MetalNative.deviceCompletedSubmit(handle);
            synchronized (bufferPool) {
                ArrayDeque<PooledBuffer> q = bufferPool.get(aligned);
                if (q != null && !q.isEmpty() && q.peekFirst().completedWhenAfter() <= completed) {
                    pooledHandle = q.pollFirst().handle();
                    bufferPoolBytes -= aligned;
                }
            }
        }
        if (pooledHandle == 0L) {
            pooledHandle = MetalNative.bufferCreate(handle, aligned, null, label);
            if (pooledHandle == 0L) {
                throw new OutOfMemoryError("Failed to allocate Metal buffer of size " + aligned);
            }
        }
        return new CelestiaBuffer(this, usage, size, pooledHandle, aligned <= POOL_MAX_BUFFER_BYTES);
    }

    void recycleBuffer(long bufHandle, long requestedSize) {
        if (closed || bufHandle == 0L) {
            if (bufHandle != 0L) MetalNative.bufferDestroy(handle, bufHandle);
            return;
        }
        long aligned = bucketSize(requestedSize);
        if (aligned > POOL_MAX_BUFFER_BYTES || !CelestiaConfig.get().performance.bufferPooling) {
            MetalNative.bufferDestroy(handle, bufHandle);
            return;
        }
        long waitUntil = MetalNative.deviceNextSubmit(handle) + 1L;
        synchronized (bufferPool) {
            if (bufferPoolBytes + aligned > POOL_CAP_BYTES) {
                MetalNative.bufferDestroy(handle, bufHandle);
                return;
            }
            bufferPool.computeIfAbsent(aligned, k -> new ArrayDeque<>())
                .addLast(new PooledBuffer(bufHandle, waitUntil));
            bufferPoolBytes += aligned;
        }
    }

    @Override
    public GpuSurfaceBackend createSurface(long windowHandle, BooleanSupplier windowClosed) {
        return new CelestiaSurface(this, windowHandle, windowClosed);
    }

    @Override
    public CommandEncoderBackend createCommandEncoder() {
        return commandEncoder;
    }

    @Override
    public GpuSampler createSampler(AddressMode u, AddressMode v, FilterMode min, FilterMode mag,
                                    int maxAnisotropy, OptionalDouble maxLod) {
        SamplerKey key = new SamplerKey(u, v, min, mag, maxAnisotropy, maxLod);
        synchronized (samplerCache) {
            CelestiaSampler cached = samplerCache.get(key);
            if (cached != null && !cached.isClosed()) return cached;
            int addrU = u == AddressMode.REPEAT ? 0 : 1;
            int addrV = v == AddressMode.REPEAT ? 0 : 1;
            int minF = min == FilterMode.LINEAR ? 1 : 0;
            int magF = mag == FilterMode.LINEAR ? 1 : 0;
            int mipF = 2; // linear mipmap filtering
            long h = MetalNative.samplerCreate(handle, addrU, addrV, minF, magF, mipF, maxAnisotropy, false, 0);
            CelestiaSampler s = new CelestiaSampler(this, u, v, min, mag, maxAnisotropy, maxLod, h);
            samplerCache.put(key, s);
            return s;
        }
    }

    @Override
    public GpuTexture createTexture(String label, int usage, GpuFormat format, int width, int height,
                                    int depthOrLayers, int mipLevels) {
        int nativeFmt = MetalConst.toNativeFormat(format);
        boolean isCube = (usage & GpuTexture.USAGE_CUBEMAP_COMPATIBLE) != 0;
        boolean isRt = (usage & GpuTexture.USAGE_RENDER_ATTACHMENT) != 0;
        boolean isRead = (usage & GpuTexture.USAGE_TEXTURE_BINDING) != 0 || isRt;
        long h = MetalNative.textureCreate(handle, nativeFmt, width, height, depthOrLayers, mipLevels,
            isCube, isRt, isRead, false, label);
        if (h == 0L) {
            throw new IllegalStateException("Failed to create Metal texture " + label + " (" + format + " " + width + "x" + height + ")");
        }
        return new CelestiaTexture(this, usage, label, format, width, height, depthOrLayers, mipLevels, h);
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture texture, int baseMipLevel, int mipLevels) {
        CelestiaTexture ct = (CelestiaTexture) texture;
        long h = MetalNative.textureViewCreate(handle, ct.handle(), baseMipLevel, mipLevels);
        return new CelestiaTextureView(this, texture, baseMipLevel, mipLevels, h);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, long size) {
        String lbl = label != null ? label.get() : null;
        return createBufferInternal(lbl, usage, size);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, ByteBuffer data) {
        String lbl = label != null ? label.get() : null;
        int len = data.remaining();
        if (len <= 0) return createBufferInternal(lbl, usage, 16L);
        CelestiaBuffer buf = createBufferInternal(lbl, usage, len);
        if (data.isDirect()) {
            MetalNative.bufferWrite(buf.handle(), 0L, MemorySegment.ofBuffer(data), len);
        } else {
            try (Arena arena = Arena.ofConfined()) {
                byte[] tmp = new byte[len];
                data.duplicate().get(tmp);
                MemorySegment seg = arena.allocate(len);
                MemorySegment.copy(tmp, 0, seg, java.lang.foreign.ValueLayout.JAVA_BYTE, 0, len);
                MetalNative.bufferWrite(buf.handle(), 0L, seg, len);
            }
        }
        return buf;
    }

    @Override
    public List<String> getLastDebugMessages() {
        String drained = MetalNative.deviceDrainErrors(handle);
        if (drained.isEmpty()) return List.of();
        return List.of(drained.split("\n"));
    }

    // -D switches force the optimizations off regardless of config (for A/B comparison and bisecting).
    private static final boolean FORCE_NO_PASS_MERGE = Boolean.getBoolean("celestiametal.noPassMerge");
    private static final boolean FORCE_NO_DEFER_CLEARS = Boolean.getBoolean("celestiametal.noDeferClears");
    private int appliedPassMerge = -1;
    private int appliedDeferClears = -1;

    /**
     * Pushes the render pass merging / deferred clear settings to the native encoder when they change.
     * Called once per presented frame so toggling them in the settings screen takes effect immediately.
     */
    void applyEncoderOptions() {
        CelestiaConfig.PerformanceSection perf = CelestiaConfig.get().performance;
        int merge = perf.renderPassMerging && !FORCE_NO_PASS_MERGE ? 1 : 0;
        int defer = perf.deferredClears && !FORCE_NO_DEFER_CLEARS ? 1 : 0;
        if (merge != appliedPassMerge) {
            MetalNative.deviceSetOption(handle, MetalConst.OPT_PASS_MERGE, merge);
            appliedPassMerge = merge;
        }
        if (defer != appliedDeferClears) {
            MetalNative.deviceSetOption(handle, MetalConst.OPT_DEFER_CLEARS, defer);
            appliedDeferClears = defer;
        }
    }

    /** Blocks until every queued GPU write into {@code buffer} has executed (see {@link CelestiaBuffer#map}). */
    void awaitGpuWrites(CelestiaBuffer buffer) {
        commandEncoder.awaitSerial(buffer.pendingGpuWriteSerial());
    }

    /** Milliseconds per second blocked on {in-flight frame cap, fences, present slots}. */
    public double[] waitRates() {
        return commandEncoder.waitRates();
    }

    /** {frames submitted, shown on screen, dropped} per second (non-blocking present path reports shown/dropped). */
    public long[] presentRates() {
        return commandEncoder.presentRates();
    }

    /** Native encoder counters for the most recently presented frame (see {@code MetalConst.STAT_*}). */
    public long[] lastFrameStats() {
        return commandEncoder.lastFrameStats();
    }

    @Override
    public boolean isDebuggingEnabled() {
        return debugLabels;
    }

    @Override
    public BackendRenderPipeline.Pending compilePipeline(BackendRenderPipeline.CreateInfo info) {
        return CelestiaPipeline.compileAsync(this, info);
    }

    @Override
    public GpuQueryPool createTimestampQueryPool(int size) {
        return new CelestiaQueryPool(size);
    }

    @Override
    public long getTimestampCalibrationOffset() {
        return 0L;
    }

    @Override
    public DeviceInfo getDeviceInfo() {
        return deviceInfo;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (current == this) current = null;
        commandEncoder.close();
        synchronized (samplerCache) {
            for (CelestiaSampler s : samplerCache.values()) {
                s.close();
            }
            samplerCache.clear();
        }
        synchronized (bufferPool) {
            for (ArrayDeque<PooledBuffer> q : bufferPool.values()) {
                while (!q.isEmpty()) {
                    MetalNative.bufferDestroy(handle, q.pollFirst().handle());
                }
            }
            bufferPool.clear();
            bufferPoolBytes = 0L;
        }
        MetalNative.deviceDestroy(handle);
    }
}
