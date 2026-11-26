package dev.celestia.metal.backend;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.device.BackendCreationException;
import com.mojang.renderpearl.api.device.GpuBackend;
import com.mojang.renderpearl.api.device.GpuDebugOptions;
import com.mojang.renderpearl.api.device.GpuDevice;
import com.mojang.renderpearl.frontend.FrontendGpuDevice;
import java.util.List;
import net.fabricmc.loader.api.FabricLoader;
import org.lwjgl.sdl.SDLVideo;
import org.slf4j.Logger;

/**
 * RenderPearl {@link GpuBackend} implementation for Apple Silicon Metal 4 / Metal 3.
 */
public final class CelestiaMetalBackend implements GpuBackend {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final List<String> INCOMPATIBLE_GL_MODS = List.of("iris", "voxy", "nvidium");

    private static volatile String cachedUnsupportedReason;
    private static volatile boolean reasonChecked;
    private static volatile MetalNative.ProbeInfo cachedProbe;

    public static synchronized String unsupportedReason() {
        if (reasonChecked) return cachedUnsupportedReason;
        reasonChecked = true;
        cachedUnsupportedReason = checkSupport();
        return cachedUnsupportedReason;
    }

    public static MetalNative.ProbeInfo probeInfo() {
        unsupportedReason();
        return cachedProbe;
    }

    private static String checkSupport() {
        if (Boolean.getBoolean("celestiametal.disable")) {
            return "disabled via -Dcelestiametal.disable=true";
        }
        String os = System.getProperty("os.name", "");
        String arch = System.getProperty("os.arch", "");
        if (!os.startsWith("Mac")) {
            return "not running on macOS";
        }
        if (!"aarch64".equals(arch)) {
            return "Java runtime is " + arch + " rather than arm64 (Apple Silicon requires ARM64 Java 25)";
        }
        if (!Boolean.getBoolean("celestiametal.ignoreIncompatibleMods")) {
            FabricLoader loader = FabricLoader.getInstance();
            for (String id : INCOMPATIBLE_GL_MODS) {
                var mod = loader.getModContainer(id);
                if (mod.isPresent()) {
                    return mod.get().getMetadata().getName() + " (" + id + ") requires OpenGL directly";
                }
            }
        }
        try {
            MetalNative.ProbeInfo probe = MetalNative.probeDevice();
            cachedProbe = probe;
            if (!probe.supported()) {
                return probe.unsupportedReason().isEmpty() ? "Apple7+ GPU not available" : probe.unsupportedReason();
            }
            return null;
        } catch (Throwable t) {
            LOGGER.warn("Failed to probe Metal device", t);
            return t.getMessage() != null ? t.getMessage() : t.getClass().getSimpleName();
        }
    }

    @Override
    public String getName() {
        return "Metal";
    }

    @Override
    public void loadLibrary() throws BackendCreationException {
        String reason = unsupportedReason();
        if (reason != null) {
            throw new BackendCreationException("Celestia Metal unavailable: " + reason,
                BackendCreationException.Reason.PLATFORM_ERROR);
        }
    }

    @Override
    public void unloadLibrary() {
        // Native library stays loaded for process lifetime.
    }

    @Override
    public long createWindow(String title, int width, int height, long monitorOrFlags) {
        long flags = SDLVideo.SDL_WINDOW_METAL | SDLVideo.SDL_WINDOW_RESIZABLE | SDLVideo.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        long win = SDLVideo.SDL_CreateWindow(title, width, height, flags);
        if (win == 0L) {
            throw new IllegalStateException("SDL_CreateWindow(SDL_WINDOW_METAL) failed");
        }
        return win;
    }

    @Override
    public GpuDevice createDevice(GpuDebugOptions debugOptions) throws BackendCreationException {
        String reason = unsupportedReason();
        if (reason != null) {
            throw new BackendCreationException("Celestia Metal unavailable: " + reason,
                BackendCreationException.Reason.PLATFORM_ERROR);
        }
        try {
            CelestiaMetalDevice device = new CelestiaMetalDevice(cachedProbe, debugOptions);
            return new FrontendGpuDevice(device);
        } catch (Throwable t) {
            throw new BackendCreationException("Failed to create Celestia Metal device: " + t.getMessage(),
                BackendCreationException.Reason.OTHER);
        }
    }
}
