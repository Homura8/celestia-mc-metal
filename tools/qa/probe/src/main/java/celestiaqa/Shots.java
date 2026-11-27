package celestiaqa;

import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * The comparison scenes (the same for any renderer: Celestia, or Iris + a reference pack) and the screenshot mode. Positions are
 * around the QA world's pond (Qa.buildScene): its water spans y 141-147 (surface ~147.9), pillars at z 10-15.
 */
final class Shots {
    /** name, time of day, weather, tp command (feet position, yaw, pitch). */
    record Scene(String name, int time, String weather, String tp) {}

    static final List<Scene> SCENES = List.of(
        new Scene("pond-morning", 1500, "clear", "tp @a 0.5 149.3 -14.5 0 -8"),
        new Scene("pond-noon", 6000, "clear", "tp @a 0.5 149.3 -14.5 0 -8"),
        new Scene("pond-sunset", 12300, "clear", "tp @a 0.5 149.3 -14.5 -90 -6"),
        new Scene("underwater", 1500, "clear", "tp @a 0.5 144.0 -14.5 0 -4"),
        new Scene("underwater-noon", 6000, "clear", "tp @a 0.5 143.0 -14.5 0 0"), // (sun overhead: the shafts come down)
        new Scene("vista-noon", 6000, "clear", "tp @a 40.5 210 40.5 135 12"),
        new Scene("vista-sunset", 12300, "clear", "tp @a 40.5 210 40.5 135 12"),
        new Scene("vista-up", 6000, "clear", "tp @a 40.5 210 40.5 135 -35"),
        new Scene("vista-night", 18000, "clear", "tp @a 40.5 210 40.5 135 -10"),
        new Scene("vista-rain", 6000, "rain", "tp @a 40.5 210 40.5 135 12")); // (last: rain and wetness take long to clear)

    private Shots() {}

    static List<Scene> selected() {
        String f = System.getProperty("celestiaqa.scenes", "");
        if (f.isEmpty()) return SCENES;
        Set<String> want = Arrays.stream(f.split(",", -1)).map(String::trim).collect(Collectors.toSet());
        List<Scene> selected = SCENES.stream().filter(sc -> want.contains(sc.name())).toList();
        if (selected.size() != want.size()) throw new IllegalArgumentException("Unknown QA scene in " + f);
        return selected;
    }

    /** Sets the time, weather and camera of a scene (the settle step after it waits for the result). */
    static Qa.Step enter(Scene sc) {
        return Qa.once(mc -> {
            Qa.cmd(mc, "time set " + sc.time());
            Qa.cmd(mc, "weather " + sc.weather());
            Qa.cmd(mc, sc.tp());
        });
    }

    /** Waits for a scene: the common settle, plus the rain at its target (and, in rain, time for surfaces to get wet). */
    static Qa.Step settle(Scene sc) {
        boolean rain = "rain".equals(sc.weather());
        return Qa.settle(rain ? 240 : 40, 600, mc -> {
            float r = mc.level.getRainLevel(1f);
            return rain ? r >= 0.99f : r <= 0.01f;
        });
    }

    static void add(List<Qa.Step> s) {
        for (Scene sc : selected()) {
            s.add(enter(sc));
            boolean fixed = Boolean.getBoolean("celestiaqa.fixedShots");
            s.add(fixed ? Qa.ticks(240) : settle(sc));
            // celestiaqa.repeat=N: a burst of N shots celestiaqa.repeatTicks apart (animated effects: waves, shafts, caustics)
            int repeat = Math.max(1, Integer.getInteger("celestiaqa.repeat", 1));
            int every = Math.max(1, Integer.getInteger("celestiaqa.repeatTicks", 10));
            for (int k = 0; k < repeat; k++) {
                String name = Qa.prefix() + "-" + sc.name() + (repeat > 1 ? "-" + k : "");
                s.add(Qa.once(mc -> {
                    Qa.screenshot(mc, name);
                    Qa.log("shot " + name + " settled " + Qa.lastWaitTicks() + " ticks | fps " + mc.getFps() + (Qa.CELESTIA ? Qa.fmt(" gpu %.2f ms", CelestiaHooks.gpuMs()) : ""));
                }));
                s.add(Qa.ticks(k + 1 < repeat ? every : 2));
            }
        }
        s.add(Qa.once(mc -> Qa.cmd(mc, "weather clear")));
        s.add(Qa.settle(20, 600, mc -> mc.level.getRainLevel(1f) <= 0.01f));
    }

    static Scene byName(String name) {
        return SCENES.stream().filter(sc -> sc.name().equals(name)).findFirst().orElseThrow();
    }

}
