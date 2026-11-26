package dev.celestia.metal;

import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPackLoader;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class ShaderManifestTest {

    @Test
    void discoversBuiltinNativePacks() {
        List<ShaderPackManifest> packs = ShaderPackLoader.discoverAll(null);
        assertTrue(packs.stream().anyMatch(p -> "off".equals(p.id)));
        assertTrue(packs.stream().anyMatch(p -> "builtin:celestia-native".equals(p.id)));
        assertTrue(packs.stream().anyMatch(p -> "builtin:celestia-minimal".equals(p.id)));

        ShaderPackManifest nativePack = packs.stream()
            .filter(p -> "builtin:celestia-native".equals(p.id))
            .findFirst()
            .orElseThrow();

        assertEquals(ShaderPackManifest.PackKind.NATIVE_MSL, nativePack.kind);
        assertEquals(4, nativePack.presets.size());
        assertTrue(nativePack.options.size() >= 18);
        assertEquals(6, nativePack.passes.size());
    }

    @Test
    void presetApplicationAndMslDefinesAreDeterministic(@TempDir Path tmpDir) {
        ShaderPackManifest nativePack = ShaderPackLoader.discoverAll(null).stream()
            .filter(p -> "builtin:celestia-native".equals(p.id))
            .findFirst()
            .orElseThrow();

        ShaderOptionState state = new ShaderOptionState(nativePack);
        assertEquals("Balanced", state.activePreset());
        String balancedHash = state.configHash();

        state.applyPreset("Performance");
        assertEquals("Performance", state.activePreset());
        assertFalse(state.getBoolean("SSAO_ENABLED"));
        assertEquals("1024", state.get("SHADOW_RES"));
        assertNotEquals(balancedHash, state.configHash());

        String mslDefines = state.toMslDefines();
        assertTrue(mslDefines.contains("#define SHADOWS_ENABLED 1"));
        assertTrue(mslDefines.contains("#define SSAO_ENABLED 0"));
        assertTrue(mslDefines.contains("#define CLOUD_STEPS 8"));

        state.saveToDisk(tmpDir);
        ShaderOptionState reloaded = new ShaderOptionState(nativePack);
        reloaded.loadFromDisk(tmpDir);
        assertEquals("Performance", reloaded.activePreset());
        assertEquals(state.configHash(), reloaded.configHash());
    }

    @Test
    void discoversExternalNativePackDirectory(@TempDir Path shaderpacksDir) throws Exception {
        Path customDir = shaderpacksDir.resolve("TestAurora");
        Files.createDirectories(customDir);
        Files.writeString(customDir.resolve("celestia-shader.json"), """
            {
              "apiVersion": 1,
              "name": "Test Aurora",
              "author": "Tester",
              "version": "0.1",
              "options": [
                { "id": "AURORA_ON", "label": "Aurora", "type": "TOGGLE", "default": "true", "category": "Sky" }
              ],
              "passes": []
            }
            """);
        List<ShaderPackManifest> packs = ShaderPackLoader.discoverAll(shaderpacksDir);
        ShaderPackManifest found = packs.stream()
            .filter(p -> "Test Aurora".equals(p.name))
            .findFirst()
            .orElseThrow();
        assertEquals(ShaderPackManifest.PackKind.NATIVE_MSL, found.kind);
        assertFalse(found.builtin);
        assertEquals(1, found.options.size());
        assertEquals(ShaderOptionDef.Kind.TOGGLE, found.options.get(0).kind());
    }
}
