package dev.celestia.metal.shader.iris;

import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Parses OptiFine / Iris shader packs ({@code shaders/shaders.properties}, {@code shaders/lang/en_us.lang},
 * and {@code #define}/{@code const} option comments) into Celestia's unified {@link ShaderPackManifest}.
 */
public final class IrisPackParser {
    private static final Pattern DEFINE_OPT = Pattern.compile(
        "^\\s*#define\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+([^/\\r\\n]+?)\\s*(?://\\s*\\[(.*?)\\])?\\s*$"
    );
    private static final Pattern TOGGLE_OPT = Pattern.compile(
        "^\\s*(?://\\s*)?#define\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*(?://.*)?$"
    );

    private IrisPackParser() {}

    public static ShaderPackManifest parseDirectory(Path dir) {
        Map<String, String> files = new LinkedHashMap<>();
        Path shadersDir = dir.resolve("shaders");
        if (Files.isDirectory(shadersDir)) {
            try (var walk = Files.walk(shadersDir)) {
                walk.filter(Files::isRegularFile).forEach(p -> {
                    String name = p.getFileName().toString().toLowerCase();
                    if (name.endsWith(".properties") || name.endsWith(".lang")
                        || name.endsWith(".fsh") || name.endsWith(".vsh") || name.endsWith(".glsl")) {
                        try {
                            String rel = dir.relativize(p).toString().replace('\\', '/');
                            files.put(rel, Files.readString(p, StandardCharsets.UTF_8));
                        } catch (IOException ignored) {
                        }
                    }
                });
            } catch (IOException ignored) {
            }
        }
        String packName = dir.getFileName().toString();
        return buildManifest("iris:" + packName, packName, dir, files);
    }

    public static ShaderPackManifest parseZip(Path zipPath, ZipFile zf) {
        Map<String, String> files = new LinkedHashMap<>();
        var en = zf.entries();
        while (en.hasMoreElements()) {
            ZipEntry ze = en.nextElement();
            if (ze.isDirectory()) continue;
            String n = ze.getName();
            if (n.startsWith("shaders/") && (n.endsWith(".properties") || n.endsWith(".lang")
                || n.endsWith(".fsh") || n.endsWith(".vsh") || n.endsWith(".glsl"))) {
                try (InputStream in = zf.getInputStream(ze)) {
                    files.put(n, new String(in.readAllBytes(), StandardCharsets.UTF_8));
                } catch (IOException ignored) {
                }
            }
        }
        String fileName = zipPath.getFileName().toString();
        String display = fileName.endsWith(".zip") ? fileName.substring(0, fileName.length() - 4) : fileName;
        return buildManifest("iris:" + fileName, display, zipPath, files);
    }

    public static ShaderPackManifest buildManifest(String id, String displayName, Path sourcePath,
                                                   Map<String, String> shaderFiles) {
        Map<String, String> props = parseProperties(shaderFiles.getOrDefault("shaders/shaders.properties", ""));
        Map<String, String> lang = parseLang(shaderFiles.getOrDefault("shaders/lang/en_us.lang", ""));

        Map<String, ShaderOptionDef> discovered = new LinkedHashMap<>();
        for (var entry : shaderFiles.entrySet()) {
            String path = entry.getKey();
            if (!path.endsWith(".fsh") && !path.endsWith(".vsh") && !path.endsWith(".glsl")) continue;
            scanOptions(entry.getValue(), lang, discovered);
        }

        // Organize screen categories from shaders.properties
        List<String> categories = new ArrayList<>();
        Map<String, String> optionCategory = new LinkedHashMap<>();
        for (var e : props.entrySet()) {
            if (e.getKey().startsWith("screen.") && !e.getKey().equals("screen")) {
                String screenId = e.getKey().substring("screen.".length());
                String catName = lang.getOrDefault("screen." + screenId, capitalize(screenId));
                if (!categories.contains(catName)) categories.add(catName);
                for (String token : e.getValue().split("\\s+")) {
                    if (!token.isEmpty() && !token.startsWith("[") && !token.equals("<empty>") && !token.equals("*")) {
                        optionCategory.put(token, catName);
                    }
                }
            }
        }
        if (categories.isEmpty()) {
            categories.add("General");
        }

        List<ShaderOptionDef> finalOptions = new ArrayList<>();
        for (ShaderOptionDef raw : discovered.values()) {
            String cat = optionCategory.getOrDefault(raw.id(), categories.get(0));
            finalOptions.add(new ShaderOptionDef(
                raw.id(), raw.label(), raw.description(), cat,
                raw.kind(), raw.defaultValue(), raw.values(), raw.min(), raw.max(), raw.step(), raw.impact()
            ));
        }

        Map<String, Map<String, String>> presets = new LinkedHashMap<>();
        for (var e : props.entrySet()) {
            if (e.getKey().startsWith("profile.")) {
                String pKey = e.getKey().substring("profile.".length());
                String pName = lang.getOrDefault("profile." + pKey, capitalize(pKey));
                Map<String, String> overrides = new LinkedHashMap<>();
                for (String tok : e.getValue().split("\\s+")) {
                    if (tok.isEmpty() || tok.startsWith("profile.")) continue;
                    if (tok.startsWith("!")) {
                        overrides.put(tok.substring(1), "false");
                    } else if (tok.contains("=")) {
                        int eq = tok.indexOf('=');
                        overrides.put(tok.substring(0, eq), tok.substring(eq + 1));
                    } else {
                        overrides.put(tok, "true");
                    }
                }
                presets.put(pName, overrides);
            }
        }

        String desc = lang.getOrDefault("pack.description", "OptiFine / Iris GLSL shader pack via Celestia Metal compatibility bridge.");
        return new ShaderPackManifest(
            id, displayName, "Iris Pack", "Iris", desc,
            1, ShaderPackManifest.PackKind.IRIS_GLSL, false, sourcePath, null,
            categories, finalOptions, presets, List.of()
        );
    }

    private static void scanOptions(String src, Map<String, String> lang, Map<String, ShaderOptionDef> out) {
        String[] lines = src.split("\\R");
        for (String line : lines) {
            Matcher dm = DEFINE_OPT.matcher(line);
            if (dm.matches()) {
                String id = dm.group(1);
                String val = dm.group(2).trim();
                String choices = dm.group(3);
                if (choices == null || out.containsKey(id)) continue;
                String label = lang.getOrDefault("option." + id, id);
                String desc = lang.getOrDefault("option." + id + ".comment", "");
                List<String> tokens = List.of(choices.trim().split("\\s+"));
                if (tokens.size() >= 2) {
                    if (isNumericList(tokens)) {
                        boolean hasDecimal = tokens.stream().anyMatch(t -> t.contains(".")) || val.contains(".");
                        if (hasDecimal) {
                            double min = parseDoubleSafe(tokens.get(0), 0.0);
                            double max = parseDoubleSafe(tokens.get(tokens.size() - 1), 1.0);
                            double step = tokens.size() > 1 ? Math.abs(parseDoubleSafe(tokens.get(1), min + 0.1) - min) : 0.1;
                            if (step <= 0.0) step = 0.05;
                            out.put(id, ShaderOptionDef.floatSlider(id, label, desc, "General",
                                parseDoubleSafe(val, min), min, max, step, ShaderOptionDef.Impact.MEDIUM));
                        } else {
                            int min = parseIntSafe(tokens.get(0), 0);
                            int max = parseIntSafe(tokens.get(tokens.size() - 1), 10);
                            int step = tokens.size() > 1 ? Math.max(1, Math.abs(parseIntSafe(tokens.get(1), min + 1) - min)) : 1;
                            out.put(id, ShaderOptionDef.intSlider(id, label, desc, "General",
                                parseIntSafe(val, min), min, max, step, ShaderOptionDef.Impact.MEDIUM));
                        }
                    } else {
                        out.put(id, ShaderOptionDef.enumOpt(id, label, desc, "General", val, tokens, ShaderOptionDef.Impact.MEDIUM));
                    }
                }
                continue;
            }
            if (line.contains("//") && line.contains("#define")) {
                Matcher tm = TOGGLE_OPT.matcher(line);
                if (tm.matches()) {
                    String id = tm.group(1);
                    if (!out.containsKey(id) && (lang.containsKey("option." + id) || line.trim().startsWith("//#define"))) {
                        boolean enabled = !line.trim().startsWith("//");
                        String label = lang.getOrDefault("option." + id, id);
                        String desc = lang.getOrDefault("option." + id + ".comment", "");
                        out.put(id, ShaderOptionDef.toggle(id, label, desc, "General", enabled, ShaderOptionDef.Impact.LOW));
                    }
                }
            }
        }
    }

    public static Map<String, String> parseProperties(String text) {
        Map<String, String> map = new LinkedHashMap<>();
        StringBuilder current = new StringBuilder();
        String currentKey = null;
        for (String rawLine : text.split("\\R")) {
            String line = rawLine.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            boolean cont = line.endsWith("\\");
            String part = cont ? line.substring(0, line.length() - 1).trim() : line;
            if (currentKey == null) {
                int eq = part.indexOf('=');
                if (eq > 0) {
                    currentKey = part.substring(0, eq).trim();
                    current.append(part.substring(eq + 1).trim());
                }
            } else {
                current.append(' ').append(part);
            }
            if (!cont && currentKey != null) {
                map.put(currentKey, current.toString().trim());
                currentKey = null;
                current.setLength(0);
            }
        }
        return map;
    }

    public static Map<String, String> parseLang(String text) {
        Map<String, String> map = new LinkedHashMap<>();
        for (String rawLine : text.split("\\R")) {
            String line = rawLine.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            int eq = line.indexOf('=');
            if (eq > 0) {
                map.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
            }
        }
        return map;
    }

    private static boolean isNumericList(List<String> tokens) {
        for (String t : tokens) {
            try {
                Double.parseDouble(t);
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return true;
    }

    private static double parseDoubleSafe(String s, double def) {
        try { return Double.parseDouble(s); } catch (NumberFormatException e) { return def; }
    }

    private static int parseIntSafe(String s, int def) {
        try { return Integer.parseInt(s); } catch (NumberFormatException e) { return def; }
    }

    private static String capitalize(String s) {
        if (s == null || s.isEmpty()) return "General";
        String clean = s.replace('_', ' ');
        return Character.toUpperCase(clean.charAt(0)) + clean.substring(1);
    }
}
