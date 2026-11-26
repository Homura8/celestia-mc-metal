package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.device.GpuSurface;
import com.mojang.renderpearl.api.device.SurfaceException;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import com.mojang.renderpearl.backend.api.CommandEncoderBackend;
import com.mojang.renderpearl.backend.api.GpuSurfaceBackend;
import dev.celestia.metal.perf.CelestiaConfig;
import java.util.Collection;
import java.util.EnumSet;
import java.util.Set;
import java.util.function.BooleanSupplier;
import org.lwjgl.sdl.SDLMetal;

public final class CelestiaSurface implements GpuSurfaceBackend {
    private static final Set<GpuSurface.PresentMode> SUPPORTED_MODES = EnumSet.of(
        GpuSurface.PresentMode.FIFO,
        GpuSurface.PresentMode.IMMEDIATE,
        GpuSurface.PresentMode.MAILBOX
    );

    private final CelestiaMetalDevice device;
    private final long windowHandle;
    private final BooleanSupplier windowClosed;
    private final long metalView;
    private long surfaceHandle;
    private int width = 1;
    private int height = 1;
    private boolean vsync = true;
    private boolean hdrEnabled;
    private boolean closed;
    private int appliedNonBlocking = -1;
    private static final boolean FORCE_BLOCKING_PRESENT = Boolean.getBoolean("celestiametal.blockingPresent");

    CelestiaSurface(CelestiaMetalDevice device, long windowHandle, BooleanSupplier windowClosed) {
        this.device = device;
        this.windowHandle = windowHandle;
        this.windowClosed = windowClosed;
        this.metalView = SDLMetal.SDL_Metal_CreateView(windowHandle);
        if (this.metalView == 0L) {
            throw new IllegalStateException("SDL_Metal_CreateView failed for window " + windowHandle);
        }
        long layerPtr = SDLMetal.SDL_Metal_GetLayer(this.metalView);
        if (layerPtr == 0L) {
            SDLMetal.SDL_Metal_DestroyView(this.metalView);
            throw new IllegalStateException("SDL_Metal_GetLayer returned null");
        }
        this.hdrEnabled = CelestiaConfig.get().appleSilicon.hdrEnabled;
        this.surfaceHandle = MetalNative.surfaceCreate(device.handle(), layerPtr, this.hdrEnabled);
        if (this.surfaceHandle == 0L) {
            SDLMetal.SDL_Metal_DestroyView(this.metalView);
            throw new IllegalStateException("cm_surface_create failed");
        }
    }

    @Override
    public void configure(GpuSurface.Configuration config) throws SurfaceException {
        if (closed || windowClosed.getAsBoolean()) return;
        this.width = Math.max(1, config.width());
        this.height = Math.max(1, config.height());
        this.vsync = config.presentMode() == GpuSurface.PresentMode.FIFO
            || config.presentMode() == GpuSurface.PresentMode.FIFO_RELAXED;
        this.hdrEnabled = CelestiaConfig.get().appleSilicon.hdrEnabled;
        applyPresentMode();
        MetalNative.surfaceConfigure(surfaceHandle, width, height, vsync, hdrEnabled);
    }

    /** Pushes the non-blocking present setting to the native surface when it changes (checked once per frame). */
    private void applyPresentMode() {
        int nonBlocking = CelestiaConfig.get().appleSilicon.nonBlockingPresent && !FORCE_BLOCKING_PRESENT ? 1 : 0;
        if (nonBlocking != appliedNonBlocking && surfaceHandle != 0L) {
            MetalNative.surfaceSetNonblocking(surfaceHandle, nonBlocking != 0);
            appliedNonBlocking = nonBlocking;
        }
    }

    @Override
    public boolean isSuboptimal() {
        return false;
    }

    @Override
    public void acquireNextTexture() throws SurfaceException {
        if (closed || windowClosed.getAsBoolean()) return;
        boolean ok = MetalNative.surfaceAcquire(surfaceHandle);
        if (!ok) {
            throw new SurfaceException("CAMetalLayer nextDrawable returned null");
        }
    }

    @Override
    public void blitFromTexture(CommandEncoderBackend encoder, GpuTextureView view) {
        if (closed || !(view instanceof CelestiaTextureView ctv)) return;
        int maxInFlight = CelestiaConfig.get().appleSilicon.lowLatencyQueue ? 2 : 3;
        applyPresentMode();
        MetalNative.surfaceBlitAndPresent(device.handle(), surfaceHandle, ctv.handle(), maxInFlight);
        if (encoder instanceof CelestiaCommandEncoder cce) {
            cce.onPresentedBySurface();
        }
    }

    @Override
    public void present() {
        // Presentation is committed together with the blit pass in surfaceBlitAndPresent.
    }

    @Override
    public Collection<GpuSurface.PresentMode> supportedPresentModes() {
        return SUPPORTED_MODES;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        if (surfaceHandle != 0L) {
            MetalNative.surfaceDestroy(device.handle(), surfaceHandle);
            surfaceHandle = 0L;
        }
        if (metalView != 0L) {
            SDLMetal.SDL_Metal_DestroyView(metalView);
        }
    }
}
