package dev.celestia.metal;

import dev.celestia.metal.shade.ShadeSettings;
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
        assertEquals(2, packs.size());

        ShaderPackManifest nativePack = packs.stream()
            .filter(p -> "builtin:celestia-native".equals(p.id))
            .findFirst()
            .orElseThrow();

        assertEquals(ShaderPackManifest.PackKind.WORLD_MSL, nativePack.kind);
        assertEquals(List.of("Performance", "Balanced", "Quality", "Ultra"), List.copyOf(nativePack.presets.keySet()));
        assertEquals(41, nativePack.options.size());
        assertTrue(nativePack.passes.isEmpty());
    }

    @Test
    void nativeOptionsApplyOnSnapshotAndPersist(@TempDir Path tmpDir) {
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

        ShadeSettings applied = ShadeSettings.from(state);
        assertEquals(1024, applied.shadows().resolution());
        assertEquals(0f, applied.water().swell());
        assertEquals(16, applied.water().ssrBudget());
        assertFalse(applied.atmosphere().volumetrics());
        assertEquals(8, applied.atmosphere().cloudSteps());
        assertTrue(applied.lights().dynamic());
        assertEquals(16, applied.lights().count());
        assertEquals(1f, applied.lights().strength());
        assertTrue(applied.lights().entities());
        assertTrue(applied.lights().colored());
        assertEquals(1f, applied.lights().coloredGlow());

        ShaderOptionState draft = state.copy();
        draft.applyPreset("Ultra");
        assertEquals(4096, ShadeSettings.from(draft).shadows().resolution());
        assertEquals(1024, ShadeSettings.from(state).shadows().resolution());
        draft.set("EXPOSURE", "NaN");
        assertEquals(0f, ShadeSettings.from(draft).post().exposureEv());
        draft.set("EXPOSURE", "42");
        assertEquals(2f, ShadeSettings.from(draft).post().exposureEv());
        draft.set("WATER_REFLECTIONS", "OFF");
        assertFalse(ShadeSettings.from(draft).water().screenReflections());
        assertEquals(0f, ShadeSettings.from(draft).water().reflectionStrength());

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
