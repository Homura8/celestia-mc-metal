package dev.celestia.metal;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.UniformType;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.backend.MetalShaderTranslator;
import dev.celestia.metal.shade.ShadeSettings;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPackLoader;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

/** Multi-pack support: user world packs (SHADER_PACK_SPEC.md, "World packs") over the engine's ABI and Celestia Native. */
class WorldPackTest {
    private static final Path EXAMPLE = Path.of("examples/shaderpacks/celestia-example-world");

    @AfterEach
    void restoreCelestiaNative() {
        ShadeShaderPatcher.setWorldPack("builtin:celestia-native", null, "");
    }

    private static ShaderPackManifest example() {
        ShaderPackManifest m = ShaderPackLoader.inspectUserEntry(EXAMPLE);
        assertNotNull(m, "example world pack not discovered");
        return m;
    }

    private static ShadeShaderPatcher.PackSource source(ShaderPackManifest m) {
        return name -> ShaderPackLoader.readPackFile(m, "shaders/" + name);
    }

    @Test
    void exampleIsAWorldPackWithRecompileOptions() {
        ShaderPackManifest m = example();
        assertEquals(ShaderPackManifest.PackKind.WORLD_MSL, m.kind);
        ShaderOptionState st = new ShaderOptionState(m);
        String defines = st.toMslDefines(true);
        assertTrue(defines.contains("#define SKY_TINT 0"), defines);
        assertTrue(defines.contains("#define SKY_TINT_MINT 1"), defines);
        assertTrue(defines.contains("#define SKY_TINT_STRENGTH 0.5000f"), defines);
        assertFalse(defines.contains("SHADOWS_ENABLED"), "runtime options are not compiled in");
    }

    @Test
    void userPacksDefaultToTheLegacyPassFormat(@TempDir Path dir) throws Exception {
        Path pack = dir.resolve("legacy");
        Files.createDirectories(pack);
        Files.writeString(pack.resolve("celestia-shader.json"), "{\"name\":\"Legacy\",\"passes\":[]}");
        assertEquals(ShaderPackManifest.PackKind.NATIVE_MSL, ShaderPackLoader.inspectUserEntry(pack).kind);
    }

    @Test
    void irisPacksAreHiddenByDefault(@TempDir Path dir) throws Exception {
        Path iris = dir.resolve("SomeIrisPack/shaders");
        Files.createDirectories(iris);
        Files.writeString(iris.resolve("composite.fsh"), "void main() {}");
        if (!ShaderPackLoader.IRIS_PACKS) {
            assertNull(ShaderPackLoader.inspectUserEntry(dir.resolve("SomeIrisPack")));
            assertTrue(ShaderPackLoader.discoverAll(dir).stream().noneMatch(p -> p.kind == ShaderPackManifest.PackKind.IRIS_GLSL));
        }
    }

    @Test
    void packFilesOverrideCelestiaNativeAndEngineFilesDoNot() {
        String nativeSky = ShadeShaderPatcher.resource("sky.fs.metal");
        String nativeWater = ShadeShaderPatcher.resource("water.metal");
        int before = ShadeShaderPatcher.epoch();

        ShaderPackManifest m = example();
        assertTrue(ShadeShaderPatcher.setWorldPack(m.id, name -> {
            // a pack shipping its own copy of an engine file must not replace the ABI
            if (name.equals("shade_api.metal")) return "#error a pack cannot override the engine ABI\n";
            return ShaderPackLoader.readPackFile(m, "shaders/" + name);
        }, ""));
        assertNotEquals(before, ShadeShaderPatcher.epoch(), "a pack switch must move the epoch on");
        assertFalse(ShadeShaderPatcher.setWorldPack(m.id, source(m), ""), "same pack and defines: no rebuild");

        assertTrue(ShadeShaderPatcher.resource("sky.fs.metal").contains("exampleSkyTint"));
        assertNotEquals(nativeSky, ShadeShaderPatcher.resource("sky.fs.metal"));
        assertEquals(nativeWater, ShadeShaderPatcher.resource("water.metal"), "files a pack omits fall back to Celestia Native");
        assertTrue(ShadeShaderPatcher.resource("shade_api.metal").contains("struct ShadeFrame"));

        int afterSwitch = ShadeShaderPatcher.epoch();
        assertTrue(ShadeShaderPatcher.setWorldPack(m.id, source(m), "#define SKY_TINT 2\n"));
        assertNotEquals(afterSwitch, ShadeShaderPatcher.epoch(), "a changed recompile option must rebuild");
        assertTrue(ShadeShaderPatcher.prelude(true, false, null).contains("#define SKY_TINT 2"));
    }

    @Test
    void undeclaredEngineOptionsKeepCelestiaNativeDefaults() {
        ShaderPackManifest nat = ShaderPackLoader.discoverAll(null).stream()
            .filter(p -> "builtin:celestia-native".equals(p.id)).findFirst().orElseThrow();
        ShaderOptionState example = new ShaderOptionState(example());
        example.set("SHADOWS_ENABLED", "false");
        ShadeSettings bare = ShadeSettings.from(example);
        ShadeSettings withFallback = ShadeSettings.from(example.withFallback(new ShaderOptionState(nat)));
        ShadeSettings reference = ShadeSettings.from(new ShaderOptionState(nat));

        assertFalse(withFallback.shadows().enabled(), "a declared engine option is the pack's");
        assertEquals(reference.water().enabled(), withFallback.water().enabled());
        assertEquals(reference.shadows().resolution(), withFallback.shadows().resolution());
        assertNotEquals(reference.shadows().resolution(), bare.shadows().resolution(), "without the fallback it would be 0");
    }

    @Test
    @EnabledOnOs(OS.MAC)
    void exampleSkyCompilesOnMetal() {
        ShaderPackManifest m = example();
        ShadeShaderPatcher.setWorldPack(m.id, source(m), new ShaderOptionState(m).toMslDefines(true));
        List<BindGroupLayout.UniformDescription> uniforms = List.of(
            new BindGroupLayout.UniformDescription("Fog", UniformType.UNIFORM_BUFFER),
            new BindGroupLayout.UniformDescription("DynamicTransforms", UniformType.UNIFORM_BUFFER),
            new BindGroupLayout.UniformDescription("Projection", UniformType.UNIFORM_BUFFER));
        var bindings = MetalShaderTranslator.buildBindings(uniforms);
        String vs = """
            struct main0_in { float3 Position [[attribute(0)]]; };
            struct main0_out { float4 gl_Position [[position]]; };
            vertex main0_out main0(main0_in in [[stage_in]]) {
                main0_out out = {};
                out.gl_Position = float4(in.Position, 1.0);
                out.gl_Position.y = -(out.gl_Position.y);
                return out;
            }
            """;
        String fs = """
            struct main0_out { float4 fragColor [[color(0)]]; };
            fragment main0_out main0() { main0_out out = {}; out.fragColor = float4(1.0); return out; }
            """;
        var sky = ShadeShaderPatcher.patch("minecraft:pipeline/sky", vs, "main0", fs, "main0",
            uniforms, bindings, ShadeShaderPatcher.Variant.HDR_WORLD);
        assertTrue(sky.patched());
        assertTrue(sky.fsSource().contains("exampleSkyTint"));

        long ctx = MetalNative.deviceCreate(true, false, "");
        assertNotEquals(0L, ctx);
        try {
            StringBuilder err = new StringBuilder();
            long fsLib = MetalNative.compileMslLibrary(ctx, sky.fsSource(), "test.example.sky.fs", true, err);
            assertNotEquals(0L, fsLib, () -> err.toString());
            MetalNative.libraryDestroy(fsLib);
            long post = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.postSource(), "test.example.post", true, err);
            assertNotEquals(0L, post, () -> "Celestia Native's files under the example pack: " + err);
            MetalNative.libraryDestroy(post);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }
}
