package dev.celestia.metal.ui;

import dev.celestia.metal.shader.pack.ShaderOptionDef;
import java.util.List;
import java.util.function.Consumer;
import java.util.function.DoubleConsumer;
import java.util.function.DoubleSupplier;
import java.util.function.Function;
import java.util.function.IntConsumer;
import java.util.function.IntSupplier;
import java.util.function.Supplier;

/**
 * Declarative row model for Celestia Metal's tabbed Video Settings screen.
 */
public sealed interface OptionEntry permits
    OptionEntry.Header,
    OptionEntry.Toggle,
    OptionEntry.IntSlider,
    OptionEntry.FloatSlider,
    OptionEntry.Cycle,
    OptionEntry.Action {

    String label();
    String description();
    ShaderOptionDef.Impact impact();

    default boolean matches(String query) {
        if (query == null || query.isBlank()) return true;
        String q = query.toLowerCase(java.util.Locale.ROOT);
        return label().toLowerCase(java.util.Locale.ROOT).contains(q)
            || description().toLowerCase(java.util.Locale.ROOT).contains(q);
    }

    record Header(String label) implements OptionEntry {
        @Override public String description() { return ""; }
        @Override public ShaderOptionDef.Impact impact() { return ShaderOptionDef.Impact.NEGLIGIBLE; }
        @Override public boolean matches(String query) { return query == null || query.isBlank(); }
    }

    record Toggle(
        String label,
        String description,
        ShaderOptionDef.Impact impact,
        Supplier<Boolean> getter,
        Consumer<Boolean> setter
    ) implements OptionEntry {}

    record IntSlider(
        String label,
        String description,
        ShaderOptionDef.Impact impact,
        int min,
        int max,
        int step,
        IntSupplier getter,
        IntConsumer setter,
        Function<Integer, String> formatter
    ) implements OptionEntry {}

    record FloatSlider(
        String label,
        String description,
        ShaderOptionDef.Impact impact,
        double min,
        double max,
        double step,
        DoubleSupplier getter,
        DoubleConsumer setter,
        Function<Double, String> formatter
    ) implements OptionEntry {}

    record Cycle<T>(
        String label,
        String description,
        ShaderOptionDef.Impact impact,
        List<T> values,
        Supplier<T> getter,
        Consumer<T> setter,
        Function<T, String> formatter
    ) implements OptionEntry {}

    record Action(
        String label,
        String description,
        String buttonLabel,
        ShaderOptionDef.Impact impact,
        Runnable action
    ) implements OptionEntry {}
}
