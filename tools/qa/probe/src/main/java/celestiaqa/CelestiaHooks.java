package celestiaqa;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shade.light.ColorLights;
import dev.celestia.metal.shade.light.DynLights;
import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;

/**
 * Everything that touches Celestia Metal. Only called when the celestia-metal mod is loaded ({@link Qa#CELESTIA}), so the rest
 * of the probe also runs under other renderers (Iris + a reference pack). Java resolves these types lazily, on first call.
 */
final class CelestiaHooks {
    static final String NATIVE = "builtin:celestia-native";

    private CelestiaHooks() {}

    /** The next frame jumps to its exposure / atmosphere targets (CelestiaShade.requestSnap). */
    static void snap() {
        CelestiaShade s = CelestiaShade.current();
        if (s != null) s.requestSnap();
    }

    static void hidePerformanceHud() {
        CelestiaConfig.get().appleSilicon.performanceHud = CelestiaConfig.HudMode.OFF;
    }

    static boolean isMetal4() {
        var device = CelestiaMetalDevice.current;
        return device != null && device.isMetal4();
    }

    /** Last submitted frame's GPU time in ms, or -1. */
    static double gpuMs() {
        CelestiaMetalDevice d = CelestiaMetalDevice.current;
        return d == null ? -1 : MetalNative.deviceLastGpuNs(d.handle()) / 1e6;
    }

    static final String EXAMPLE_PACK = "user:celestia-example-world";

    static void refreshPacks() {
        ShaderPipelineManager.get().refreshPacks();
    }

    static String worldPack() {
        return dev.celestia.metal.shade.ShadeShaderPatcher.worldPackKey();
    }

    static void requireWorldReady(String step) {
        var shade = dev.celestia.metal.shade.CelestiaShade.current();
        if (shade == null || !shade.isReady() || !dev.celestia.metal.shade.CelestiaShade.isEnabled()) {
            throw new IllegalStateException("World renderer not ready after pack step " + step + " (" + worldPack() + ")");
        }
    }

    static void selectPack(String id) {
        ShaderPipelineManager.get().selectPack(id);
    }

    /** Apply all overrides together so one option change publishes the world settings once. */
    static void options(String kvs) {
        var manager = ShaderPipelineManager.get();
        var state = manager.optionState(manager.activePack()).copy();
        applyOverrides(state, kvs);
        manager.applyOptions(state);
    }

    static void presetWith(String preset, String kvs) {
        var manager = ShaderPipelineManager.get();
        if (manager.activePack() == null || !NATIVE.equals(manager.activePack().id)) manager.selectPack(NATIVE);
        var state = manager.optionState(manager.activePack()).copy();
        if (!state.manifest().presets.containsKey(preset)) throw new IllegalArgumentException("Unknown preset " + preset);
        state.applyPreset(preset);
        applyOverrides(state, kvs);
        manager.applyOptions(state);
    }

    private static void applyOverrides(ShaderOptionState state, String kvs) {
        if (kvs == null || kvs.isBlank()) return;
        for (String entry : kvs.split(",")) {
            String[] parts = entry.split("=", 2);
            if (parts.length != 2 || state.manifest().options.stream().noneMatch(option -> option.id().equals(parts[0].trim()))) {
                throw new IllegalArgumentException("Invalid shader option " + entry);
            }
            state.set(parts[0].trim(), parts[1].trim());
        }
    }

    static void debugView(int view) {
        CelestiaShade s = CelestiaShade.current();
        if (s != null) s.setDebugView(view);
    }

    static String status() {
        CelestiaShade s = CelestiaShade.current();
        return (s != null ? s.statusSummary() : "no shade") + " | dynLights " + DynLights.activeCount() + " | colourSlots "
            + ColorLights.activeSlots();
    }
}
