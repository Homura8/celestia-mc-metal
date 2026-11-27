package celestiaqa;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.function.Predicate;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.core.BlockPos;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;

/**
 * Scripted in-game QA for Celestia Metal (see docs/QA.md; launched by tools/qa/run.sh). Runs the modes listed in
 * -Dcelestiaqa.modes, in order, in one game session, then quits. Every wait is a condition (chunks built, exposure snapped,
 * rain at its target) with a short minimum and a timeout, not a fixed delay.
 *
 * <p>System properties: celestiaqa.modes (shots,profile,perf,lights,frames), celestiaqa.create (make the QA world when it is
 * missing), celestiaqa.preset (Celestia preset, default Ultra), celestiaqa.options (KEY=V,...), celestiaqa.pack (off = pack off),
 * celestiaqa.scenes (comma filter), celestiaqa.prefix (screenshot prefix), celestiaqa.devs (profile: dev switches),
 * celestiaqa.profileEvery (profile: submits per [GPU] report), celestiaqa.frames (frames: count), celestiaqa.debug (debug view).
 */
public final class Qa {
    static final boolean CELESTIA = FabricLoader.getInstance().isModLoaded("celestia-metal");
    static final String WORLD = "CelestiaQA";
    static final long SEED = 20261128L;

    /** A step runs every tick until it returns true. */
    interface Step {
        boolean run(Minecraft mc);
    }

    private static final List<Step> STEPS = new ArrayList<>();
    private static int t = -1, step, stepStart, frames, stepFrames;
    private static boolean built, bootstrapped;
    static final double[] SAMPLES = new double[8192];
    static int samples;
    static boolean sampling;

    private Qa() {}

    // ---- helpers ------------------------------------------------------------------------------------------------------------
    static void log(String s) {
        System.out.println("[QA] " + s);
    }

    static void cmd(Minecraft mc, String c) {
        IntegratedServer s = mc.getSingleplayerServer();
        if (s != null) s.execute(() -> s.getCommands().performPrefixedCommand(s.createCommandSourceStack(), c));
    }

    static int elapsed() {
        return t - stepStart;
    }

    static int elapsedFrames() {
        return frames - stepFrames;
    }

    static Step once(java.util.function.Consumer<Minecraft> r) {
        return mc -> {
            r.accept(mc);
            return true;
        };
    }

    static Step ticks(int n) {
        return mc -> elapsed() >= n;
    }

    static Step frames(int n) {
        return mc -> elapsedFrames() >= n;
    }

    /**
     * Until everything has settled: the next frame snaps exposure (Celestia), then at least {@code min} ticks for the temporal
     * passes (TAA, cloud and reflection histories) and until every visible chunk section is built and {@code extra} holds;
     * {@code max} ticks at most.
     */
    static Step settle(int min, int max, Predicate<Minecraft> extra) {
        return mc -> {
            if (elapsed() == 0 && CELESTIA) CelestiaHooks.snap();
            if (elapsed() == min / 2 && CELESTIA) CelestiaHooks.snap(); // (again once the chunks around have streamed in)
            boolean ready = elapsed() >= min && mc.levelRenderer.hasRenderedAllSections() && (extra == null || extra.test(mc));
            if (elapsed() >= max) log("settle timed out after " + max + " ticks");
            return ready || elapsed() >= max;
        };
    }

    static void screenshot(Minecraft mc, String name) {
        Screenshot.grab(mc.gameDirectory, name + ".png", mc.gameRenderer.mainRenderTarget(), 1, c -> { });
    }

    static String prefix() {
        return System.getProperty("celestiaqa.prefix", CELESTIA ? "celestia" : "ref");
    }

    /** The renderer's configuration for this run (Celestia only): preset, then options, or the pack off. */
    static void configure() {
        if (!CELESTIA) return;
        if ("off".equals(System.getProperty("celestiaqa.pack"))) {
            CelestiaHooks.selectPack("off");
            return;
        }
        CelestiaHooks.presetWith(System.getProperty("celestiaqa.preset", "Ultra"), System.getProperty("celestiaqa.options"));
        String dbg = System.getProperty("celestiaqa.debug");
        if (dbg != null) CelestiaHooks.debugView(Integer.parseInt(dbg));
    }

    // ---- world --------------------------------------------------------------------------------------------------------------
    /** At the title screen: open the QA world, creating it (fixed seed, normal terrain, spectator) the first time. */
    private static void bootstrap(Minecraft mc) {
        if (bootstrapped || !(mc.screen instanceof TitleScreen) || !Boolean.getBoolean("celestiaqa.create")) return;
        bootstrapped = true;
        if (mc.getLevelSource().levelExists(WORLD)) {
            log("opening " + WORLD);
            mc.createWorldOpenFlows().openWorld(WORLD, () -> { });
            return;
        }
        log("creating " + WORLD + " (seed " + SEED + ")");
        LevelSettings settings = new LevelSettings(WORLD, GameType.SPECTATOR,
            new LevelSettings.DifficultySettings(Difficulty.PEACEFUL, false, false), true, WorldDataConfiguration.DEFAULT);
        mc.createWorldOpenFlows().createFreshLevel(WORLD, settings, new WorldOptions(SEED, true, false),
            WorldPresets::createNormalWorldDimensions, mc.screen);
    }

    /**
     * The test scene (once per world: a marker block below the floor records it): a walled pond floating at y 141-147, so its
     * water has no air pockets around it, with an end stone pillar, a sandstone pillar and a glass column standing in it. Every
     * fill stays under 32768 blocks (and the whole build ~45k: big fills stall chunk rebuilds and lighting).
     */
    private static void buildScene(List<Step> s) {
        s.add(once(mc -> {
            cmd(mc, "gamemode spectator @a");
            cmd(mc, "difficulty peaceful");
            cmd(mc, "gamerule minecraft:advance_time false");
            cmd(mc, "gamerule minecraft:advance_weather false");
            cmd(mc, "weather clear");
            cmd(mc, "tp @a 0.5 160 0.5");
        }));
        s.add(settle(20, 400, null));
        s.add(mc -> {
            if (mc.level.getBlockState(new BlockPos(0, 139, 0)).is(Blocks.LODESTONE)) {
                log("scene already built");
                return true;
            }
            log("building the test scene");
            cmd(mc, "fill -25 140 -25 25 148 25 minecraft:smooth_sandstone");
            cmd(mc, "fill -24 141 -24 24 148 24 minecraft:air");
            cmd(mc, "fill -24 141 -24 24 147 24 minecraft:water");
            cmd(mc, "fill -11 141 10 -6 157 14 minecraft:end_stone_bricks");
            cmd(mc, "fill 8 141 12 9 158 13 minecraft:cut_sandstone");
            cmd(mc, "fill -1 141 13 1 150 15 minecraft:glass");
            cmd(mc, "setblock 0 139 0 minecraft:lodestone");
            cmd(mc, "setworldspawn 0 160 0");
            return true;
        });
        s.add(settle(40, 600, null));
    }

    // ---- modes --------------------------------------------------------------------------------------------------------------
    private static List<Step> build() {
        List<Step> s = new ArrayList<>();
        buildScene(s);
        s.add(once(mc -> configure()));
        s.add(settle(60, 600, null)); // (pipelines for the configuration compile)
        for (String mode : System.getProperty("celestiaqa.modes", "shots").split(",")) {
            switch (mode.trim()) {
                case "shots" -> Shots.add(s);
                case "profile" -> Modes.profile(s);
                case "perf" -> Modes.perf(s);
                case "lights" -> Modes.lights(s);
                case "frames" -> Modes.frames(s);
                default -> log("unknown mode " + mode);
            }
        }
        s.add(once(mc -> {
            log("done");
            mc.stop();
        }));
        return s;
    }

    public static void tick(Minecraft mc) {
        if (mc.level == null) {
            bootstrap(mc);
            return;
        }
        if (mc.player == null || mc.getSingleplayerServer() == null) return;
        t++;
        if (!built) {
            built = true;
            STEPS.addAll(build());
            stepStart = t;
            stepFrames = frames;
            log("renderer " + (CELESTIA ? "celestia" : "other") + ", " + STEPS.size() + " steps");
        }
        if (sampling && samples < SAMPLES.length && CELESTIA) {
            double g = CelestiaHooks.gpuMs();
            if (g > 0) SAMPLES[samples++] = g;
        }
        while (step < STEPS.size()) {
            boolean done;
            try {
                done = STEPS.get(step).run(mc);
            } catch (Throwable e) {
                log("step " + step + " failed: " + e);
                e.printStackTrace();
                done = true;
            }
            if (!done) return;
            step++;
            stepStart = t;
            stepFrames = frames;
        }
    }

    public static void frame(Minecraft mc) {
        frames++;
        Modes.onFrame(mc);
    }

    static String fmt(String f, Object... a) {
        return String.format(Locale.ROOT, f, a);
    }
}
