// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/ShadeMsl.java & ShadeEntity.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalShaderTranslator;
import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Loads ported MSL shader modules and patches RenderPearl-translated SPIRV-Cross Metal sources for HDR
 * world rendering (sky, celestial, stars, sunrise/sunset, clouds, vanilla & Sodium 0.9.x terrain,
 * entities/items/blocks/particles/hand, and generic HDR sRGB->scene-linear conversion).
 *
 * <p>Sodium compatibility is achieved purely by inspecting translated MSL structure and pipeline names
 * without ever loading or referencing Sodium Java classes.
 */
public final class ShadeShaderPatcher {
    public enum Variant {
        BASE,
        HDR_WORLD,
        HDR_WORLD_WATER_ABOVE,
        HDR_WORLD_WATER_SKY_ONLY,
        HDR_WORLD_WATER_ABOVE_SKY_ONLY,
        HDR_WORLD_WATER_ABOVE_SKY_ONLY_NO_SWELL_CAUSTICS,
        HDR_WORLD_WATER_ABOVE_FAST_SKY,
        HDR_WORLD_WATER_ABOVE_FAST_SKY_NO_SWELL_CAUSTICS,
        HDR_HAND
    }

    public record PatchedStages(String vsSource, String vsEntry, String fsSource, String fsEntry, boolean patched) {}

    /** Engine-owned MSL: the world-pack ABI (buffer layouts, slots), vanilla uniform blocks and the engine's own kernels. */
    private static final String ENGINE_BASE = "/assets/celestiametal/shaders/engine/";
    private static final Set<String> ENGINE_FILES = Set.of(
        "shade_slots.metal", "shade_api.metal", "vanilla_uniforms.metal",
        "taa.metal", "dynlight.metal", "dynlight_vis.metal", "colorlight.metal");
    /** Celestia Native's sources: the reference world pack, and the fallback for any file a world pack does not provide. */
    public static final String DEFAULT_PACK_SHADERS = "/assets/celestiametal/shaderpacks/celestia-native/shaders/";
    private static final Map<String, String> RESOURCE_CACHE = new ConcurrentHashMap<>();

    /** Reads one file of the active world pack ({@code shaders/<name>} relative to the pack root); null when it has none. */
    @FunctionalInterface
    public interface PackSource {
        String read(String name);
    }

    private static volatile PackSource worldPack;
    private static volatile String worldPackKey = "builtin:celestia-native";
    private static volatile String worldPackDefines = "";
    private static volatile int epoch;

    private static final Map<String, Integer> ENTITY_PIPELINES = Map.ofEntries(
        Map.entry("minecraft:pipeline/entity_solid", 0),
        Map.entry("minecraft:pipeline/entity_solid_offset_forward", 0),
        Map.entry("minecraft:pipeline/entity_solid_z_offset_forward", 0),
        Map.entry("minecraft:pipeline/entity_cutout", 0),
        Map.entry("minecraft:pipeline/entity_cutout_cull", 0),
        Map.entry("minecraft:pipeline/entity_cutout_z_offset", 0),
        Map.entry("minecraft:pipeline/entity_cutout_dissolve", 0),
        Map.entry("minecraft:pipeline/entity_translucent", 0),
        Map.entry("minecraft:pipeline/entity_translucent_cull", 0),
        Map.entry("minecraft:pipeline/armor_cutout_no_cull", 0),
        Map.entry("minecraft:pipeline/armor_decal_cutout_no_cull", 0),
        Map.entry("minecraft:pipeline/armor_translucent", 0),
        Map.entry("minecraft:pipeline/banner_pattern", 0),
        Map.entry("minecraft:pipeline/item_cutout", 0),
        Map.entry("minecraft:pipeline/item_translucent", 0),
        Map.entry("minecraft:pipeline/solid_block", 1),
        Map.entry("minecraft:pipeline/cutout_block", 1),
        Map.entry("minecraft:pipeline/translucent_block", 1),
        Map.entry("minecraft:pipeline/opaque_particle", 2),
        Map.entry("minecraft:pipeline/translucent_particle", 2)
    );

    private static final Set<String> SKY_UNIFORMS = Set.of("DynamicTransforms", "Projection", "Fog");
    private static final Set<String> CELESTIAL_UNIFORMS = Set.of("DynamicTransforms", "Projection", "Sampler0");
    private static final Set<String> MATRIX_UNIFORMS = Set.of("DynamicTransforms", "Projection");

    private static final String FLIP = "out.gl_Position.y = -(out.gl_Position.y);";
    private static final String VERTEX_ENTRY = "vertex main0_out main0(";
    private static final String FRAGMENT_ENTRY = "fragment main0_out main0(";
    private static final Pattern COLOR0 = Pattern.compile("(?:float4|half4)\\s+(\\w+)\\s*\\[\\[color\\(0\\)\\]\\]");
    private static final Pattern DT_PARAM = Pattern.compile("constant\\s+DynamicTransforms\\s*&\\s*(\\w+)\\s*\\[\\[buffer\\(\\d+\\)\\]\\]");
    private static final Pattern FOG_PARAM = Pattern.compile("constant\\s+Fog\\s*&\\s*(\\w+)\\s*\\[\\[buffer\\(\\d+\\)\\]\\]");
    private static final Pattern SODIUM_GLOBALS_PARAM = Pattern.compile("constant\\s+u_Globals\\s*&\\s*(\\w+)\\s*\\[\\[buffer\\(\\d+\\)\\]\\]");
    private static final Pattern FRONT_FACING_PARAM = Pattern.compile("bool\\s+(\\w+)\\s*\\[\\[front_facing\\]\\]");

    private ShadeShaderPatcher() {}

    /**
     * Selects the world pack whose MSL the world renderer compiles from. {@code key} identifies the source set (pack id plus
     * anything that changes its generated defines): when it changes, every cached source is dropped and {@link #epoch()}
     * moves on, so {@code CelestiaShade} and every {@code CelestiaPipeline} rebuild their world shaders on next use.
     *
     * @param source  reads {@code shaders/<name>} from the pack, or null for Celestia Native
     * @param defines {@code #define} lines from the pack's {@code "recompile"} options, put in front of every world prelude
     * @return true when the source set changed
     */
    public static synchronized boolean setWorldPack(String key, PackSource source, String defines) {
        String d = defines == null ? "" : defines;
        if (key.equals(worldPackKey) && d.equals(worldPackDefines)) return false;
        worldPack = source;
        worldPackKey = key;
        worldPackDefines = d;
        RESOURCE_CACHE.clear();
        epoch++;
        return true;
    }

    /** Bumped whenever the world pack's sources change (pack switch, recompile option, reload). */
    public static int epoch() {
        return epoch;
    }

    public static String worldPackKey() {
        return worldPackKey;
    }

    /** Drops cached sources and moves the epoch on without changing the pack (shader reload of a pack under development). */
    public static synchronized void invalidate() {
        RESOURCE_CACHE.clear();
        epoch++;
    }

    public static String resource(String name) {
        return RESOURCE_CACHE.computeIfAbsent(name, ShadeShaderPatcher::load);
    }

    private static String load(String name) {
        if (ENGINE_FILES.contains(name)) return classpath(ENGINE_BASE + name);
        PackSource pack = worldPack;
        if (pack != null) {
            String own = pack.read(name);
            if (own != null) return own;
        }
        return classpath(DEFAULT_PACK_SHADERS + name);
    }

    private static String classpath(String path) {
        try (InputStream in = ShadeShaderPatcher.class.getResourceAsStream(path)) {
            if (in == null) {
                throw new IllegalStateException("Missing shader resource: " + path);
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public static String prelude(boolean hdr, boolean hand, String extraDefines) {
        return prelude(hdr, hand, extraDefines, true);
    }

    public static String prelude(boolean hdr, boolean hand, String extraDefines, boolean includeVanillaUniforms) {
        StringBuilder sb = new StringBuilder(16384);
        sb.append("#define MCOPT_SHADE 1\n");
        if (hdr) sb.append("#define MCOPT_HDR 1\n");
        boolean dynLights = hdr && dev.celestia.metal.shade.light.DynLights.ON;
        if (dynLights) sb.append("#define SHADE_DYNLIGHT 1\n");
        boolean colorLights = hdr && dev.celestia.metal.shade.light.ColorLights.ON;
        if (colorLights) sb.append("#define SHADE_COLORLIGHT 1\n");
        if (hand) sb.append("#define MCOPT_HAND 1\n");
        if (extraDefines != null && !extraDefines.isEmpty()) {
            sb.append(extraDefines);
            if (!extraDefines.endsWith("\n")) sb.append('\n');
        }
        sb.append(worldPackDefines);
        sb.append(resource("shade_slots.metal")).append('\n');
        sb.append(resource("shade_api.metal")).append('\n');
        sb.append(resource("shade_look.metal")).append('\n');
        sb.append(resource("shade_common.metal")).append('\n');
        sb.append(resource("shade_m2.metal")).append('\n');
        sb.append(resource("shade_dims.metal")).append('\n');
        if (dynLights) sb.append(dev.celestia.metal.shade.light.DynLightMsl.module()).append('\n');
        if (colorLights) sb.append(resource("colorlight.metal")).append('\n');
        if (includeVanillaUniforms) {
            sb.append(resource("vanilla_uniforms.metal")).append('\n');
        }
        return sb.toString();
    }

    public static String lookOnlyPrelude() {
        return "#define MCOPT_SHADE 1\n#define MCOPT_HDR 1\n" + worldPackDefines
            + resource("shade_slots.metal") + "\n"
            + resource("shade_api.metal") + "\n"
            + resource("shade_look.metal") + "\n";
    }

    public static String postSource() {
        return prelude(true, false, "#define CELESTIA_VL_COMPOSITE 1\n#define CELESTIA_SSAO 1")
            + resource("vl.metal") + "\n" + resource("ssao.metal") + "\n"
            + resource("shade_post.metal") + "\n" + resource("motion_blur.metal") + "\n";
    }

    public static String atmosphereSource() {
        return prelude(true, false, "#define CELESTIA_VL_MARCH 1\n#define SHADE_WX_NOISE_BAKE 1", false)
            + resource("shade_post.metal") + "\n" + resource("clouds.metal") + "\n"
            + resource("vl.metal") + "\n" + resource("weather_surface.metal") + "\n"
            + resource("aurora.metal") + "\n";
    }

    public static String waterDefines() {
        return waterDefines(true);
    }

    private static String waterDefines(boolean screenReflections) {
        String quad = !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.water.ssrQuad"))
            ? "#define SHADE_SSR_QUAD 1\n#define SHADE_SSRH_OWN 1\n" : "";
        String reflections = screenReflections ? "#define SHADE_SSR 1\n" : "";
        return quad + reflections + """
            #define SHADE_WATER 1
            #define SHADE_SSR_HIER 1
            #define SHADE_SSRH_L2 1
            #define SHADE_SSRH_THICK 2.0
            #define SHADE_SSRH_THIN 1
            #define SHADE_SSR_STEPS 24
            #define SHADE_SSR_RAWZ 1
            #define SHADE_SSR_LEAN2 1
            #define SHADE_SSR_EDGE 1
            #define SHADE_SSR_THICK_K 1.5
            #define SHADE_SSR_BEHIND 0
            #define SHADE_SSR_TOP 0.15
            #define SHADE_SSR_SIDE 0.25
            #define SHADE_SSR_SIDE_END 0.0
            #define SHADE_SSR_PREV 1
            #define SHADE_CAUSTICS 1
            #define SHADE_FOAM 1
            #define SHADE_GLOSSY 1
            #define SHADE_WATER_DETAIL 1
            #define SHADE_WATER_DETAIL_SIZE 256
            #define SHADE_WATER_DETAIL_FAR 112.0
            #define SHADE_WATER_PATTERN_FAR 0.075
            #define SHADE_WATER_SMOOTH 1
            #define SHADE_WATER_GLINT_GRAZE 1
            #define SHADE_WAVE_BAKE 1
            #define SHADE_WATER_SWELL 1
            #define SHADE_WATER_SWELL_BAKED 1
            #define SHADE_WATER_GLITTER 1
            #define SHADE_WATER_SUBRECT 1
            """;
    }

    public static String waterBakeSource() {
        return prelude(true, false, waterDefines(), false)
            + resource("shade_post.metal") + "\n"
            + resource("water.metal") + "\n";
    }

    public static String skyLutSource() {
        return prelude(true, false, null) + resource("sky_lut.metal") + "\n";
    }

    public static String shadowSodiumSource() {
        return resource("shadow_sodium.metal");
    }

    public static String shadowVanillaSource() {
        return resource("shadow_vanilla.metal");
    }

    /**
     * Produces patched MSL vertex/fragment stages for the requested variant, falling back safely to base
     * or {@link #patchHdrFragment} if a shader stage does not match the expected structure.
     */
    public static PatchedStages patch(String pipelineName,
                                      String baseVs, String baseVsEntry,
                                      String baseFs, String baseFsEntry,
                                      List<BindGroupLayout.UniformDescription> uniforms,
                                      List<MetalShaderTranslator.SlotBinding> bindings,
                                      Variant variant) {
        if (variant == Variant.BASE) {
            return new PatchedStages(baseVs, baseVsEntry, baseFs, baseFsEntry, false);
        }
        String name = pipelineName != null ? pipelineName : "";
        String lower = name.toLowerCase(Locale.ROOT);
        String slotDefines = MetalShaderTranslator.slotDefines(uniforms, bindings);

        if (variant == Variant.HDR_HAND) {
            if (isEntityPipeline(name) && baseFs != null) {
                PatchedStages entity = patchEntity(name, baseVs, baseVsEntry, baseFs, baseFsEntry, true);
                if (entity != null) return entity;
            }
            return new PatchedStages(baseVs, baseVsEntry, baseFs, baseFsEntry, false);
        }

        // HDR_WORLD variant
        // 1. Dedicated sky, celestial, stars, sunrise/sunset, and clouds stages
        if ("minecraft:pipeline/sky".equals(lower) && hasUniforms(uniforms, SKY_UNIFORMS) && baseFs != null) {
            String pre = prelude(true, false, slotDefines);
            return new PatchedStages(pre + resource("sky.vs.metal"), "main0", pre + resource("sky.fs.metal"), "main0", true);
        }
        if ("minecraft:pipeline/celestial".equals(lower) && hasUniforms(uniforms, CELESTIAL_UNIFORMS) && baseFs != null) {
            String pre = prelude(true, false, slotDefines);
            return new PatchedStages(pre + resource("celestial.vs.metal"), "main0", pre + resource("celestial.fs.metal"), "main0", true);
        }
        if ("minecraft:pipeline/end_sky".equals(lower) && hasUniforms(uniforms, CELESTIAL_UNIFORMS) && baseFs != null) {
            String pre = prelude(true, false, slotDefines);
            return new PatchedStages(pre + resource("end_sky.vs.metal"), "main0", pre + resource("end_sky.fs.metal"), "main0", true);
        }
        if ("minecraft:pipeline/sunrise_sunset".equals(lower) && hasUniforms(uniforms, MATRIX_UNIFORMS)) {
            String pre = prelude(true, false, slotDefines);
            String fs = baseFs != null ? patchHdrFragment(baseFs) : null;
            return new PatchedStages(pre + resource("sunrise_sunset.vs.metal"), "main0", fs, baseFsEntry, true);
        }
        if ("minecraft:pipeline/stars".equals(lower) && hasUniforms(uniforms, MATRIX_UNIFORMS)) {
            String pre = prelude(true, false, slotDefines);
            String fs = baseFs != null ? patchHdrFragment(baseFs) : null;
            return new PatchedStages(pre + resource("stars.vs.metal"), "main0", fs, baseFsEntry, true);
        }
        if (("minecraft:pipeline/clouds".equals(lower) || "minecraft:pipeline/flat_clouds".equals(lower))
            && hasUniforms(uniforms, Set.of("CloudInfo")) && baseFs != null && !lower.contains("oit")) {
            String pre = prelude(true, false, slotDefines);
            return new PatchedStages(baseVs, baseVsEntry, pre + resource("clouds.fs.metal"), "main0", true);
        }

        // 2. Vanilla & Sodium 0.9.x terrain (opaque/cutout & P3a translucent water)
        if (baseFs != null && isOpaqueOrCutoutTerrain(lower, baseVs)) {
            PatchedStages terrain = patchTerrain(lower, baseVs, baseVsEntry, baseFs, baseFsEntry);
            if (terrain != null) return terrain;
        }
        if (baseFs != null && isTranslucentTerrain(lower, baseVs)) {
            PatchedStages waterTerrain = patchTerrainCommon(lower, baseVs, baseVsEntry, baseFs, baseFsEntry, variant);
            if (waterTerrain != null) return waterTerrain;
        }

        // 3. Vanilla entities, moving blocks, items, particles
        if (baseFs != null && isEntityPipeline(lower)) {
            PatchedStages entity = patchEntity(lower, baseVs, baseVsEntry, baseFs, baseFsEntry, false);
            if (entity != null) return entity;
        }

        // 4. Generic world fallback: convert display-referred color(0) to scene-linear pre-exposed HDR
        boolean fastWeather = "minecraft:pipeline/weather".equals(lower);
        String patchedFs = baseFs != null ? patchHdrFragment(baseFs, fastWeather) : null;
        return new PatchedStages(baseVs, baseVsEntry, patchedFs, baseFsEntry, patchedFs != null && !patchedFs.equals(baseFs));
    }

    public static boolean isOpaqueOrCutoutTerrain(String pipelineNameLower, String vsMsl) {
        if (pipelineNameLower == null) return false;
        if (pipelineNameLower.contains("oit") || pipelineNameLower.contains("translucent")
            || pipelineNameLower.contains("tripwire") || pipelineNameLower.contains("_block")) {
            return false;
        }
        boolean nameLooksTerrain = pipelineNameLower.contains("terrain")
            || pipelineNameLower.contains("chunk")
            || pipelineNameLower.contains("sodium")
            || pipelineNameLower.contains("block_layer");
        if (!nameLooksTerrain) return false;
        return isSodiumTerrainVs(vsMsl) || isVanillaTerrainVs(vsMsl);
    }

    public static boolean isTranslucentTerrainPipelineName(String pipelineName) {
        if (pipelineName == null) return false;
        String lower = pipelineName.toLowerCase(Locale.ROOT);
        if (lower.contains("oit") || lower.contains("tripwire") || lower.contains("_block") || !lower.contains("translucent")) {
            return false;
        }
        return lower.contains("terrain") || lower.contains("chunk") || lower.contains("sodium") || lower.contains("block_layer");
    }

    public static boolean isTranslucentTerrain(String pipelineNameLower, String vsMsl) {
        return isTranslucentTerrainPipelineName(pipelineNameLower)
            && (isSodiumTerrainVs(vsMsl) || isVanillaTerrainVs(vsMsl));
    }

    public static boolean isSodiumTerrainVs(String vsMsl) {
        return vsMsl != null && (vsMsl.contains("a_LightAndData") || vsMsl.contains("u_Globals") || vsMsl.contains("u_RegionOffset"));
    }

    public static boolean isVanillaTerrainVs(String vsMsl) {
        return vsMsl != null && vsMsl.contains(" UV2 ") && vsMsl.contains(" Color ");
    }

    public static boolean isEntityPipeline(String pipelineNameLower) {
        return pipelineNameLower != null && ENTITY_PIPELINES.containsKey(pipelineNameLower);
    }

    /**
     * Patches any SPIRV-Cross fragment shader to convert its display-referred output to pre-exposed HDR
     * radiance via {@code shadeLdrToHdr}.
     */
    public static String patchHdrFragment(String msl) {
        return patchHdrFragment(msl, false);
    }

    private static String patchHdrFragment(String msl, boolean fastWeather) {
        if (msl == null) return null;
        int sig = msl.indexOf(FRAGMENT_ENTRY);
        if (sig < 0) return msl;
        Matcher m = COLOR0.matcher(msl);
        if (!m.find() || m.start() > sig) return msl;
        String member = m.group(1);
        int close = findClosingParen(msl, sig + FRAGMENT_ENTRY.length() - 1);
        if (close < 0) return msl;
        String head = msl.substring(0, close)
            + ", constant ShadeLook& celestiaShadeLook [[buffer(" + MetalConst.SHADE_BUF_LOOK + ")]]";
        String body = msl.substring(close).replace("return out;",
            "{ out." + member + " = shadeLdrToHdr(out." + member + ", celestiaShadeLook); return out; }");
        return (fastWeather ? "#define CELESTIA_WEATHER_FAST_HDR 1\n" : "") + lookOnlyPrelude() + head + body;
    }

    private static final String TERRAIN_OUT_MEMBERS =
        "    float3 mcoptPos [[user(locn12)]];\n"
        + "    float4 mcoptColor [[user(locn13)]];\n"
        + "    float2 mcoptLight [[user(locn14)]];\n";

    private static final Pattern GL_POS_FIELD = Pattern.compile("\\bfloat4\\s+gl_Position\\s*\\[\\[position\\]\\];");
    private static final Pattern STRUCT_MAIN0_IN = Pattern.compile("struct\\s+main0_in\\s*\\{");
    private static final Pattern FRAG_POSITION_PARAM = Pattern.compile("\\bfloat4\\s+(\\w+)\\s*\\[\\[position\\]\\]");
    private static final Pattern TEXCOORD_FIELD = Pattern.compile("\\bfloat2\\s+(\\w*(?:texcoord|uv)\\w*)\\s*\\[\\[user\\(", Pattern.CASE_INSENSITIVE);

    static PatchedStages patchTerrain(String pipelineNameLower,
                                      String vsMsl, String vsEntry,
                                      String fsMsl, String fsEntry) {
        return patchTerrainCommon(pipelineNameLower, vsMsl, vsEntry, fsMsl, fsEntry, null);
    }

    private static PatchedStages patchTerrainCommon(String pipelineNameLower,
                                                    String vsMsl, String vsEntry,
                                                    String fsMsl, String fsEntry,
                                                    Variant waterVariant) {
        if (vsMsl == null || fsMsl == null) return null;
        boolean translucentWater = waterVariant != null;
        boolean sodium = isSodiumTerrainVs(vsMsl);
        String inVs = structBody(vsMsl, "main0_in");
        String outVs = structBody(vsMsl, "main0_out");
        String posExpr = extractProjectedPosition(vsMsl);
        Matcher glPosM = outVs != null ? GL_POS_FIELD.matcher(vsMsl) : null;
        if (inVs == null || outVs == null || posExpr == null || glPosM == null || !glPosM.find()
            || !vsMsl.contains(FLIP) || !vsMsl.contains(VERTEX_ENTRY)) {
            return null;
        }
        String colorExpr;
        String lightExpr;
        if (sodium) {
            if (!inVs.contains("a_Color") || !inVs.contains("a_LightAndData")) return null;
            colorExpr = "float4(in.a_Color)";
            lightExpr = "clamp((float2(in.a_LightAndData.xy) - 8.0) * (1.0 / 240.0), 0.0, 1.0)";
        } else {
            if (!inVs.contains("Color") || !inVs.contains("UV2")) return null;
            colorExpr = "float4(in.Color)";
            lightExpr = "float2(in.UV2) * (1.0 / 240.0)";
        }

        String patchedVs = glPosM.replaceFirst(Matcher.quoteReplacement(TERRAIN_OUT_MEMBERS + "    " + glPosM.group()));
        patchedVs = patchedVs.replace(FLIP,
            "out.mcoptPos = " + posExpr + ";\n"
            + "    out.mcoptColor = " + colorExpr + ";\n"
            + "    out.mcoptLight = " + lightExpr + ";\n"
            + "    " + FLIP);

        String inFs = structBody(fsMsl, "main0_in");
        String outFs = structBody(fsMsl, "main0_out");
        int sig = fsMsl.indexOf(FRAGMENT_ENTRY);
        if (inFs == null || outFs == null || sig < 0) return null;
        Matcher colorMatcher = COLOR0.matcher(outFs);
        if (!colorMatcher.find()) return null;
        String colorMember = colorMatcher.group(1);

        int close = findClosingParen(fsMsl, sig + FRAGMENT_ENTRY.length() - 1);
        int ret = fsMsl.lastIndexOf("return out;");
        if (close < 0 || ret < close) return null;

        String texelCaptured = captureTerrainTexel(fsMsl, sig, close, ret, sodium);
        if (texelCaptured == null) return null;

        Matcher inFsM = STRUCT_MAIN0_IN.matcher(texelCaptured);
        if (!inFsM.find()) return null;
        int inFsEnd = texelCaptured.indexOf("};", inFsM.end());
        if (inFsEnd < 0) return null;

        int pSig = texelCaptured.indexOf(FRAGMENT_ENTRY);
        int pClose = findClosingParen(texelCaptured, pSig + FRAGMENT_ENTRY.length() - 1);
        int pRet = texelCaptured.lastIndexOf("return out;");

        String chunkVis = inFs.contains("chunkVisibility") ? "in.chunkVisibility"
            : (inFs.contains("v_fadeFactor") ? "in.v_fadeFactor" : "1.0");
        boolean isCutout = pipelineNameLower.contains("cutout") || fsMsl.contains("discard_fragment()");

        String fogExpr = "float4(1e6, 1e6, 1e6, 1e6)";
        Matcher fogM = FOG_PARAM.matcher(texelCaptured);
        Matcher sgM = SODIUM_GLOBALS_PARAM.matcher(texelCaptured);
        if (sodium && sgM.find(pSig) && sgM.start() < pClose) {
            String g = sgM.group(1);
            fogExpr = "float4(" + g + ".u_EnvironmentFog.x, " + g + ".u_EnvironmentFog.y, "
                + g + ".u_RenderFog.x, " + g + ".u_RenderFog.y)";
        } else if (fogM.find(pSig) && fogM.start() < pClose) {
            String fg = fogM.group(1);
            fogExpr = "float4(" + fg + ".FogEnvironmentalStart, " + fg + ".FogEnvironmentalEnd, "
                + fg + ".FogRenderDistanceStart, " + fg + ".FogRenderDistanceEnd)";
        }

        String shadeParams = ", constant ShadeFrame& celSF [[buffer(" + MetalConst.SHADE_BUF_FRAME + ")]]"
            + ", constant ShadeLook& celSL [[buffer(" + MetalConst.SHADE_BUF_LOOK + ")]]"
            + ", constant ShadeGpu& celSG [[buffer(" + MetalConst.SHADE_BUF_GPU + ")]]"
            + ", constant ShadeResources& celSR [[buffer(" + MetalConst.SHADE_BUF_RESOURCES + ")]]"
            + ", depth2d_array<float> celShadow [[texture(" + MetalConst.SHADE_TEX_SHADOW + ")]]"
            + ", sampler celShadowCmp [[sampler(" + MetalConst.SHADE_SAMP_SHADOW + ")]]"
            + ", texture2d<half> celLut [[texture(" + MetalConst.SHADE_TEX_SKY_LUT + ")]]"
            + ", sampler celLutSmplr [[sampler(" + MetalConst.SHADE_SAMP_LINEAR + ")]]"
            + dynLightParams() + colorLightParams();

        String shadeCall;
        StringBuilder fs = new StringBuilder(texelCaptured.length() + (translucentWater ? 65536 : 4096));
        String fragPosName;
        Matcher fpM = FRAG_POSITION_PARAM.matcher(texelCaptured);
        if (fpM.find(pSig) && fpM.start() < pClose) {
            fragPosName = fpM.group(1);
        } else {
            fragPosName = "celFragCoord";
            shadeParams += ", float4 celFragCoord [[position]]";
        }
        Matcher uvField = TEXCOORD_FIELD.matcher(inFs);
        String uvExpr = inFs.contains("v_TexCoord") ? "in.v_TexCoord" : inFs.contains("texCoord0") ? "in.texCoord0"
            : uvField.find() ? "in." + uvField.group(1) : "float2(0.0)";
        if (translucentWater) {
            shadeParams += ", texture2d<half> celSceneCopy [[texture(" + MetalConst.SHADE_TEX_WATER_SCENE + ")]]"
                + ", depth2d<float> celDepthCopy [[texture(" + MetalConst.SHADE_TEX_WATER_DEPTH + ")]]"
                + ", constant ShadeWaterParams& celWP [[buffer(" + MetalConst.SHADE_BUF_WATER + ")]]"
                + ", texture2d<half> celWaterWaves [[texture(" + MetalConst.SHADE_TEX_WATER_WAVES + ")]]"
                + ", texture2d<float> celWaterCoarse [[texture(" + MetalConst.SHADE_TEX_WATER_PYR + ")]]"
                + ", texture2d<half> celWaterDetail [[texture(" + MetalConst.SHADE_TEX_WATER_DETAIL + ")]]";
            shadeCall = "    out." + colorMember + " = shadeWaterTerrainShade(out." + colorMember
                + ", celTexel, in.mcoptColor, in.mcoptPos, in.mcoptLight, " + uvExpr + ", " + fragPosName
                + ", " + chunkVis + ", " + fogExpr
                + ", celLut, celLutSmplr, celShadow, celShadowCmp, celSF, celSL, celSG, celSR"
                + ", celSceneCopy, celDepthCopy, celWP, celWaterWaves, celWaterCoarse, celWaterDetail CEL_DL_ARGS CEL_CL_ARGS);\n";

            boolean withoutSwellOrCaustics = waterVariant == Variant.HDR_WORLD_WATER_ABOVE_SKY_ONLY_NO_SWELL_CAUSTICS
                || waterVariant == Variant.HDR_WORLD_WATER_ABOVE_FAST_SKY_NO_SWELL_CAUSTICS;
            boolean fastSky = waterVariant == Variant.HDR_WORLD_WATER_ABOVE_FAST_SKY
                || waterVariant == Variant.HDR_WORLD_WATER_ABOVE_FAST_SKY_NO_SWELL_CAUSTICS;
            boolean screenReflections = waterVariant == Variant.HDR_WORLD || waterVariant == Variant.HDR_WORLD_WATER_ABOVE;
            String defines = waterDefines(screenReflections) + "#define SHADE_WEATHER 1\n#define SHADE_RIPPLES 1\n#define SHADE_RIPPLE_LAYERS 1\n";
            if (withoutSwellOrCaustics) defines += "#undef SHADE_WATER_SWELL\n#undef SHADE_CAUSTICS\n";
            // (pricing, dev only) -Dcelestiametal.shade.water.devUndef=WATER_PANO,CAUSTICS,...: compile those SHADE_* features out
            // of the water shader, to price each one with its share of the register pressure (a branch skipping it doesn't)
            for (String f : System.getProperty("celestiametal.shade.water.devUndef", "").split(",")) {
                if (f.matches("[A-Z0-9_]+")) defines += "#undef SHADE_" + f + "\n";
            }
            for (String f : System.getProperty("celestiametal.shade.water.devDefine", "").split(",")) {
                if (f.matches("[A-Z0-9_]+")) defines += "#define SHADE_" + f + " 1\n";
            }
            if (fastSky) defines += "#define SHADE_OWN_TRANSLUCENT 1\n#define SHADE_WOFF_FAST 1\n";
            if (waterVariant != Variant.HDR_WORLD && waterVariant != Variant.HDR_WORLD_WATER_SKY_ONLY) {
                defines += "#define SHADE_LEAN_ABOVE 1\n";
            }
            fs.append(prelude(true, false, defines, false));
            fs.append(resource("shade_material.metal")).append('\n');
            fs.append(resource("weather_surface.metal")).append('\n');
            fs.append(resource("water.metal")).append('\n');
            fs.append(resource("shade_water_terrain.metal")).append('\n');
        } else {
            shadeCall = "    out." + colorMember + " = shadeTerrainShade(out." + colorMember
                + ", celTexel, in.mcoptColor, in.mcoptPos, in.mcoptLight, " + fragPosName + ".xy,\n"
                + "#ifdef CELESTIA_TERRAIN_MATERIAL_UV\n        " + uvExpr + ",\n#endif\n        " + chunkVis + ", "
                + (isCutout ? "true" : "false") + ", " + fogExpr
                + ", celLut, celLutSmplr, celShadow, celShadowCmp, celSF, celSL, celSG, celSR CEL_DL_ARGS CEL_CL_ARGS);\n";

            fs.append(prelude(true, false, null, false));
            fs.append(resource("shade_material.metal")).append('\n');
            fs.append(resource("weather_surface.metal")).append('\n');
            fs.append(resource("shade_terrain.metal")).append('\n');
        }

        fs.append(texelCaptured, 0, inFsEnd);
        fs.append(TERRAIN_OUT_MEMBERS);
        fs.append(texelCaptured, inFsEnd, pClose);
        fs.append(shadeParams);
        fs.append(texelCaptured, pClose, pRet);
        fs.append(shadeCall);
        fs.append(texelCaptured, pRet, texelCaptured.length());

        return new PatchedStages(patchedVs, vsEntry, fs.toString(), fsEntry, true);
    }

    /** Fragment-main parameters for the dynamic lights (buffer 29, textures 24/25), or "" with the module off. */
    static String dynLightParams() {
        if (!dev.celestia.metal.shade.light.DynLights.ON) return "";
        return ", constant ShadeDynLights& celDL [[buffer(" + MetalConst.SHADE_BUF_DYNLIGHTS + ")]]"
            + ", texture3d<half> celDlIrr [[texture(" + MetalConst.SHADE_TEX_DL_IRR + ")]]"
            + ", texture3d<half> celDlDir [[texture(" + MetalConst.SHADE_TEX_DL_DIR + ")]]";
    }

    /** Fragment-main parameters for the coloured block light (buffer 30, textures 26/27), or "" with the module off. */
    static String colorLightParams() {
        if (!dev.celestia.metal.shade.light.ColorLights.ON) return "";
        return ", constant ShadeColorLights& celCL [[buffer(" + MetalConst.SHADE_BUF_COLORLIGHT + ")]]"
            + ", texture3d<float> celClFine [[texture(" + MetalConst.SHADE_TEX_CL_FINE + ")]]"
            + ", texture3d<float> celClCoarse [[texture(" + MetalConst.SHADE_TEX_CL_COARSE + ")]]"
            + ", texture3d<float> celClLevels [[texture(" + MetalConst.SHADE_TEX_CL_LEVELS + ")]]";
    }

    private static String captureTerrainTexel(String fsMsl, int sig, int close, int ret, boolean sodium) {
        int brace = fsMsl.indexOf('{', close);
        if (brace < 0 || brace >= ret) return null;
        String body = fsMsl.substring(brace + 1, ret);
        String vtxColorField = sodium ? "v_Color" : "vertexColor";

        // Case 1: `color *= in.v_Color;` or `_NN *= in.vertexColor;`
        Pattern mulAssign = Pattern.compile("\\b(\\w+)\\s*\\*=\\s*in\\." + vtxColorField + "\\s*;");
        Matcher m1 = mulAssign.matcher(body);
        if (m1.find()) {
            String varName = m1.group(1);
            String patchedBody = m1.replaceFirst("celTexel = " + varName + "; " + Matcher.quoteReplacement(m1.group(0)));
            return fsMsl.substring(0, brace + 1) + "\n    float4 celTexel = float4(1.0);" + patchedBody + fsMsl.substring(ret);
        }

        // Case 2: `float4 color = <expr> * in.vertexColor;` (or `float4 _NN = (<expr>) * in.v_Color;`)
        Pattern mulInline = Pattern.compile("([^=\\n;{}]+)\\s*\\*\\s*in\\." + vtxColorField + "\\s*;");
        Matcher m2 = mulInline.matcher(body);
        if (m2.find()) {
            String lhsExpr = m2.group(1).trim();
            String rep = "((celTexel = (" + lhsExpr + ")) * in." + vtxColorField + ");";
            String patchedBody = m2.replaceFirst(Matcher.quoteReplacement(rep));
            return fsMsl.substring(0, brace + 1) + "\n    float4 celTexel = float4(1.0);" + patchedBody + fsMsl.substring(ret);
        }
        return null;
    }

    private static final String ENTITY_OUT_MEMBERS =
        "    float3 mcoptPos [[user(locn12)]];\n"
        + "    float3 mcoptNrm [[user(locn13)]];\n"
        + "    float4 mcoptColor [[user(locn14)]];\n"
        + "    float2 mcoptLight [[user(locn15)]];\n";

    static PatchedStages patchEntity(String pipelineNameLower,
                                     String vsMsl, String vsEntry,
                                     String fsMsl, String fsEntry,
                                     boolean hand) {
        Integer kindObj = ENTITY_PIPELINES.get(pipelineNameLower);
        if (kindObj == null || vsMsl == null || fsMsl == null) return null;
        int kind = hand ? 3 : kindObj;

        String inVs = structBody(vsMsl, "main0_in");
        String outVs = structBody(vsMsl, "main0_out");
        String posExpr = extractProjectedPosition(vsMsl);
        Matcher glPosM = outVs != null ? GL_POS_FIELD.matcher(vsMsl) : null;
        if (inVs == null || outVs == null || posExpr == null || glPosM == null || !glPosM.find()
            || !vsMsl.contains(FLIP) || !vsMsl.contains(VERTEX_ENTRY)) {
            return null;
        }
        if (!inVs.contains(" Color ") || !inVs.contains(" UV2 ")) return null;
        String nrmExpr = inVs.contains(" Normal ") ? "in.Normal" : "float3(0.0)";

        String patchedVs = glPosM.replaceFirst(Matcher.quoteReplacement(ENTITY_OUT_MEMBERS + "    " + glPosM.group()));
        patchedVs = patchedVs.replace(FLIP,
            "out.mcoptPos = " + posExpr + ";\n"
            + "    out.mcoptNrm = " + nrmExpr + ";\n"
            + "    out.mcoptColor = float4(in.Color);\n"
            + "    out.mcoptLight = float2(in.UV2) * (1.0 / 240.0);\n"
            + "    " + FLIP);

        String inFs = structBody(fsMsl, "main0_in");
        String outFs = structBody(fsMsl, "main0_out");
        int sig = fsMsl.indexOf(FRAGMENT_ENTRY);
        if (inFs == null || outFs == null || sig < 0) return null;
        Matcher colorMatcher = COLOR0.matcher(outFs);
        if (!colorMatcher.find()) return null;
        if (!fsMsl.contains("texture2d<float> Sampler0 [[texture(") || !inFs.contains("texCoord0")
            || fsMsl.contains("GlintSampler") || fsMsl.contains("[[position]]")) {
            return null;
        }
        String member = colorMatcher.group(1);
        int close = findClosingParen(fsMsl, sig + FRAGMENT_ENTRY.length() - 1);
        int ret = fsMsl.lastIndexOf("return out;");
        if (close < 0 || ret < close) return null;

        Matcher dt = DT_PARAM.matcher(fsMsl);
        Matcher fog = FOG_PARAM.matcher(fsMsl);
        boolean hasDt = dt.find(sig) && dt.start() < close;
        boolean hasFog = fog.find(sig) && fog.start() < close;
        Matcher fr = FRONT_FACING_PARAM.matcher(fsMsl.substring(sig, close));
        String front = fr.find() ? fr.group(1) : "celFront";

        StringBuilder params = new StringBuilder();
        params.append(", constant ShadeFrame& celSF [[buffer(").append(MetalConst.SHADE_BUF_FRAME).append(")]]")
            .append(", constant ShadeLook& celSL [[buffer(").append(MetalConst.SHADE_BUF_LOOK).append(")]]")
            .append(", constant ShadeGpu& celSG [[buffer(").append(MetalConst.SHADE_BUF_GPU).append(")]]")
            .append(", constant ShadeResources& celSR [[buffer(").append(MetalConst.SHADE_BUF_RESOURCES).append(")]]")
            .append(", depth2d_array<float> celShadow [[texture(").append(MetalConst.SHADE_TEX_SHADOW).append(")]]")
            .append(", sampler celShadowCmp [[sampler(").append(MetalConst.SHADE_SAMP_SHADOW).append(")]]")
            .append(", texture2d<half> celLut [[texture(").append(MetalConst.SHADE_TEX_SKY_LUT).append(")]]")
            .append(", sampler celLutSmplr [[sampler(").append(MetalConst.SHADE_SAMP_LINEAR).append(")]]")
            .append(", float4 celFrag [[position]]")
            .append(dynLightParams()).append(colorLightParams());
        if ("celFront".equals(front)) {
            params.append(", bool celFront [[front_facing]]");
        }

        String overlay = inFs.contains("overlayColor") ? "in.overlayColor" : "float4(0.0, 0.0, 0.0, 1.0)";
        String modulator = hasDt ? dt.group(1) + ".ColorModulator" : "float4(1.0)";
        String fogV = hasFog
            ? "float4(" + fog.group(1) + ".FogEnvironmentalStart, " + fog.group(1) + ".FogEnvironmentalEnd, "
                + fog.group(1) + ".FogRenderDistanceStart, " + fog.group(1) + ".FogRenderDistanceEnd)"
            : "float4(1e6, 1e6, 1e6, 1e6)";

        String shade = "    out." + member + " = shadeEntityShade(out." + member
            + ", Sampler0.sample(Sampler0Smplr, in.texCoord0) * in.mcoptColor * " + modulator + ", "
            + overlay + ", in.mcoptPos, in.mcoptNrm, in.mcoptLight, " + front + ", celFrag, " + kind + ", " + fogV
            + ", celLut, celLutSmplr, celShadow, celShadowCmp, celSF, celSL, celSG, celSR CEL_DL_ARGS CEL_CL_ARGS);\n";

        Matcher inFsM = STRUCT_MAIN0_IN.matcher(fsMsl);
        if (!inFsM.find()) return null;
        int inEnd = fsMsl.indexOf("};", inFsM.end());
        if (inEnd < 0) return null;

        StringBuilder fs = new StringBuilder(fsMsl.length() + 4096);
        fs.append(prelude(true, hand, null, false));
        fs.append(resource("shade_entity.metal")).append('\n');
        fs.append(fsMsl, 0, inEnd);
        fs.append(ENTITY_OUT_MEMBERS);
        fs.append(fsMsl, inEnd, close);
        fs.append(params);
        fs.append(fsMsl, close, ret);
        fs.append(shade);
        fs.append(fsMsl, ret, fsMsl.length());

        return new PatchedStages(patchedVs, vsEntry, fs.toString(), fsEntry, true);
    }

    private static boolean hasUniforms(List<BindGroupLayout.UniformDescription> uniforms, Set<String> required) {
        if (uniforms == null) return false;
        for (String req : required) {
            boolean found = false;
            for (BindGroupLayout.UniformDescription u : uniforms) {
                if (req.equals(u.name())) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    private static String structBody(String msl, String name) {
        Matcher m = Pattern.compile("struct\\s+" + Pattern.quote(name) + "\\s*\\{").matcher(msl);
        if (!m.find()) return null;
        int b = msl.indexOf("};", m.end());
        return b < 0 ? null : msl.substring(m.start(), b);
    }

    private static int findClosingParen(String s, int openIdx) {
        if (openIdx < 0 || openIdx >= s.length() || s.charAt(openIdx) != '(') return -1;
        int depth = 0;
        for (int i = openIdx; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '(') depth++;
            else if (c == ')' && --depth == 0) return i;
        }
        return -1;
    }

    /**
     * Extracts {@code <posExpr>} from {@code out.gl_Position = <mat> * float4(<posExpr>, 1.0);}.
     */
    static String extractProjectedPosition(String vsMsl) {
        int assign = vsMsl.indexOf("out.gl_Position =");
        while (assign >= 0) {
            int semi = vsMsl.indexOf(';', assign);
            if (semi < 0) break;
            String stmt = vsMsl.substring(assign, semi);
            int f4 = stmt.lastIndexOf("float4(");
            if (f4 >= 0) {
                int start = f4 + "float4(".length();
                int depth = 1;
                int topComma = -1;
                for (int i = start; i < stmt.length(); i++) {
                    char c = stmt.charAt(i);
                    if (c == '(') depth++;
                    else if (c == ')') {
                        depth--;
                        if (depth == 0) break;
                    } else if (c == ',' && depth == 1) {
                        topComma = i;
                        break;
                    }
                }
                if (topComma > start) {
                    String after = stmt.substring(topComma + 1).trim();
                    if (after.startsWith("1.0")) {
                        return stmt.substring(start, topComma).trim();
                    }
                }
            }
            assign = vsMsl.indexOf("out.gl_Position =", semi + 1);
        }
        return null;
    }
}
