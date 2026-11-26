package dev.celestia.metal.shader.pack;

import dev.celestia.metal.shader.iris.IrisPackParser;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Discovers built-in Native MSL packs, external Native MSL packs, and Iris/OptiFine GLSL packs
 * inside {@code shaderpacks/}.
 */
public final class ShaderPackLoader {
    private static final List<String> BUILTIN_PACK_RESOURCES = List.of(
        "/assets/celestiametal/shaderpacks/celestia-native/celestia-shader.json"
    );

    private ShaderPackLoader() {}

    public static List<ShaderPackManifest> discoverAll(Path shaderpacksDir) {
        List<ShaderPackManifest> packs = new ArrayList<>();
        packs.add(ShaderPackManifest.offPack());

        for (String resPath : BUILTIN_PACK_RESOURCES) {
            String json = readClasspathText(resPath);
            if (json != null) {
                String dirRoot = resPath.substring(0, resPath.lastIndexOf('/'));
                String id = "builtin:" + dirRoot.substring(dirRoot.lastIndexOf('/') + 1);
                packs.add(ShaderPackManifest.parseNativeJson(id, json, true, null, dirRoot));
            }
        }

        if (shaderpacksDir != null && Files.isDirectory(shaderpacksDir)) {
            List<Path> entries = new ArrayList<>();
            try (var stream = Files.list(shaderpacksDir)) {
                stream.forEach(entries::add);
            } catch (IOException ignored) {
            }
            entries.sort(Comparator.comparing(p -> p.getFileName().toString().toLowerCase()));
            for (Path entry : entries) {
                ShaderPackManifest m = inspectUserEntry(entry);
                if (m != null) packs.add(m);
            }
        }
        return packs;
    }

    public static ShaderPackManifest inspectUserEntry(Path entry) {
        String fname = entry.getFileName().toString();
        if (fname.startsWith(".")) return null;
        if (Files.isDirectory(entry)) {
            Path manifestFile = entry.resolve("celestia-shader.json");
            if (Files.exists(manifestFile)) {
                try {
                    String json = Files.readString(manifestFile, StandardCharsets.UTF_8);
                    return ShaderPackManifest.parseNativeJson("user:" + fname, json, false, entry, null);
                } catch (IOException ignored) {
                    return null;
                }
            }
            if (Files.isDirectory(entry.resolve("shaders"))) {
                return IrisPackParser.parseDirectory(entry);
            }
            return null;
        }
        if (fname.toLowerCase().endsWith(".zip")) {
            try (ZipFile zf = new ZipFile(entry.toFile())) {
                ZipEntry nativeEntry = zf.getEntry("celestia-shader.json");
                if (nativeEntry != null) {
                    try (InputStream in = zf.getInputStream(nativeEntry)) {
                        String json = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                        return ShaderPackManifest.parseNativeJson("user:" + fname, json, false, entry, null);
                    }
                }
                if (zf.getEntry("shaders/shaders.properties") != null || hasZipShadersFolder(zf)) {
                    return IrisPackParser.parseZip(entry, zf);
                }
            } catch (IOException ignored) {
            }
        }
        return null;
    }

    private static boolean hasZipShadersFolder(ZipFile zf) {
        var en = zf.entries();
        while (en.hasMoreElements()) {
            String n = en.nextElement().getName();
            if (n.startsWith("shaders/") && (n.endsWith(".fsh") || n.endsWith(".vsh"))) return true;
        }
        return false;
    }

    public static String readPackFile(ShaderPackManifest manifest, String relativePath) {
        if (manifest.builtin && manifest.resourceRoot != null) {
            return readClasspathText(manifest.resourceRoot + "/" + relativePath);
        }
        if (manifest.sourcePath == null) return null;
        if (Files.isDirectory(manifest.sourcePath)) {
            Path p = manifest.sourcePath.resolve(relativePath);
            if (!Files.exists(p)) return null;
            try {
                return Files.readString(p, StandardCharsets.UTF_8);
            } catch (IOException e) {
                return null;
            }
        }
        if (manifest.sourcePath.getFileName().toString().toLowerCase().endsWith(".zip")) {
            try (ZipFile zf = new ZipFile(manifest.sourcePath.toFile())) {
                ZipEntry ze = zf.getEntry(relativePath);
                if (ze == null) return null;
                try (InputStream in = zf.getInputStream(ze)) {
                    return new String(in.readAllBytes(), StandardCharsets.UTF_8);
                }
            } catch (IOException e) {
                return null;
            }
        }
        return null;
    }

    public static String readClasspathText(String resourcePath) {
        try (InputStream in = ShaderPackLoader.class.getResourceAsStream(resourcePath)) {
            if (in == null) return null;
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
        }
    }
}
