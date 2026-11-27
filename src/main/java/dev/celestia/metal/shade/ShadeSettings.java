package dev.celestia.metal.shade;

import dev.celestia.metal.shader.pack.ShaderOptionState;

/** The options applied to a complete world frame. The options editor keeps its own mutable copy. */
public record ShadeSettings(Shadows shadows, Lights lights, Sky sky, Water water, Atmosphere atmosphere, Post post) {
    public record Shadows(boolean enabled, int resolution, int distance, int farInterval, float softness,
                          boolean ssao, float ssaoStrength) {}
    /** Dynamic lights (P6a) and coloured block light (P6b): the modules are startup switches, these are read every frame. */
    public record Lights(boolean dynamic, float strength, int count, boolean entities,
                         boolean colored, float coloredStrength, float coloredGlow, boolean smoothBlock) {}
    public record Sky(boolean stars, boolean haze, float hazeStrength) {}
    public record Water(boolean enabled, boolean waves, float waveStrength, float swell, boolean screenReflections,
                        float reflectionStrength, int ssrBudget, int ssrDistance, float caustics, float foam) {}
    public record Atmosphere(boolean clouds, int cloudSteps, float cloudCoverage, float cloudDensity, float cloudSpeed,
                             boolean volumetrics, int lightSteps, float lightStrength, boolean weather) {}
    public record Post(int look, boolean bloom, float bloomStrength, float exposureEv, float saturation, float pastel) {}

    public static ShadeSettings from(ShaderOptionState s) {
        String reflections = s.get("WATER_REFLECTIONS");
        float reflectionStrength = reflections.equals("OFF") ? 0f : value(s, "REFLECTION_STRENGTH");
        return new ShadeSettings(
            new Shadows(s.getBoolean("SHADOWS_ENABLED"), s.getInt("SHADOW_RES"), s.getInt("SHADOW_DISTANCE"),
                s.getInt("SHADOW_FAR_INTERVAL"), value(s, "SHADOW_SOFTNESS"),
                s.getBoolean("SSAO_ENABLED"), value(s, "SSAO_STRENGTH")),
            new Lights(s.getBoolean("DYNAMIC_LIGHTS"), value(s, "DYNAMIC_LIGHT_STRENGTH"), s.getInt("DYNAMIC_LIGHT_COUNT"),
                s.getBoolean("DYNAMIC_LIGHT_ENTITIES"), s.getBoolean("COLORED_LIGHTS"), value(s, "COLORED_LIGHT_STRENGTH"),
                value(s, "COLORED_LIGHT_GLOW"), s.getBoolean("SMOOTH_BLOCK_LIGHT")),
            new Sky(s.getBoolean("STARFIELD_ENABLED"), s.getBoolean("AERIAL_FOG"), value(s, "HAZE_STRENGTH")),
            new Water(s.getBoolean("WATER_ENABLED"), s.getBoolean("WATER_WAVES"), value(s, "WAVE_STRENGTH"),
                value(s, "WATER_SWELL"), reflections.equals("SSR_AND_SKY") && reflectionStrength > 0f,
                reflectionStrength,
                s.getInt("SSR_BUDGET"), s.getInt("SSR_DISTANCE"), value(s, "WATER_CAUSTICS"), value(s, "WATER_FOAM")),
            new Atmosphere(s.getBoolean("CLOUDS_ENABLED"), s.getInt("CLOUD_STEPS"), value(s, "CLOUD_COVERAGE"),
                value(s, "CLOUD_DENSITY"), value(s, "CLOUD_SPEED"), s.getBoolean("GOD_RAYS"),
                s.getInt("VL_STEPS"), value(s, "VL_STRENGTH"), s.getBoolean("WEATHER_ENABLED")),
            new Post(switch (s.get("COLOR_LOOK")) {
                case "STORYBOOK" -> 1;
                case "NATURAL" -> 2;
                case "PASTEL" -> 3;
                default -> 0;
            }, s.getBoolean("BLOOM_ENABLED"), value(s, "BLOOM_STRENGTH"), value(s, "EXPOSURE"), value(s, "SATURATION"),
                value(s, "PASTEL_STRENGTH"))
        );
    }

    private static float value(ShaderOptionState state, String key) {
        return (float) state.getDouble(key);
    }
}
