package dev.celestia.metal;

import dev.celestia.metal.shader.iris.IrisGlslBridge;
import dev.celestia.metal.shader.iris.IrisPackParser;
import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class IrisPackParserTest {

    @Test
    void parsesIrisPropertiesLangAndOptions(@TempDir Path shaderpacksDir) throws Exception {
        Path packDir = shaderpacksDir.resolve("SampleIrisPack");
        Path shadersDir = packDir.resolve("shaders");
        Path langDir = shadersDir.resolve("lang");
        Files.createDirectories(langDir);

        Files.writeString(shadersDir.resolve("shaders.properties"), """
            profile.LOW=BLOOM_STRENGTH=0.1 !GODRAYS
            profile.HIGH=BLOOM_STRENGTH=0.4 GODRAYS
            screen.LIGHTING=SHADOW_SAMPLES GODRAYS
            screen.POST=BLOOM_STRENGTH
            """);
        Files.writeString(langDir.resolve("en_us.lang"), """
            screen.LIGHTING=Lighting
            screen.POST=Post Processing
            option.SHADOW_SAMPLES=Shadow Samples
            option.GODRAYS=Volumetric Rays
            option.BLOOM_STRENGTH=Bloom Strength
            profile.LOW=Low
            profile.HIGH=High
            """);
        Files.writeString(shadersDir.resolve("composite.fsh"), """
            #define SHADOW_SAMPLES 4 // [1 2 4 8]
            #define BLOOM_STRENGTH 0.25 // [0.0 0.1 0.25 0.5]
            //#define GODRAYS
            void main() {
                gl_FragColor = vec4(1.0);
            }
            """);

        ShaderPackManifest manifest = IrisPackParser.parseDirectory(packDir);
        assertEquals(ShaderPackManifest.PackKind.IRIS_GLSL, manifest.kind);
        assertTrue(manifest.categories.contains("Lighting"));
        assertTrue(manifest.categories.contains("Post Processing"));
        assertEquals(3, manifest.options.size());

        ShaderOptionDef samples = manifest.options.stream()
            .filter(o -> "SHADOW_SAMPLES".equals(o.id())).findFirst().orElseThrow();
        assertEquals("Shadow Samples", samples.label());
        assertEquals("Lighting", samples.category());
        assertEquals(ShaderOptionDef.Kind.INT_SLIDER, samples.kind());

        ShaderOptionState state = new ShaderOptionState(manifest);
        state.applyPreset("High");
        assertTrue(state.getBoolean("GODRAYS"));
        state.saveToDisk(shaderpacksDir);
        assertTrue(Files.exists(shaderpacksDir.resolve("SampleIrisPack.txt")));

        ShaderOptionState reloaded = new ShaderOptionState(manifest);
        reloaded.loadFromDisk(shaderpacksDir);
        assertTrue(reloaded.getBoolean("GODRAYS"));
    }

    @Test
    void translatesIrisGlslFragmentToMslViaShadercAndSpvc() {
        String glsl = """
            #version 450 core
            layout(location = 0) in vec2 vUv;
            void main() {
                celestiaFragColor0 = vec4(vUv.x, vUv.y, 0.5, 1.0);
            }
            """;
        String msl = IrisGlslBridge.translateGlslToMsl("composite.fsh", glsl, IrisGlslBridge.Stage.FRAGMENT, null);
        assertNotNull(msl);
        assertTrue(msl.contains("metal::") || msl.contains("using namespace metal"));
        assertTrue(msl.contains("celestiaFragColor0"));
    }
}
