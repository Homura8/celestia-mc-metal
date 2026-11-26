package dev.celestia.metal.shader.pack;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Manifest describing a shader pack (Built-in Native MSL, External Native MSL, or Iris/OptiFine GLSL).
 */
public final class ShaderPackManifest {
    private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();

    public enum PackKind {
        OFF("Off"),
        NATIVE_MSL("✦ Native MSL"),
        IRIS_GLSL("Iris / GLSL");

        public final String badge;

        PackKind(String badge) {
            this.badge = badge;
        }
    }

    public record PassDef(
        String name,
        String stage,       // "COMPUTE" or "FULLSCREEN"
        String shaderFile,
        String entryPoint,
        double resolutionScale,
        String outputFormat,
        int threadgroupX,
        int threadgroupY
    ) {}

    public final String id;
    public final String name;
    public final String author;
    public final String version;
    public final String description;
    public final int apiVersion;
    public final PackKind kind;
    public final boolean builtin;
    public final Path sourcePath;
    public final String resourceRoot;
    public final List<String> categories;
    public final List<ShaderOptionDef> options;
    public final Map<String, Map<String, String>> presets;
    public final List<PassDef> passes;

    public ShaderPackManifest(String id, String name, String author, String version, String description,
                              int apiVersion, PackKind kind, boolean builtin, Path sourcePath, String resourceRoot,
                              List<String> categories, List<ShaderOptionDef> options,
                              Map<String, Map<String, String>> presets, List<PassDef> passes) {
        this.id = id;
        this.name = name;
        this.author = author;
        this.version = version;
        this.description = description;
        this.apiVersion = apiVersion;
        this.kind = kind;
        this.builtin = builtin;
        this.sourcePath = sourcePath;
        this.resourceRoot = resourceRoot;
        this.categories = List.copyOf(categories);
        this.options = List.copyOf(options);
        this.presets = presets;
        this.passes = List.copyOf(passes);
    }

    public static ShaderPackManifest offPack() {
        return new ShaderPackManifest(
            "off", "Off (Vanilla Metal)", "Minecraft", "26.3",
            "Renders Minecraft's native visuals directly on Metal 4 / Metal 3 with zero shader overhead.",
            1, PackKind.OFF, true, null, null,
            List.of(), List.of(), Map.of(), List.of()
        );
    }

    public static ShaderPackManifest parseNativeJson(String id, String jsonText, boolean builtin,
                                                     Path sourcePath, String resourceRoot) {
        JsonObject root = JsonParser.parseString(jsonText).getAsJsonObject();
        int api = root.has("apiVersion") ? root.get("apiVersion").getAsInt() : 1;
        String name = str(root, "name", id);
        String author = str(root, "author", "Unknown");
        String version = str(root, "version", "1.0.0");
        String desc = str(root, "description", "Native Apple Silicon MSL shader pack.");

        List<String> categories = new ArrayList<>();
        if (root.has("categories") && root.get("categories").isJsonArray()) {
            for (JsonElement el : root.getAsJsonArray("categories")) {
                categories.add(el.getAsString());
            }
        }

        List<ShaderOptionDef> opts = new ArrayList<>();
        if (root.has("options") && root.get("options").isJsonArray()) {
            for (JsonElement el : root.getAsJsonArray("options")) {
                JsonObject o = el.getAsJsonObject();
                String oId = str(o, "id", "");
                if (oId.isEmpty()) continue;
                String oLabel = str(o, "label", oId);
                String oDesc = str(o, "description", "");
                String oCat = str(o, "category", categories.isEmpty() ? "General" : categories.get(0));
                if (!categories.contains(oCat)) categories.add(oCat);

                ShaderOptionDef.Kind kind = ShaderOptionDef.Kind.valueOf(str(o, "type", "TOGGLE").toUpperCase());
                ShaderOptionDef.Impact impact = ShaderOptionDef.Impact.valueOf(str(o, "impact", "LOW").toUpperCase());
                String def = str(o, "default", kind == ShaderOptionDef.Kind.TOGGLE ? "true" : "0");
                List<String> vals = new ArrayList<>();
                if (o.has("values") && o.get("values").isJsonArray()) {
                    for (JsonElement v : o.getAsJsonArray("values")) vals.add(v.getAsString());
                }
                double min = o.has("min") ? o.get("min").getAsDouble() : 0.0;
                double max = o.has("max") ? o.get("max").getAsDouble() : 1.0;
                double step = o.has("step") ? o.get("step").getAsDouble() : 1.0;
                opts.add(new ShaderOptionDef(oId, oLabel, oDesc, oCat, kind, def, vals, min, max, step, impact));
            }
        }

        Map<String, Map<String, String>> presets = new LinkedHashMap<>();
        if (root.has("presets") && root.get("presets").isJsonObject()) {
            JsonObject pObj = root.getAsJsonObject("presets");
            for (var entry : pObj.entrySet()) {
                Map<String, String> vals = new LinkedHashMap<>();
                JsonObject po = entry.getValue().getAsJsonObject();
                for (var kv : po.entrySet()) {
                    vals.put(kv.getKey(), kv.getValue().getAsString());
                }
                presets.put(entry.getKey(), Map.copyOf(vals));
            }
        }

        List<PassDef> passes = new ArrayList<>();
        if (root.has("passes") && root.get("passes").isJsonArray()) {
            JsonArray arr = root.getAsJsonArray("passes");
            for (JsonElement el : arr) {
                JsonObject p = el.getAsJsonObject();
                passes.add(new PassDef(
                    str(p, "name", "pass"),
                    str(p, "stage", "FULLSCREEN").toUpperCase(),
                    str(p, "shader", ""),
                    str(p, "entryPoint", "main_fs"),
                    p.has("scale") ? p.get("scale").getAsDouble() : 1.0,
                    str(p, "format", "RGBA16_FLOAT"),
                    p.has("threadgroupX") ? p.get("threadgroupX").getAsInt() : 8,
                    p.has("threadgroupY") ? p.get("threadgroupY").getAsInt() : 8
                ));
            }
        }

        return new ShaderPackManifest(id, name, author, version, desc, api, PackKind.NATIVE_MSL,
            builtin, sourcePath, resourceRoot, categories, opts, presets, passes);
    }

    public String toJson() {
        return GSON.toJson(this);
    }

    private static String str(JsonObject o, String key, String def) {
        return o.has(key) && !o.get(key).isJsonNull() ? o.get(key).getAsString() : def;
    }
}
