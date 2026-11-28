package celestiaqa;

import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import net.minecraft.resources.ResourceKey;
import net.minecraft.world.level.Level;

/**
 * The comparison scenes (the same for any renderer: Celestia, or Iris + a reference pack) and the screenshot mode. Positions are
 * around the QA world's pond (Qa.buildScene): its water spans y 141-147 (surface ~147.9), pillars at z 10-15.
 */
final class Shots {
    /** name, time of day, weather, dimension, tp command (feet position, yaw, pitch). */
    record Scene(String name, int time, String weather, ResourceKey<Level> dimension, String tp) {
        Scene(String name, int time, String weather, String tp) {
            this(name, time, weather, Level.OVERWORLD, tp);
        }
    }

    static final List<Scene> SCENES = List.of(
        new Scene("pond-morning", 1500, "clear", "tp @a 0.5 149.3 -14.5 0 -8"),
        new Scene("pond-noon", 6000, "clear", "tp @a 0.5 149.3 -14.5 0 -8"),
        new Scene("pond-sunset", 12300, "clear", "tp @a 0.5 149.3 -14.5 -90 -6"),
        new Scene("pond-night", 18000, "clear", "tp @a 0.5 149.3 -14.5 0 -10"),
        // the spawn spot looking into the pond's corner at sunset: the low sun grazes the north wall edge-on (shadow acne's worst case)
        new Scene("pond-corner-sunset", 12300, "clear", "tp @a 0.5 150.5 0.5 135 6"),
        new Scene("underwater", 1500, "clear", "tp @a 0.5 144.0 -14.5 0 -4"),
        new Scene("underwater-noon", 6000, "clear", "tp @a 0.5 143.0 -14.5 0 0"), // (sun overhead: the shafts come down)
        new Scene("underwater-up", 6000, "clear", "tp @a 0.5 143.0 -14.5 0 -45"),
        new Scene("ground-noon", 6000, "clear", "execute in minecraft:overworld positioned 128.5 0 -32.5"
            + " positioned over motion_blocking_no_leaves run tp @a ~ ~1 ~ 135 4"),
        // The plains village on the coast at (-352, 256) in the QA seed: houses, paths, grass, docks and the bay. Real-play
        // views for performance: the floating pond above is a worst case with nothing else on screen. (Fixed heights: the ground
        // there is y 65 and 64; a heightmap lookup in the tp itself runs before the far-off chunks load.)
        new Scene("village-noon", 6000, "clear", "tp @a -330.5 65 256.5 90 4"),
        new Scene("village-sunset", 12300, "clear", "tp @a -330.5 65 256.5 90 4"),
        new Scene("village-night", 18000, "clear", "tp @a -330.5 65 256.5 90 4"),
        new Scene("village-high", 6000, "clear", "tp @a -318.5 78 256.5 90 18"),
        new Scene("village-shore", 6000, "clear", "tp @a -330.5 67 240.5 135 6"),
        // the sandbar next to the village: shallow water over sand (shore foam, caustics, the waves' travel direction)
        new Scene("beach", 6000, "clear", "tp @a -380.5 72 232.5 100 25"),
        new Scene("beach-sunset", 12300, "clear", "tp @a -380.5 72 232.5 100 25"), // (grazing sun on the sand)
        new Scene("village-sunset-back", 12300, "clear", "tp @a -330.5 65 256.5 -90 4"), // (sun behind the camera: faces away from it)
        new Scene("village-shore-sunset", 12300, "clear", "tp @a -330.5 67 240.5 135 6"),
        new Scene("vista-noon", 6000, "clear", "tp @a 40.5 210 40.5 135 12"),
        new Scene("vista-sunset", 12300, "clear", "tp @a 40.5 210 40.5 135 12"),
        new Scene("vista-up", 6000, "clear", "tp @a 40.5 210 40.5 135 -35"),
        new Scene("vista-night", 18000, "clear", "tp @a 40.5 210 40.5 135 -10"),
        new Scene("vista-rain", 6000, "rain", "tp @a 40.5 210 40.5 135 12"),
        new Scene("village-rain", 6000, "rain", "tp @a -330.5 65 256.5 90 4"), // (last Overworld: rain and wetness take long to clear)
        new Scene("nether", 6000, "clear", Level.NETHER, "execute in minecraft:the_nether run tp @a 0.5 100 0.5 135 30"), // (open air above the nether wastes)
        new Scene("end", 6000, "clear", Level.END, "execute in minecraft:the_end run tp @a 0.5 76 -48.5 0 8"));

    private Shots() {}

    /**
     * The default suite (celestiaqa.scenes unset): the real plains village, which is what the owner plays in (houses, foliage,
     * water, docks). The floating test pond and the vistas are worst cases and special views: name them, or "all" for every scene.
     */
    static final List<String> DEFAULT_SCENES = List.of("village-noon", "village-sunset", "village-night", "village-high",
        "village-shore", "village-shore-sunset", "beach", "village-rain");

    static List<Scene> selected() {
        String f = System.getProperty("celestiaqa.scenes", "");
        if (f.isEmpty()) return SCENES.stream().filter(sc -> DEFAULT_SCENES.contains(sc.name())).toList();
        if (f.equals("all")) return SCENES;
        Set<String> want = Arrays.stream(f.split(",", -1)).map(String::trim).collect(Collectors.toSet());
        List<Scene> selected = SCENES.stream().filter(sc -> want.contains(sc.name())).toList();
        if (selected.size() != want.size()) throw new IllegalArgumentException("Unknown QA scene in " + f);
        return selected;
    }

    /** Sets the time, weather and camera of a scene (the settle step after it waits for the result). */
    static Qa.Step enter(Scene sc) {
        return Qa.once(mc -> {
            if (sc.dimension() == Level.OVERWORLD) {
                Qa.cmd(mc, "time set " + sc.time());
                Qa.cmd(mc, "weather " + sc.weather());
                String tp = sc.tp().startsWith("tp ") ? "execute in minecraft:overworld run " + sc.tp() : sc.tp();
                Qa.cmd(mc, tp);
            } else {
                Qa.cmd(mc, sc.tp());
            }
        });
    }

    /** Waits for a scene: the common settle, plus the rain at its target (and, in rain, time for surfaces to get wet). */
    static Qa.Step settle(Scene sc) {
        boolean overworld = sc.dimension() == Level.OVERWORLD;
        boolean rain = overworld && "rain".equals(sc.weather());
        // (the village and the beach are ~435 blocks from spawn: their chunks generate and load after the teleport)
        boolean far = sc.name().startsWith("village") || sc.name().equals("beach");
        return Qa.settle(rain ? 240 : (far ? 160 : overworld ? 40 : 80), 600, mc -> {
            if (mc.level == null || mc.level.dimension() != sc.dimension()) return false;
            if (!overworld) return true;
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
            Qa.addFrameTiming(s, sc.name(), Integer.getInteger("celestiaqa.measureFrames", 0));
        }
        if (selected().stream().anyMatch(sc -> "rain".equals(sc.weather()))) {
            s.add(Qa.once(mc -> Qa.cmd(mc, "execute in minecraft:overworld run weather clear")));
            s.add(Qa.settle(20, 600, mc -> mc.level == null || mc.level.dimension() != Level.OVERWORLD || mc.level.getRainLevel(1f) <= 0.01f));
        }
    }

    static Scene byName(String name) {
        return SCENES.stream().filter(sc -> sc.name().equals(name)).findFirst().orElseThrow();
    }

}
