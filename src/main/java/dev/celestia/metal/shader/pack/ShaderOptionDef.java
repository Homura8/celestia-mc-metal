package dev.celestia.metal.shader.pack;

import java.util.List;

/**
 * Typed shader pack option definition shared across Native MSL packs and Iris/OptiFine GLSL packs.
 */
public record ShaderOptionDef(
    String id,
    String label,
    String description,
    String category,
    Kind kind,
    String defaultValue,
    List<String> values,
    double min,
    double max,
    double step,
    Impact impact,
    boolean recompile
) {
    /**
     * An option read at run time (ShadeSettings uniforms, Iris defines, legacy pass defines). {@code recompile} options of a world
     * pack are compiled into its MSL as {@code #define}s instead, and changing one rebuilds the world shaders.
     */
    public ShaderOptionDef(String id, String label, String description, String category, Kind kind, String defaultValue,
                           List<String> values, double min, double max, double step, Impact impact) {
        this(id, label, description, category, kind, defaultValue, values, min, max, step, impact, false);
    }

    public enum Kind {
        TOGGLE,
        ENUM,
        INT_SLIDER,
        FLOAT_SLIDER
    }

    public enum Impact {
        NEGLIGIBLE("Negligible", 0xFF9ED4B8),
        LOW("Low", 0xFFC8B3E4),
        MEDIUM("Medium", 0xFFE7CDE1),
        HIGH("High", 0xFFE9BCCD);

        public final String label;
        public final int color;

        Impact(String label, int color) {
            this.label = label;
            this.color = color;
        }
    }

    public static ShaderOptionDef toggle(String id, String label, String desc, String category, boolean def, Impact impact) {
        return new ShaderOptionDef(id, label, desc, category, Kind.TOGGLE, Boolean.toString(def), List.of("false", "true"), 0, 1, 1, impact);
    }

    public static ShaderOptionDef enumOpt(String id, String label, String desc, String category, String def, List<String> values, Impact impact) {
        return new ShaderOptionDef(id, label, desc, category, Kind.ENUM, def, List.copyOf(values), 0, values.size() - 1, 1, impact);
    }

    public static ShaderOptionDef intSlider(String id, String label, String desc, String category, int def, int min, int max, int step, Impact impact) {
        return new ShaderOptionDef(id, label, desc, category, Kind.INT_SLIDER, Integer.toString(def), List.of(), min, max, step, impact);
    }

    public static ShaderOptionDef floatSlider(String id, String label, String desc, String category, double def, double min, double max, double step, Impact impact) {
        return new ShaderOptionDef(id, label, desc, category, Kind.FLOAT_SLIDER, Double.toString(def), List.of(), min, max, step, impact);
    }
}
