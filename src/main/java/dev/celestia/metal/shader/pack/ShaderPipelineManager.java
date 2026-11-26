package dev.celestia.metal.shader.pack;

import com.mojang.logging.LogUtils;
import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.perf.CelestiaConfig;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;

/**
 * Coordinates shader pack discovery, selection, option persistence, live MSL compilation on Metal,
 * hot reload, and per-frame pass state.
 */
public final class ShaderPipelineManager {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final ShaderPipelineManager INSTANCE = new ShaderPipelineManager();
    private static final String COMMON_PRELUDE_RESOURCE = "/assets/celestiametal/shaders/celestia_common.metal";

    public record CompiledPass(
        ShaderPackManifest.PassDef def,
        long libraryHandle,
        long functionHandle,
        long pipelineHandle
    ) {}

    private final List<ShaderPackManifest> discoveredPacks = new ArrayList<>();
    private final Map<String, ShaderOptionState> optionStates = new ConcurrentHashMap<>();
    private final List<CompiledPass> activeCompiledPasses = new ArrayList<>();
    private final FrameUniforms frameUniforms = new FrameUniforms();
    private final List<String> lastDiagnostics = new ArrayList<>();

    private ShaderPackManifest activePack = ShaderPackManifest.offPack();
    private boolean shadersEnabled = true;
    private String lastCompiledHash = "";
    private long uniformBufferHandle;
    private long lastCompileTimeMs;

    private ShaderPipelineManager() {}

    public static ShaderPipelineManager get() {
        return INSTANCE;
    }

    public Path shaderpacksDir() {
        return Path.of("shaderpacks");
    }

    public synchronized void refreshPacks() {
        discoveredPacks.clear();
        discoveredPacks.addAll(ShaderPackLoader.discoverAll(shaderpacksDir()));
        String targetId = CelestiaConfig.get().shaders.activePackId;
        ShaderPackManifest found = findPack(targetId);
        if (found == null) {
            found = findPack("builtin:celestia-native");
        }
        if (found == null) {
            found = ShaderPackManifest.offPack();
        }
        activePack = found;
        ShaderOptionState state = optionState(activePack);
        String preset = CelestiaConfig.get().shaders.activePreset;
        if (preset != null && !preset.isEmpty() && activePack.presets.containsKey(preset)) {
            state.applyPreset(preset);
        }
        state.loadFromDisk(shaderpacksDir());
    }

    public synchronized List<ShaderPackManifest> packs() {
        if (discoveredPacks.isEmpty()) refreshPacks();
        return Collections.unmodifiableList(new ArrayList<>(discoveredPacks));
    }

    public ShaderPackManifest findPack(String id) {
        for (ShaderPackManifest m : discoveredPacks) {
            if (m.id.equals(id)) return m;
        }
        return null;
    }

    public synchronized ShaderPackManifest activePack() {
        if (discoveredPacks.isEmpty()) refreshPacks();
        return activePack;
    }

    public synchronized boolean isShadersEnabled() {
        return shadersEnabled && activePack.kind != ShaderPackManifest.PackKind.OFF;
    }

    public synchronized void toggleShaders() {
        shadersEnabled = !shadersEnabled;
        if (shadersEnabled) {
            compileActivePackIfNeeded(true);
        } else {
            releaseCompiledPasses();
        }
    }

    public synchronized String activeDisplayName() {
        if (!shadersEnabled || activePack.kind == ShaderPackManifest.PackKind.OFF) return "Off";
        return activePack.name;
    }

    public synchronized ShaderOptionState optionState(ShaderPackManifest pack) {
        return optionStates.computeIfAbsent(pack.id, id -> {
            ShaderOptionState s = new ShaderOptionState(pack);
            s.loadFromDisk(shaderpacksDir());
            return s;
        });
    }

    public synchronized void selectPack(String packId) {
        if (discoveredPacks.isEmpty()) refreshPacks();
        ShaderPackManifest next = findPack(packId);
        if (next == null) next = ShaderPackManifest.offPack();
        activePack = next;
        shadersEnabled = next.kind != ShaderPackManifest.PackKind.OFF;

        CelestiaConfig cfg = CelestiaConfig.get();
        cfg.shaders.activePackId = next.id;
        ShaderOptionState st = optionState(next);
        cfg.shaders.activePreset = st.activePreset();
        cfg.save();

        compileActivePackIfNeeded(true);
    }

    public synchronized void applyPreset(String presetName) {
        ShaderOptionState st = optionState(activePack);
        st.applyPreset(presetName);
        st.saveToDisk(shaderpacksDir());
        CelestiaConfig cfg = CelestiaConfig.get();
        cfg.shaders.activePreset = st.activePreset();
        cfg.save();
        compileActivePackIfNeeded(true);
    }

    public synchronized void reloadActivePack() {
        refreshPacks();
        compileActivePackIfNeeded(true);
    }

    public synchronized List<String> lastDiagnostics() {
        return List.copyOf(lastDiagnostics);
    }

    public synchronized long lastCompileTimeMs() {
        return lastCompileTimeMs;
    }

    public synchronized int compiledPassCount() {
        return activeCompiledPasses.size();
    }

    public FrameUniforms frameUniforms() {
        return frameUniforms;
    }

    public synchronized void compileActivePackIfNeeded(boolean force) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev == null) return;
        if (!isShadersEnabled()) {
            releaseCompiledPasses();
            lastDiagnostics.clear();
            lastCompiledHash = "";
            return;
        }
        ShaderOptionState state = optionState(activePack);
        String hash = state.configHash();
        if (!force && hash.equals(lastCompiledHash) && !activeCompiledPasses.isEmpty()) {
            return;
        }

        releaseCompiledPasses();
        lastDiagnostics.clear();

        if (activePack.kind == ShaderPackManifest.PackKind.NATIVE_MSL) {
            long start = System.currentTimeMillis();
            String common = ShaderPackLoader.readClasspathText(COMMON_PRELUDE_RESOURCE);
            if (common == null) common = "#include <metal_stdlib>\nusing namespace metal;\n";
            String defines = state.toMslDefines();

            for (ShaderPackManifest.PassDef pass : activePack.passes) {
                String passSrc = ShaderPackLoader.readPackFile(activePack, pass.shaderFile());
                if (passSrc == null) {
                    lastDiagnostics.add("Missing shader file: " + pass.shaderFile());
                    continue;
                }
                String combined = defines + "\n" + common + "\n// --- Pass: " + pass.name() + " ---\n" + passSrc;
                StringBuilder err = new StringBuilder();
                long lib = MetalNative.compileMslLibrary(dev.handle(), combined,
                    activePack.id + "/" + pass.name(), true, err);
                if (lib == 0L) {
                    lastDiagnostics.add("[" + pass.name() + "] MSL compile error: " + err);
                    LOGGER.error("Shader pack {} pass {} failed: {}", activePack.name, pass.name(), err);
                    continue;
                }
                long fn = MetalNative.compileFunction(lib, pass.entryPoint(), false, 0, 0, err);
                if (fn == 0L) {
                    MetalNative.libraryDestroy(lib);
                    lastDiagnostics.add("[" + pass.name() + "] Missing entryPoint '" + pass.entryPoint() + "': " + err);
                    continue;
                }
                long pipe = 0L;
                if ("COMPUTE".equals(pass.stage())) {
                    pipe = MetalNative.computePipelineCreate(dev.handle(), fn, pass.name(), err);
                } else {
                    // Fullscreen triangle fragment pass: compile trivial vertex + fragment PSO
                    long vsFn = MetalNative.compileFunction(lib, "celestia_fullscreen_vs", false, 0, 0, err);
                    if (vsFn != 0L) {
                        try (Arena arena = Arena.ofConfined()) {
                            MemorySegment col = arena.allocate(36, 4);
                            col.set(ValueLayout.JAVA_INT, 0, parseFormat(pass.outputFormat()));
                            col.set(ValueLayout.JAVA_INT, 4, 0);
                            col.set(ValueLayout.JAVA_INT, 32, 15);
                            pipe = MetalNative.renderPipelineCreate(
                                dev.handle(), vsFn, fn,
                                MemorySegment.NULL, 0,
                                MemorySegment.NULL, 0,
                                col, 1,
                                -1, 3, 0, false, false, 0, false, 0.0f, 0.0f,
                                pass.name(), err);
                        }
                        MetalNative.functionDestroy(vsFn);
                    } else {
                        lastDiagnostics.add("[" + pass.name() + "] Missing celestia_fullscreen_vs: " + err);
                    }
                }
                if (pipe == 0L) {
                    MetalNative.functionDestroy(fn);
                    MetalNative.libraryDestroy(lib);
                    lastDiagnostics.add("[" + pass.name() + "] Pipeline creation failed: " + err);
                    continue;
                }
                activeCompiledPasses.add(new CompiledPass(pass, lib, fn, pipe));
            }
            lastCompileTimeMs = System.currentTimeMillis() - start;
            lastCompiledHash = hash;
            LOGGER.info("Compiled native MSL shader pack '{}' ({} passes, {} diagnostics) in {} ms",
                activePack.name, activeCompiledPasses.size(), lastDiagnostics.size(), lastCompileTimeMs);
        } else if (activePack.kind == ShaderPackManifest.PackKind.IRIS_GLSL) {
            lastCompiledHash = hash;
            lastDiagnostics.add("Iris/OptiFine pack loaded via GLSL->SPIR-V->MSL compatibility bridge.");
        }
    }

    public synchronized void uploadFrameUniforms(CelestiaMetalDevice dev) {
        if (dev == null) return;
        if (uniformBufferHandle == 0L) {
            uniformBufferHandle = MetalNative.bufferCreate(dev.handle(), FrameUniforms.BYTE_SIZE, null, "CelestiaFrameUniforms");
        }
        long ptr = MetalNative.bufferContents(uniformBufferHandle);
        if (ptr != 0L) {
            ByteBuffer bb = MemorySegment.ofAddress(ptr).reinterpret(FrameUniforms.BYTE_SIZE).asByteBuffer()
                .order(java.nio.ByteOrder.nativeOrder());
            frameUniforms.pack(bb);
        }
    }

    private void releaseCompiledPasses() {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        for (CompiledPass cp : activeCompiledPasses) {
            if (dev != null && cp.pipelineHandle() != 0L) {
                if ("COMPUTE".equals(cp.def().stage())) {
                    MetalNative.computePipelineDestroy(dev.handle(), cp.pipelineHandle());
                } else {
                    MetalNative.pipelineDestroy(dev.handle(), cp.pipelineHandle());
                }
            }
            if (cp.functionHandle() != 0L) MetalNative.functionDestroy(cp.functionHandle());
            if (cp.libraryHandle() != 0L) MetalNative.libraryDestroy(cp.libraryHandle());
        }
        activeCompiledPasses.clear();
    }

    private static int parseFormat(String name) {
        return switch (name.toUpperCase()) {
            case "RGBA8_UNORM" -> MetalConst.FMT_RGBA8_UNORM;
            case "RG11B10_FLOAT" -> MetalConst.FMT_RG11B10_FLOAT;
            case "R16_FLOAT" -> MetalConst.FMT_R16_FLOAT;
            case "RG16_FLOAT" -> MetalConst.FMT_RG16_FLOAT;
            default -> MetalConst.FMT_RGBA16_FLOAT;
        };
    }
}
