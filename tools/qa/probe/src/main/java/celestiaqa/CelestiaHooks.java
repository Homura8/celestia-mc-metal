package celestiaqa;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalNative;
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

    /** Last submitted frame's GPU time in ms, or -1. */
    static double gpuMs() {
        CelestiaMetalDevice d = CelestiaMetalDevice.current;
        return d == null ? -1 : MetalNative.deviceLastGpuNs(d.handle()) / 1e6;
    }

    static void selectPack(String id) {
        ShaderPipelineManager.get().selectPack(id);
    }

    static void preset(String name) {
        ShaderPipelineManager m = ShaderPipelineManager.get();
        if (m.activePack() == null || !NATIVE.equals(m.activePack().id)) m.selectPack(NATIVE);
        m.applyPreset(name);
    }

    /** KEY=VALUE[,KEY=VALUE...] on top of the current option state. */
    static void options(String kvs) {
        if (kvs == null || kvs.isEmpty()) return;
        ShaderPipelineManager m = ShaderPipelineManager.get();
        ShaderOptionState st = m.optionState(m.activePack()).copy();
        for (String kv : kvs.split(",")) {
            String[] p = kv.split("=", 2);
            if (p.length == 2) st.set(p[0].trim(), p[1].trim());
        }
        m.applyOptions(st);
    }

    /** A preset, then option overrides (null for none). */
    static void presetWith(String preset, String kvs) {
        preset(preset);
        options(kvs);
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
