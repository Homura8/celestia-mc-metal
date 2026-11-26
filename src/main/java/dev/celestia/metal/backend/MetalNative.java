package dev.celestia.metal.backend;

import java.io.IOException;
import java.io.InputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/**
 * Java 25 Foreign Function & Memory (FFM) bridge to {@code libcelestiametal.dylib}.
 */
public final class MetalNative {
    private static final String LIB_RESOURCE = "/natives/macos-arm64/libcelestiametal.dylib";
    private static final Linker LINKER = Linker.nativeLinker();

    private static volatile boolean loaded;
    private static volatile Throwable loadError;
    private static SymbolLookup lookup;

    public record ProbeInfo(
        boolean supported,
        boolean metal4Supported,
        int appleGpuFamily,
        int maxTextureSize,
        int maxAnisotropy,
        int maxRefreshRateHz,
        int thermalState,
        boolean lowPowerMode,
        float edrHeadroom,
        long recommendedMaxWorkingSetBytes,
        String gpuName,
        String unsupportedReason
    ) {}

    public record Telemetry(int thermalState, boolean lowPowerMode, int refreshHz, float edrHeadroom) {}

    private static final MemoryLayout PROBE_LAYOUT = MemoryLayout.structLayout(
        ValueLayout.JAVA_INT.withName("supported"),
        ValueLayout.JAVA_INT.withName("metal4Supported"),
        ValueLayout.JAVA_INT.withName("appleGpuFamily"),
        ValueLayout.JAVA_INT.withName("maxTextureSize"),
        ValueLayout.JAVA_INT.withName("maxAnisotropy"),
        ValueLayout.JAVA_INT.withName("maxRefreshRateHz"),
        ValueLayout.JAVA_INT.withName("thermalState"),
        ValueLayout.JAVA_INT.withName("lowPowerMode"),
        ValueLayout.JAVA_FLOAT.withName("edrHeadroom"),
        MemoryLayout.paddingLayout(4),
        ValueLayout.JAVA_LONG.withName("recommendedMaxWorkingSetBytes"),
        MemoryLayout.sequenceLayout(256, ValueLayout.JAVA_BYTE).withName("gpuName"),
        MemoryLayout.sequenceLayout(256, ValueLayout.JAVA_BYTE).withName("unsupportedReason")
    );

    private static MethodHandle mhAbiVersion;
    private static MethodHandle mhProbeDevice;
    private static MethodHandle mhQueryTelemetry;
    private static MethodHandle mhDeviceCreate;
    private static MethodHandle mhDeviceDestroy;
    private static MethodHandle mhDeviceIsMetal4;
    private static MethodHandle mhDeviceWaitIdle;

    private static MethodHandle mhBufferCreate;
    private static MethodHandle mhBufferDestroy;
    private static MethodHandle mhBufferWrite;

    private static MethodHandle mhTextureCreate;
    private static MethodHandle mhTextureDestroy;
    private static MethodHandle mhTextureViewCreate;
    private static MethodHandle mhSamplerCreate;
    private static MethodHandle mhSamplerDestroy;

    private static MethodHandle mhCompileMslLibrary;
    private static MethodHandle mhLibraryDestroy;
    private static MethodHandle mhCompileFunction;
    private static MethodHandle mhFunctionDestroy;
    private static MethodHandle mhRenderPipelineCreate;
    private static MethodHandle mhPipelineDestroy;
    private static MethodHandle mhComputePipelineCreate;
    private static MethodHandle mhComputePipelineDestroy;

    private static MethodHandle mhCmdBegin;


    private static MethodHandle mhSurfaceCreate;
    private static MethodHandle mhSurfaceDestroy;
    private static MethodHandle mhSurfaceConfigure;

    private static MethodHandle mhUpscalerCreate;
    private static MethodHandle mhUpscalerDestroy;
    private static MethodHandle mhUpscalerEncode;

    private static MethodHandle mhComputeDispatch;

    private static MethodHandle mhShadeSetEnabled;
    private static MethodHandle mhShadeSetGlobals;
    private static MethodHandle mhShadeSetResource;
    private static MethodHandle mhShadeFullscreenPass;
    private static MethodHandle mhShadeExposureRun;
    private static MethodHandle mhShadowRenderSodium;
    private static MethodHandle mhShadowRenderVanilla;
    private static MethodHandle mhWaterSetParams;
    private static MethodHandle mhWaterGenerateMipmaps;
    private static MethodHandle mhWaterCapture;
    private static MethodHandle mhBlitCopyTextureFull;

    private MetalNative() {}

    /**
     * Hot-path downcall handles held in {@code static final} fields so C2 can constant-fold and inline
     * {@code invokeExact}. Initialized lazily on first use, after {@link #load()} has bound the library.
     * Handles created with {@link Linker.Option#critical(boolean) critical(false)} skip the Java→native
     * thread-state transition; they are used only for short, non-blocking calls that never upcall into
     * Java and only receive native (off-heap) segments.
     */
    private static final class Hot {
        private static final ValueLayout.OfInt I = ValueLayout.JAVA_INT;
        private static final ValueLayout.OfLong L = ValueLayout.JAVA_LONG;
        private static final ValueLayout.OfFloat F = ValueLayout.JAVA_FLOAT;
        private static final ValueLayout.OfDouble D = ValueLayout.JAVA_DOUBLE;
        private static final ValueLayout P = ValueLayout.ADDRESS;

        static {
            load();
        }

        static final MethodHandle mhPassSetPipeline = downcallCritical("cm_pass_set_pipeline", FunctionDescriptor.ofVoid(L, L));
        static final MethodHandle mhPassSetScissor = downcallCritical("cm_pass_set_scissor", FunctionDescriptor.ofVoid(L, I, I, I, I, I));
        static final MethodHandle mhPassSetUniformBuffer = downcallCritical("cm_pass_set_uniform_buffer", FunctionDescriptor.ofVoid(L, I, L, L));
        static final MethodHandle mhPassSetTextureSampler = downcallCritical("cm_pass_set_texture_sampler", FunctionDescriptor.ofVoid(L, I, L, I, L));
        static final MethodHandle mhPassPushConstants = downcallCritical("cm_pass_push_constants", FunctionDescriptor.ofVoid(L, I, P, I));
        static final MethodHandle mhPassSetVertexBuffer = downcallCritical("cm_pass_set_vertex_buffer", FunctionDescriptor.ofVoid(L, I, L, L, I));
        static final MethodHandle mhPassSetIndexBuffer = downcallCritical("cm_pass_set_index_buffer", FunctionDescriptor.ofVoid(L, L, I));
        static final MethodHandle mhPassDraw = downcallCritical("cm_pass_draw", FunctionDescriptor.ofVoid(L, I, I, I, I, I));
        static final MethodHandle mhPassDrawIndexed = downcallCritical("cm_pass_draw_indexed", FunctionDescriptor.ofVoid(L, I, L, I, I, I, I, I));
        static final MethodHandle mhPassMultiDraw = downcallCritical("cm_pass_multi_draw", FunctionDescriptor.ofVoid(L, I, P, P, I, I, I));
        static final MethodHandle mhPassMultiDrawIndexed = downcallCritical("cm_pass_multi_draw_indexed", FunctionDescriptor.ofVoid(L, I, P, P, P, I, I, I));
        static final MethodHandle mhPassDrawIndirect = downcallCritical("cm_pass_draw_indirect", FunctionDescriptor.ofVoid(L, I, L, L, I, I, I));
        static final MethodHandle mhCmdHasActive = downcallCritical("cm_cmd_has_active", FunctionDescriptor.of(I, L));
        static final MethodHandle mhDeviceNextSubmit = downcallCritical("cm_device_next_submit", FunctionDescriptor.of(L, L));
        static final MethodHandle mhDeviceCompletedSubmit = downcallCritical("cm_device_completed_submit", FunctionDescriptor.of(L, L));
        static final MethodHandle mhDeviceLastGpuNs = downcallCritical("cm_device_last_gpu_ns", FunctionDescriptor.of(L, L));
        static final MethodHandle mhDeviceIsLost = downcallCritical("cm_device_is_lost", FunctionDescriptor.of(I, L));
        static final MethodHandle mhBufferContents = downcallCritical("cm_buffer_contents", FunctionDescriptor.of(L, L));
        static final MethodHandle mhPassBegin = downcall("cm_pass_begin", FunctionDescriptor.of(I, L, P, P, P, I, L, I, D, I, I, I, I, P));
        static final MethodHandle mhPassEnd = downcall("cm_pass_end", FunctionDescriptor.ofVoid(L));
        static final MethodHandle mhCmdSubmit = downcall("cm_cmd_submit", FunctionDescriptor.of(L, L, I));
        static final MethodHandle mhWaitSubmit = downcall("cm_wait_submit", FunctionDescriptor.of(I, L, L, L));
        static final MethodHandle mhBlitClearColor = downcall("cm_blit_clear_color", FunctionDescriptor.ofVoid(L, L, F, F, F, F));
        static final MethodHandle mhBlitClearDepth = downcall("cm_blit_clear_depth", FunctionDescriptor.ofVoid(L, L, D));
        static final MethodHandle mhBlitClearColorDepth = downcall("cm_blit_clear_color_depth", FunctionDescriptor.ofVoid(L, L, F, F, F, F, L, D));
        static final MethodHandle mhBlitCopyBuffer = downcall("cm_blit_copy_buffer", FunctionDescriptor.ofVoid(L, L, L, L, L, L));
        static final MethodHandle mhBlitCopyBufferToTexture = downcall("cm_blit_copy_buffer_to_texture", FunctionDescriptor.ofVoid(L, L, L, I, L, I, I, I, I, I, I));
        static final MethodHandle mhBlitCopyTextureToBuffer = downcall("cm_blit_copy_texture_to_buffer", FunctionDescriptor.ofVoid(L, L, I, I, I, I, I, I, L, L, I));
        static final MethodHandle mhBlitCopyTexture = downcall("cm_blit_copy_texture", FunctionDescriptor.ofVoid(L, L, I, I, I, I, L, I, I, I, I, I, I));
        static final MethodHandle mhBlitWriteTexture = downcall("cm_blit_write_texture", FunctionDescriptor.ofVoid(L, L, P, L, I, I, I, I, I, I, I));
        static final MethodHandle mhSurfaceAcquire = downcall("cm_surface_acquire", FunctionDescriptor.of(I, L));
        static final MethodHandle mhSurfaceBlitAndPresent = downcall("cm_surface_blit_and_present", FunctionDescriptor.ofVoid(L, L, L, I));
        static final MethodHandle mhDeviceDrainErrors = downcall("cm_device_drain_errors", FunctionDescriptor.of(I, L, P, I));
        static final MethodHandle mhTextureBufferCreate = downcall("cm_texture_buffer_create", FunctionDescriptor.of(L, L, L, L, L, I));
        static final MethodHandle mhTextureViewDestroy = downcall("cm_texture_view_destroy", FunctionDescriptor.ofVoid(L, L));
        static final MethodHandle mhPassFinish = downcallCritical("cm_pass_finish", FunctionDescriptor.ofVoid(L));
        static final MethodHandle mhPassMultiDrawPacked = downcallCritical("cm_pass_multi_draw_packed", FunctionDescriptor.ofVoid(L, I, P, I, I, I));
        static final MethodHandle mhPassMultiDrawIndexedPacked = downcallCritical("cm_pass_multi_draw_indexed_packed", FunctionDescriptor.ofVoid(L, I, P, I, L, I, I));
        static final MethodHandle mhDeviceStats = downcallCritical("cm_device_stats", FunctionDescriptor.ofVoid(L, P, I));
        static final MethodHandle mhDeviceSetOption = downcall("cm_device_set_option", FunctionDescriptor.ofVoid(L, I, I));
        static final MethodHandle mhUpscaleTo = downcall("cm_upscale_to", FunctionDescriptor.of(I, L, L, L, I));
        static final MethodHandle mhSurfaceSetNonblocking = downcall("cm_surface_set_nonblocking", FunctionDescriptor.ofVoid(L, I));

        private Hot() {}
    }

    public static synchronized void load() {
        if (loaded) return;
        if (loadError != null) {
            throw new IllegalStateException("Failed to load Celestia Metal native library", loadError);
        }
        try {
            Path dylib = extractLibrary();
            lookup = SymbolLookup.libraryLookup(dylib, Arena.global());
            bindHandles();
            int abi = (int) mhAbiVersion.invokeExact();
            if (abi != MetalConst.ABI_VERSION) {
                throw new IllegalStateException("ABI mismatch: expected " + MetalConst.ABI_VERSION + ", got " + abi);
            }
            loaded = true;
        } catch (Throwable t) {
            loadError = t;
            throw new IllegalStateException("Failed to load Celestia Metal native library", t);
        }
    }

    public static boolean isLoaded() {
        return loaded;
    }

    private static Path extractLibrary() throws IOException {
        Path cacheDir = Path.of(System.getProperty("java.io.tmpdir"), "celestia-metal-natives");
        Files.createDirectories(cacheDir);
        Path target = cacheDir.resolve("libcelestiametal-" + MetalConst.ABI_VERSION + ".dylib");
        try (InputStream in = MetalNative.class.getResourceAsStream(LIB_RESOURCE)) {
            if (in != null) {
                Path tmp = Files.createTempFile(cacheDir, "libcelestiametal-", ".tmp");
                Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
                Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING);
                return target;
            }
        }
        // Fallback for unit-test / dev-tree execution before processResources packaging
        Path devPath = Path.of("build/native/libcelestiametal.dylib");
        if (Files.exists(devPath)) return devPath.toAbsolutePath();
        throw new IOException("Bundled native library missing: " + LIB_RESOURCE);
    }

    private static MethodHandle downcall(String name, FunctionDescriptor desc) {
        MemorySegment sym = lookup.find(name).orElseThrow(() -> new UnsatisfiedLinkError("Missing symbol: " + name));
        return LINKER.downcallHandle(sym, desc);
    }

    private static MethodHandle downcallCritical(String name, FunctionDescriptor desc) {
        MemorySegment sym = lookup.find(name).orElseThrow(() -> new UnsatisfiedLinkError("Missing symbol: " + name));
        return LINKER.downcallHandle(sym, desc, Linker.Option.critical(false));
    }

    private static void bindHandles() {
        ValueLayout.OfInt I = ValueLayout.JAVA_INT;
        ValueLayout.OfLong L = ValueLayout.JAVA_LONG;
        ValueLayout.OfFloat F = ValueLayout.JAVA_FLOAT;
        ValueLayout.OfDouble D = ValueLayout.JAVA_DOUBLE;
        ValueLayout P = ValueLayout.ADDRESS;

        mhAbiVersion = downcall("cm_abi_version", FunctionDescriptor.of(I));
        mhProbeDevice = downcall("cm_probe_device", FunctionDescriptor.ofVoid(P));
        mhQueryTelemetry = downcall("cm_query_system_telemetry", FunctionDescriptor.ofVoid(P, P, P, P));
        mhDeviceCreate = downcall("cm_device_create", FunctionDescriptor.of(L, I, I, P));
        mhDeviceDestroy = downcall("cm_device_destroy", FunctionDescriptor.ofVoid(L));
        mhDeviceIsMetal4 = downcall("cm_device_is_metal4", FunctionDescriptor.of(I, L));
        mhDeviceWaitIdle = downcall("cm_device_wait_idle", FunctionDescriptor.ofVoid(L));

        mhBufferCreate = downcall("cm_buffer_create", FunctionDescriptor.of(L, L, L, P, P));
        mhBufferDestroy = downcall("cm_buffer_destroy", FunctionDescriptor.ofVoid(L, L));
        mhBufferWrite = downcall("cm_buffer_write", FunctionDescriptor.ofVoid(L, L, P, L));

        mhTextureCreate = downcall("cm_texture_create", FunctionDescriptor.of(L, L, I, I, I, I, I, I, I, I, I, P));
        mhTextureDestroy = downcall("cm_texture_destroy", FunctionDescriptor.ofVoid(L, L));
        mhTextureViewCreate = downcall("cm_texture_view_create", FunctionDescriptor.of(L, L, L, I, I));
        mhSamplerCreate = downcall("cm_sampler_create", FunctionDescriptor.of(L, L, I, I, I, I, I, I, I, I));
        mhSamplerDestroy = downcall("cm_sampler_destroy", FunctionDescriptor.ofVoid(L, L));

        mhCompileMslLibrary = downcall("cm_compile_msl_library", FunctionDescriptor.of(L, L, P, P, I, P, I));
        mhLibraryDestroy = downcall("cm_library_destroy", FunctionDescriptor.ofVoid(L));
        mhCompileFunction = downcall("cm_compile_function", FunctionDescriptor.of(L, L, P, I, I, I, P, I));
        mhFunctionDestroy = downcall("cm_function_destroy", FunctionDescriptor.ofVoid(L));
        mhRenderPipelineCreate = downcall("cm_render_pipeline_create", FunctionDescriptor.of(
            L, L, L, L, P, I, P, I, P, I, I, I, I, I, I, I, I, F, F, P, P, I));
        mhPipelineDestroy = downcall("cm_pipeline_destroy", FunctionDescriptor.ofVoid(L, L));
        mhComputePipelineCreate = downcall("cm_compute_pipeline_create", FunctionDescriptor.of(L, L, L, P, P, I));
        mhComputePipelineDestroy = downcall("cm_compute_pipeline_destroy", FunctionDescriptor.ofVoid(L, L));

        mhCmdBegin = downcall("cm_cmd_begin", FunctionDescriptor.ofVoid(L));



        mhSurfaceCreate = downcall("cm_surface_create", FunctionDescriptor.of(L, L, L, I));
        mhSurfaceDestroy = downcall("cm_surface_destroy", FunctionDescriptor.ofVoid(L, L));
        mhSurfaceConfigure = downcall("cm_surface_configure", FunctionDescriptor.ofVoid(L, I, I, I, I));

        mhUpscalerCreate = downcall("cm_upscaler_create", FunctionDescriptor.of(L, L, I, I, I, I, I, I, I, I));
        mhUpscalerDestroy = downcall("cm_upscaler_destroy", FunctionDescriptor.ofVoid(L, L));
        mhUpscalerEncode = downcall("cm_upscaler_encode", FunctionDescriptor.ofVoid(L, L, L, L, L, L, F, F, I));

        mhComputeDispatch = downcall("cm_compute_dispatch", FunctionDescriptor.ofVoid(L, L, P, P, I, P, I, P, I, I, I, I, I, I, I));

        mhShadeSetEnabled = downcall("cm_shade_set_enabled", FunctionDescriptor.ofVoid(L, I));
        mhShadeSetGlobals = downcall("cm_shade_set_globals", FunctionDescriptor.ofVoid(L, L, L, L, L, L, L, L, L, L, L, L, L));
        mhShadeSetResource = downcall("cm_shade_set_resource", FunctionDescriptor.ofVoid(L, I, L));
        mhShadeFullscreenPass = downcall("cm_shade_fullscreen_pass", FunctionDescriptor.ofVoid(L, L, L, P, I, P, I, P, I));
        mhShadeExposureRun = downcall("cm_shade_exposure_run", FunctionDescriptor.ofVoid(L, L, L, L, L, L, L, L, I, I));
        mhShadowRenderSodium = downcall("cm_shadow_render_sodium", FunctionDescriptor.ofVoid(
            L, L, I, I, L, L, P, I, L, L, L, L, P, I, L, L, F, F, I));
        mhShadowRenderVanilla = downcall("cm_shadow_render_vanilla", FunctionDescriptor.ofVoid(
            L, L, I, I, L, L, P, I, P, I, L, L, F, F, I));
        mhWaterSetParams = downcall("cm_water_set_params", FunctionDescriptor.ofVoid(L, L, L, L, L, I));
        mhWaterGenerateMipmaps = downcall("cm_water_generate_mipmaps", FunctionDescriptor.ofVoid(L, L, L, L));
        mhWaterCapture = downcall("cm_water_capture", FunctionDescriptor.of(I, L, L, L));
        mhBlitCopyTextureFull = downcall("cm_blit_copy_texture_full", FunctionDescriptor.ofVoid(L, L, L));
    }

    public static ProbeInfo probeDevice() {
        load();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocate(PROBE_LAYOUT);
            mhProbeDevice.invokeExact(seg);
            boolean supported = seg.get(ValueLayout.JAVA_INT, 0) != 0;
            boolean metal4 = seg.get(ValueLayout.JAVA_INT, 4) != 0;
            int family = seg.get(ValueLayout.JAVA_INT, 8);
            int maxTex = seg.get(ValueLayout.JAVA_INT, 12);
            int maxAniso = seg.get(ValueLayout.JAVA_INT, 16);
            int hz = seg.get(ValueLayout.JAVA_INT, 20);
            int thermal = seg.get(ValueLayout.JAVA_INT, 24);
            boolean lpm = seg.get(ValueLayout.JAVA_INT, 28) != 0;
            float edr = seg.get(ValueLayout.JAVA_FLOAT, 32);
            long wss = seg.get(ValueLayout.JAVA_LONG, 40);
            String gpuName = seg.asSlice(48, 256).getString(0);
            String reason = seg.asSlice(304, 256).getString(0);
            return new ProbeInfo(supported, metal4, family, maxTex, maxAniso, hz, thermal, lpm, edr, wss, gpuName, reason);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public static Telemetry queryTelemetry() {
        if (!loaded) return new Telemetry(0, false, 60, 1.0f);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment t = arena.allocate(ValueLayout.JAVA_INT);
            MemorySegment l = arena.allocate(ValueLayout.JAVA_INT);
            MemorySegment h = arena.allocate(ValueLayout.JAVA_INT);
            MemorySegment e = arena.allocate(ValueLayout.JAVA_FLOAT);
            mhQueryTelemetry.invokeExact(t, l, h, e);
            return new Telemetry(t.get(ValueLayout.JAVA_INT, 0), l.get(ValueLayout.JAVA_INT, 0) != 0,
                h.get(ValueLayout.JAVA_INT, 0), e.get(ValueLayout.JAVA_FLOAT, 0));
        } catch (Throwable ex) {
            return new Telemetry(0, false, 60, 1.0f);
        }
    }

    public static long deviceCreate(boolean preferMetal4, boolean debugLabels, String archivePath) {
        load();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment p = archivePath != null ? arena.allocateFrom(archivePath) : MemorySegment.NULL;
            return (long) mhDeviceCreate.invokeExact(preferMetal4 ? 1 : 0, debugLabels ? 1 : 0, p);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public static void deviceDestroy(long ctx) {
        try { mhDeviceDestroy.invokeExact(ctx); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static boolean deviceIsMetal4(long ctx) {
        try { return ((int) mhDeviceIsMetal4.invokeExact(ctx)) != 0; } catch (Throwable t) { return false; }
    }

    public static boolean deviceIsLost(long ctx) {
        try { return ((int) Hot.mhDeviceIsLost.invokeExact(ctx)) != 0; } catch (Throwable t) { return true; }
    }

    public static long deviceCompletedSubmit(long ctx) {
        try { return (long) Hot.mhDeviceCompletedSubmit.invokeExact(ctx); } catch (Throwable t) { return 0L; }
    }

    public static long deviceNextSubmit(long ctx) {
        try { return (long) Hot.mhDeviceNextSubmit.invokeExact(ctx); } catch (Throwable t) { return 0L; }
    }

    public static long deviceLastGpuNs(long ctx) {
        try { return (long) Hot.mhDeviceLastGpuNs.invokeExact(ctx); } catch (Throwable t) { return 0L; }
    }

    private static MemorySegment errorScratch;

    public static synchronized String deviceDrainErrors(long ctx) {
        try {
            if (errorScratch == null) errorScratch = Arena.global().allocate(4096);
            errorScratch.set(ValueLayout.JAVA_BYTE, 0, (byte) 0);
            int count = (int) Hot.mhDeviceDrainErrors.invokeExact(ctx, errorScratch, 4096);
            return count > 0 ? errorScratch.getString(0) : "";
        } catch (Throwable t) {
            return "";
        }
    }

    public static void deviceSetOption(long ctx, int option, int value) {
        try { Hot.mhDeviceSetOption.invokeExact(ctx, option, value); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Copies cumulative native encoder counters (see {@link MetalConst#STAT_COUNT}) into {@code out}. */
    public static void deviceStats(long ctx, MemorySegment out, int count) {
        try { Hot.mhDeviceStats.invokeExact(ctx, out, count); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void deviceWaitIdle(long ctx) {
        try { mhDeviceWaitIdle.invokeExact(ctx); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    private static MemorySegment segOrNull(MemorySegment seg) {
        return seg != null ? seg : MemorySegment.NULL;
    }

    public static long bufferCreate(long ctx, long sizeBytes, MemorySegment initialData, String label) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lbl = label != null ? arena.allocateFrom(label) : MemorySegment.NULL;
            return (long) mhBufferCreate.invokeExact(ctx, sizeBytes, segOrNull(initialData), lbl);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void bufferDestroy(long ctx, long buf) {
        try { mhBufferDestroy.invokeExact(ctx, buf); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long bufferContents(long buf) {
        try { return (long) Hot.mhBufferContents.invokeExact(buf); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void bufferWrite(long buf, long offset, MemorySegment src, long length) {
        try { mhBufferWrite.invokeExact(buf, offset, src, length); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long textureCreate(long ctx, int fmt, int w, int h, int layers, int mips,
                                     boolean cube, boolean rt, boolean read, boolean write, String label) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lbl = label != null ? arena.allocateFrom(label) : MemorySegment.NULL;
            return (long) mhTextureCreate.invokeExact(ctx, fmt, w, h, layers, mips,
                cube ? 1 : 0, rt ? 1 : 0, read ? 1 : 0, write ? 1 : 0, lbl);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void textureDestroy(long ctx, long tex) {
        try { mhTextureDestroy.invokeExact(ctx, tex); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long textureViewCreate(long ctx, long tex, int baseMip, int mipCount) {
        try { return (long) mhTextureViewCreate.invokeExact(ctx, tex, baseMip, mipCount); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long textureBufferCreate(long ctx, long buf, long offset, long lengthBytes, int format) {
        try { return (long) Hot.mhTextureBufferCreate.invokeExact(ctx, buf, offset, lengthBytes, format); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void textureViewDestroy(long ctx, long view) {
        try { Hot.mhTextureViewDestroy.invokeExact(ctx, view); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long samplerCreate(long ctx, int u, int v, int minF, int magF, int mipF,
                                     int aniso, boolean cmp, int cmpFunc) {
        try { return (long) mhSamplerCreate.invokeExact(ctx, u, v, minF, magF, mipF, aniso, cmp ? 1 : 0, cmpFunc); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void samplerDestroy(long ctx, long samp) {
        try { mhSamplerDestroy.invokeExact(ctx, samp); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long compileMslLibrary(long ctx, String mslSource, String label, boolean fastMath, StringBuilder errorOut) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment src = arena.allocateFrom(mslSource);
            MemorySegment lbl = label != null ? arena.allocateFrom(label) : MemorySegment.NULL;
            MemorySegment errBuf = arena.allocate(4096);
            long handle = (long) mhCompileMslLibrary.invokeExact(ctx, src, lbl, fastMath ? 1 : 0, errBuf, 4096);
            if (handle == 0L && errorOut != null) errorOut.append(errBuf.getString(0));
            return handle;
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void libraryDestroy(long lib) {
        try { mhLibraryDestroy.invokeExact(lib); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long compileFunction(long lib, String entryPoint, boolean hasConst, int constId, int constVal, StringBuilder errorOut) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment ep = arena.allocateFrom(entryPoint);
            MemorySegment errBuf = arena.allocate(2048);
            long handle = (long) mhCompileFunction.invokeExact(lib, ep, hasConst ? 1 : 0, constId, constVal, errBuf, 2048);
            if (handle == 0L && errorOut != null) errorOut.append(errBuf.getString(0));
            return handle;
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void functionDestroy(long fn) {
        try { mhFunctionDestroy.invokeExact(fn); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long renderPipelineCreate(long ctx, long vsFn, long fsFn,
                                            MemorySegment vtxBufs, int vtxBufCount,
                                            MemorySegment attribs, int attribCount,
                                            MemorySegment colors, int colorCount,
                                            int depthFmt, int topo, int polyMode,
                                            boolean cull, boolean depthTest, int depthCmp, boolean depthWrite,
                                            float biasSlope, float biasConst, String label, StringBuilder errorOut) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lbl = label != null ? arena.allocateFrom(label) : MemorySegment.NULL;
            MemorySegment errBuf = arena.allocate(4096);
            long h = (long) mhRenderPipelineCreate.invokeExact(
                ctx, vsFn, fsFn,
                segOrNull(vtxBufs), vtxBufCount,
                segOrNull(attribs), attribCount,
                segOrNull(colors), colorCount,
                depthFmt, topo, polyMode,
                cull ? 1 : 0, depthTest ? 1 : 0, depthCmp, depthWrite ? 1 : 0,
                biasSlope, biasConst, lbl, errBuf, 4096);
            if (h == 0L && errorOut != null) errorOut.append(errBuf.getString(0));
            return h;
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void pipelineDestroy(long ctx, long pipe) {
        try { mhPipelineDestroy.invokeExact(ctx, pipe); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long computePipelineCreate(long ctx, long csFn, String label, StringBuilder errorOut) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lbl = label != null ? arena.allocateFrom(label) : MemorySegment.NULL;
            MemorySegment errBuf = arena.allocate(2048);
            long h = (long) mhComputePipelineCreate.invokeExact(ctx, csFn, lbl, errBuf, 2048);
            if (h == 0L && errorOut != null) errorOut.append(errBuf.getString(0));
            return h;
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void computePipelineDestroy(long ctx, long pipe) {
        try { mhComputePipelineDestroy.invokeExact(ctx, pipe); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void cmdBegin(long ctx) {
        try { mhCmdBegin.invokeExact(ctx); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static boolean cmdHasActive(long ctx) {
        try { return ((int) Hot.mhCmdHasActive.invokeExact(ctx)) != 0; } catch (Throwable t) { return false; }
    }

    public static long cmdSubmit(long ctx, int maxInFlight) {
        try { return (long) Hot.mhCmdSubmit.invokeExact(ctx, maxInFlight); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static boolean waitSubmit(long ctx, long serial, long timeoutNs) {
        try { return ((int) Hot.mhWaitSubmit.invokeExact(ctx, serial, timeoutNs)) != 0; }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitClearColor(long ctx, long tex, float r, float g, float b, float a) {
        try { Hot.mhBlitClearColor.invokeExact(ctx, tex, r, g, b, a); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitClearDepth(long ctx, long tex, double depth) {
        try { Hot.mhBlitClearDepth.invokeExact(ctx, tex, depth); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitClearColorDepth(long ctx, long ctex, float r, float g, float b, float a, long dtex, double depth) {
        try { Hot.mhBlitClearColorDepth.invokeExact(ctx, ctex, r, g, b, a, dtex, depth); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitCopyBuffer(long ctx, long srcBuf, long srcOff, long dstBuf, long dstOff, long size) {
        try { Hot.mhBlitCopyBuffer.invokeExact(ctx, srcBuf, srcOff, dstBuf, dstOff, size); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitWriteTexture(long ctx, long tex, MemorySegment srcData, long dataSize,
                                        int rowStride, int mip, int slice, int x, int y, int w, int h) {
        try { Hot.mhBlitWriteTexture.invokeExact(ctx, tex, srcData, dataSize, rowStride, mip, slice, x, y, w, h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitCopyBufferToTexture(long ctx, long srcBuf, long srcOff, int rowBytes,
                                               long dstTex, int mip, int slice, int dstX, int dstY, int w, int h) {
        try { Hot.mhBlitCopyBufferToTexture.invokeExact(ctx, srcBuf, srcOff, rowBytes, dstTex, mip, slice, dstX, dstY, w, h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitCopyTextureToBuffer(long ctx, long srcTex, int mip, int slice, int srcX, int srcY,
                                               int w, int h, long dstBuf, long dstOff, int rowBytes) {
        try { Hot.mhBlitCopyTextureToBuffer.invokeExact(ctx, srcTex, mip, slice, srcX, srcY, w, h, dstBuf, dstOff, rowBytes); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitCopyTexture(long ctx, long srcTex, int srcMip, int srcSlice, int srcX, int srcY,
                                         long dstTex, int dstMip, int dstSlice, int dstX, int dstY, int w, int h) {
        try { Hot.mhBlitCopyTexture.invokeExact(ctx, srcTex, srcMip, srcSlice, srcX, srcY, dstTex, dstMip, dstSlice, dstX, dstY, w, h); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static boolean passBegin(long ctx, MemorySegment colorViews, MemorySegment colorClearsFlags,
                                    MemorySegment colorClearsRgba, int colorCount,
                                    long depthView, boolean depthClearFlag, double depthClear,
                                    int areaX, int areaY, int areaW, int areaH, String label) {
        if (label == null) {
            try {
                return ((int) Hot.mhPassBegin.invokeExact(ctx,
                    segOrNull(colorViews),
                    segOrNull(colorClearsFlags),
                    segOrNull(colorClearsRgba),
                    colorCount, depthView, depthClearFlag ? 1 : 0, depthClear,
                    areaX, areaY, areaW, areaH, MemorySegment.NULL)) != 0;
            } catch (Throwable t) { throw new RuntimeException(t); }
        }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lbl = arena.allocateFrom(label);
            return ((int) Hot.mhPassBegin.invokeExact(ctx,
                segOrNull(colorViews),
                segOrNull(colorClearsFlags),
                segOrNull(colorClearsRgba),
                colorCount, depthView, depthClearFlag ? 1 : 0, depthClear,
                areaX, areaY, areaW, areaH, lbl)) != 0;
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Hard end: always closes the native render encoder. */
    public static void passEnd(long ctx) {
        try { Hot.mhPassEnd.invokeExact(ctx); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Soft end used per RenderPearl pass: lets the next compatible pass merge into the open encoder. */
    public static void passFinish(long ctx) {
        try { Hot.mhPassFinish.invokeExact(ctx); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetPipeline(long ctx, long pipe) {
        try { Hot.mhPassSetPipeline.invokeExact(ctx, pipe); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetScissor(long ctx, boolean enabled, int x, int y, int w, int h) {
        try { Hot.mhPassSetScissor.invokeExact(ctx, enabled ? 1 : 0, x, y, w, h); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetUniformBuffer(long ctx, int slot, long buf, long offset) {
        try { Hot.mhPassSetUniformBuffer.invokeExact(ctx, slot, buf, offset); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetTextureSampler(long ctx, int texSlot, long view, int sampSlot, long samp) {
        try { Hot.mhPassSetTextureSampler.invokeExact(ctx, texSlot, view, sampSlot, samp); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passPushConstants(long ctx, int slot, MemorySegment data, int size) {
        try { Hot.mhPassPushConstants.invokeExact(ctx, slot, data, size); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetVertexBuffer(long ctx, int slot, long buf, long offset, int stride) {
        try { Hot.mhPassSetVertexBuffer.invokeExact(ctx, slot, buf, offset, stride); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passSetIndexBuffer(long ctx, long buf, boolean isInt32) {
        try { Hot.mhPassSetIndexBuffer.invokeExact(ctx, buf, isInt32 ? 1 : 0); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passDraw(long ctx, int topo, int vtxCount, int instCount, int firstVtx, int firstInst) {
        try { Hot.mhPassDraw.invokeExact(ctx, topo, vtxCount, instCount, firstVtx, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passDrawIndexed(long ctx, int topo, long idxBufOff, int idxCount, int instCount,
                                       int baseVtx, int firstIdx, int firstInst) {
        try { Hot.mhPassDrawIndexed.invokeExact(ctx, topo, idxBufOff, idxCount, instCount, baseVtx, firstIdx, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passMultiDraw(long ctx, int topo, MemorySegment firstVtx, MemorySegment vtxCounts,
                                     int count, int instCount, int firstInst) {
        try { Hot.mhPassMultiDraw.invokeExact(ctx, topo, firstVtx, vtxCounts, count, instCount, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passMultiDrawIndexed(long ctx, int topo, MemorySegment idxOffsets, MemorySegment idxCounts,
                                            MemorySegment baseVtx, int count, int instCount, int firstInst) {
        try { Hot.mhPassMultiDrawIndexed.invokeExact(ctx, topo, idxOffsets, idxCounts,
            segOrNull(baseVtx), count, instCount, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** {@code cmds} holds {@code count} interleaved {@code {firstVertex, vertexCount}} uint32 pairs (native memory). */
    public static void passMultiDrawPacked(long ctx, int topo, MemorySegment cmds, int count, int instCount, int firstInst) {
        try { Hot.mhPassMultiDrawPacked.invokeExact(ctx, topo, cmds, count, instCount, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** {@code cmds} holds {@code count} interleaved {@code {firstIndex, indexCount, vertexOffset}} triples (native memory). */
    public static void passMultiDrawIndexedPacked(long ctx, int topo, MemorySegment cmds, int count,
                                                  long indexBaseOffset, int instCount, int firstInst) {
        try { Hot.mhPassMultiDrawIndexedPacked.invokeExact(ctx, topo, cmds, count, indexBaseOffset, instCount, firstInst); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void passDrawIndirect(long ctx, int topo, long indBuf, long off, int count, int stride, boolean indexed) {
        try { Hot.mhPassDrawIndirect.invokeExact(ctx, topo, indBuf, off, count, stride, indexed ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long surfaceCreate(long ctx, long layerPtr, boolean hdr) {
        try { return (long) mhSurfaceCreate.invokeExact(ctx, layerPtr, hdr ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void surfaceDestroy(long ctx, long surf) {
        try { mhSurfaceDestroy.invokeExact(ctx, surf); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void surfaceConfigure(long surf, int w, int h, boolean vsync, boolean hdr) {
        try { mhSurfaceConfigure.invokeExact(surf, w, h, vsync ? 1 : 0, hdr ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static boolean surfaceAcquire(long surf) {
        try { return ((int) Hot.mhSurfaceAcquire.invokeExact(surf)) != 0; } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void surfaceBlitAndPresent(long ctx, long surf, long srcView, int maxInFlight) {
        try { Hot.mhSurfaceBlitAndPresent.invokeExact(ctx, surf, srcView, maxInFlight); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Upscales all of srcTex into dstTex. mode 0 = bilinear, 1 = MetalFX Spatial. Returns the mode used, -1 on error. */
    public static int upscaleTo(long ctx, long srcTex, long dstTex, int mode) {
        try { return (int) Hot.mhUpscaleTo.invokeExact(ctx, srcTex, dstTex, mode); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    /** Non-blocking (MAILBOX-style) presentation while VSync is off; see cm_surface_set_nonblocking. */
    public static void surfaceSetNonblocking(long surf, boolean enabled) {
        try { Hot.mhSurfaceSetNonblocking.invokeExact(surf, enabled ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static long upscalerCreate(long ctx, boolean temporal, int colorFmt, int outputFmt,
                                      int inW, int inH, int outW, int outH, boolean hdr) {
        try { return (long) mhUpscalerCreate.invokeExact(ctx, temporal ? 1 : 0, colorFmt, outputFmt,
            inW, inH, outW, outH, hdr ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void upscalerDestroy(long ctx, long upscaler) {
        try { mhUpscalerDestroy.invokeExact(ctx, upscaler); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void upscalerEncode(long ctx, long upscaler, long colorTex, long depthTex,
                                      long motionTex, long outTex, float jitterX, float jitterY, boolean resetHistory) {
        try { mhUpscalerEncode.invokeExact(ctx, upscaler, colorTex, depthTex, motionTex, outTex,
            jitterX, jitterY, resetHistory ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void computeDispatch(long ctx, long pipe, MemorySegment bufs, MemorySegment offs, int bufCount,
                                       MemorySegment texs, int texCount, MemorySegment samps, int sampCount,
                                       int gx, int gy, int gz, int tx, int ty, int tz) {
        try {
            mhComputeDispatch.invokeExact(ctx, pipe,
                segOrNull(bufs),
                segOrNull(offs), bufCount,
                segOrNull(texs), texCount,
                segOrNull(samps), sampCount,
                gx, gy, gz, tx, ty, tz);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadeSetEnabled(long ctx, boolean enabled) {
        try { mhShadeSetEnabled.invokeExact(ctx, enabled ? 1 : 0); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadeSetGlobals(long ctx,
                                       long frameBuf, long frameOffset,
                                       long lookBuf, long lookOffset,
                                       long gpuBuf, long gpuOffset,
                                       long resBuf, long resOffset,
                                       long shadowTex, long skyLutTex,
                                       long shadowSamp, long linearSamp) {
        try {
            mhShadeSetGlobals.invokeExact(ctx, frameBuf, frameOffset, lookBuf, lookOffset,
                gpuBuf, gpuOffset, resBuf, resOffset, shadowTex, skyLutTex, shadowSamp, linearSamp);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadeSetResource(long ctx, int slot, long texPtr) {
        try { mhShadeSetResource.invokeExact(ctx, slot, texPtr); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadeFullscreenPass(long ctx, long pso, long colorTex,
                                           MemorySegment texPtrs, int texCount,
                                           MemorySegment sampPtrs, int sampCount,
                                           MemorySegment pushData, int pushBytes) {
        try {
            mhShadeFullscreenPass.invokeExact(ctx, pso, colorTex,
                segOrNull(texPtrs), texCount,
                segOrNull(sampPtrs), sampCount,
                segOrNull(pushData), pushBytes);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadeExposureRun(long ctx, long histComputePso, long expComputePso,
                                        long srcTex, long gpuBuf, long gpuOffset,
                                        long lookBuf, long lookOffset, int gx, int gy) {
        try {
            mhShadeExposureRun.invokeExact(ctx, histComputePso, expComputePso, srcTex,
                gpuBuf, gpuOffset, lookBuf, lookOffset, gx, gy);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadowRenderSodium(long ctx, long shadowTex, int layer, int resolution,
                                          long solidPso, long cutoutPso,
                                          MemorySegment cascadeData, int cascadeBytes,
                                          long chunksBuf, long chunksOffset,
                                          long regionsBuf, long regionsOffset,
                                          MemorySegment draws, int drawCount,
                                          long atlasTex, long atlasSamp,
                                          float slopeScale, float clamp, boolean loadExisting) {
        try {
            mhShadowRenderSodium.invokeExact(ctx, shadowTex, layer, resolution, solidPso, cutoutPso,
                segOrNull(cascadeData), cascadeBytes, chunksBuf, chunksOffset, regionsBuf, regionsOffset,
                segOrNull(draws), drawCount, atlasTex, atlasSamp, slopeScale, clamp, loadExisting ? 1 : 0);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void shadowRenderVanilla(long ctx, long shadowTex, int layer, int resolution,
                                           long solidPso, long cutoutPso,
                                           MemorySegment cascadeData, int cascadeBytes,
                                           MemorySegment draws, int drawCount,
                                           long atlasTex, long atlasSamp,
                                           float slopeScale, float clamp, boolean loadExisting) {
        try {
            mhShadowRenderVanilla.invokeExact(ctx, shadowTex, layer, resolution, solidPso, cutoutPso,
                segOrNull(cascadeData), cascadeBytes, segOrNull(draws), drawCount,
                atlasTex, atlasSamp, slopeScale, clamp, loadExisting ? 1 : 0);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void waterSetParams(long ctx, long paramsBuf, long paramsOffset,
                                      long wavesTex, long detailTex, boolean enabled) {
        try {
            mhWaterSetParams.invokeExact(ctx, paramsBuf, paramsOffset, wavesTex, detailTex, enabled ? 1 : 0);
        } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void waterGenerateMipmaps(long ctx, long wavesTex, long detailTex, long swellTex) {
        try { mhWaterGenerateMipmaps.invokeExact(ctx, wavesTex, detailTex, swellTex); } catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static int waterCapture(long ctx, long pyrPso, long pyr2Pso) {
        try { return (int) mhWaterCapture.invokeExact(ctx, pyrPso, pyr2Pso); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }

    public static void blitCopyTextureFull(long ctx, long srcTex, long dstTex) {
        try { mhBlitCopyTextureFull.invokeExact(ctx, srcTex, dstTex); }
        catch (Throwable t) { throw new RuntimeException(t); }
    }
}
