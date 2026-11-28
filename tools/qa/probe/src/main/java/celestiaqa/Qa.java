package celestiaqa;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Predicate;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.core.BlockPos;
import net.minecraft.network.chat.contents.TranslatableContents;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.LevelSettings;
import net.minecraft.world.level.WorldDataConfiguration;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;

/**
 * Scripted in-game QA for Celestia Metal (see docs/QA.md; launched by tools/qa/run.sh). Runs the modes listed in
 * -Dcelestiaqa.modes, in order, in one game session, then quits. Scene waits use chunk and weather readiness with a
 * minimum history warm-up. Measurements and light captures retain fixed windows.
 *
 * <p>System properties: celestiaqa.modes (shots,profile,perf,lights,frames,packs,scales), celestiaqa.create (make the QA world when it is
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
    private static int t = -1, step, stepStart, frames, stepFrames, lastWaitTicks;
    private static boolean built, bootstrapped;
    private static final double[] SAMPLES = new double[240];
    private static int samples;
    private static boolean sampling;
    private static double[] frameTimes;
    private static int timedFrames;
    private static long lastFrameTime;
    private static float timedPanYaw;
    private static final AtomicInteger PENDING_SHOTS = new AtomicInteger();
    private static volatile String screenshotFailure;
    private static int captures;

    static void startSampling() {
        Minecraft mc = Minecraft.getInstance();
        if (mc != null) focus(mc);
        samples = 0;
        sampling = true;
    }

    static double[] finishSampling() {
        sampling = false;
        return Arrays.copyOf(SAMPLES, samples);
    }

    static void addFrameTiming(List<Step> steps, String scene, int count) {
        if (count == 0) return;
        if (count < 100 || count > 10000) throw new IllegalArgumentException("Timing requires 100–10000 frames");
        float pan = Float.parseFloat(System.getProperty("celestiaqa.timedPanYaw", "0"));
        if (!Float.isFinite(pan)) throw new IllegalArgumentException("Invalid timed pan yaw");
        steps.add(once(mc -> {
            focus(mc);
            focusLost = false;
            frameTimes = new double[count];
            timedFrames = 0;
            lastFrameTime = 0L;
            timedPanYaw = pan;
        }));
        steps.add(mc -> {
            if (!mc.getWindow().isFocused()) focusLost = true;
            return timedFrames == count;
        });
        steps.add(once(mc -> {
            double[] times = frameTimes;
            frameTimes = null;
            double mean = Arrays.stream(times).average().orElseThrow();
            Arrays.sort(times);
            double p99 = times[(int) Math.ceil(count * 0.99) - 1];
            String scale = CELESTIA ? CelestiaHooks.renderScaleLabel() : "native";
            log(fmt("timing %-16s %6.1f fps | p99 %5.2f ms | %d frames | %s | output %dx%d%s", scene, 1000.0 / mean,
                p99, count, scale, mc.gameRenderer.mainRenderTarget().width, mc.gameRenderer.mainRenderTarget().height,
                pan == 0f ? "" : fmt(" | pan %.2f°/frame", pan)) + (focusLost ? " | UNFOCUSED (macOS throttles background windows: discard)" : ""));
        }));
    }

    private static boolean focusLost;

    /**
     * Brings the game window to the front. macOS throttles a window behind others (occlusion, App Nap), so a run started in
     * the background, or clicked into focus halfway, times differently: timings are taken in front, and say when focus was lost.
     */
    static void focus(Minecraft mc) {
        long handle = mc.getWindow().handle();
        if (handle != 0L) org.lwjgl.sdl.SDLVideo.SDL_RaiseWindow(handle);
    }

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

    static int lastWaitTicks() {
        return lastWaitTicks;
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
        capture(mc, name, 1);
    }

    static boolean screenshotsReady(Minecraft mc) {
        if (PENDING_SHOTS.get() > 0) {
            if (elapsed() >= 1200) throw new IllegalStateException("Screenshot write timed out");
            return false;
        }
        if (screenshotFailure != null) throw new IllegalStateException(screenshotFailure);
        return true;
    }

    static void captureFrame(Minecraft mc, String name) {
        var target = mc.gameRenderer.mainRenderTarget();
        // The exported frames top out at 1100 px. Downsample Retina sequences before encoding PNGs.
        boolean canHalve = Math.max(target.width, target.height) >= 2200
            && target.width % 2 == 0 && target.height % 2 == 0;
        capture(mc, name, canHalve ? 2 : 1);
    }

    private static void capture(Minecraft mc, String name, int downscale) {
        PENDING_SHOTS.incrementAndGet();
        captures++;
        Screenshot.grab(mc.gameDirectory, name + ".png", mc.gameRenderer.mainRenderTarget(), downscale, result -> {
            if (!(result.getContents() instanceof TranslatableContents translated)
                || !"screenshot.success".equals(translated.getKey())) {
                screenshotFailure = name + ": " + result.getString();
            }
            PENDING_SHOTS.decrementAndGet();
        });
    }

    static String prefix() {
        return System.getProperty("celestiaqa.prefix", CELESTIA ? "celestia" : "ref");
    }

    /** The renderer's configuration for this run (Celestia only): preset, then options, or the pack off. */
    static void configure() {
        if (!CELESTIA) return;
        Integer scale = Integer.getInteger("celestiaqa.renderScale");
        if (scale != null) CelestiaHooks.setRenderScale(scale);
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
        if (bootstrapped || !(mc.gui.screen() instanceof TitleScreen) || !Boolean.getBoolean("celestiaqa.create")) return;
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
            WorldPresets::createNormalWorldDimensions, mc.gui.screen());
    }

    /**
     * The test scene (once per world: a marker block below the floor records it): a walled pond floating at y 141-147, so its
     * water has no air pockets around it, with an end stone pillar, a sandstone pillar and a glass column standing in it. Every
     * fill stays under 32768 blocks (and the whole build ~45k: big fills stall chunk rebuilds and lighting).
     */
    private static void buildScene(List<Step> s) {
        s.add(once(mc -> {
            focus(mc); // (in front for the whole run: see focus)
            cmd(mc, "gamemode spectator @a");
            cmd(mc, "difficulty peaceful");
            cmd(mc, "gamerule minecraft:advance_time false");
            cmd(mc, "gamerule minecraft:advance_weather false");
            cmd(mc, "gamerule minecraft:spawn_mobs false");
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
        s.add(mc -> {
            if (mc.level.getBlockState(new BlockPos(0, 139, 0)).is(Blocks.LODESTONE)
                && mc.level.getBlockState(new BlockPos(0, 145, 0)).is(Blocks.WATER)) return true;
            if (elapsed() >= 600) throw new IllegalStateException("Pond did not build");
            return false;
        });
    }

    // ---- modes --------------------------------------------------------------------------------------------------------------
    private static List<Step> build() {
        List<Step> s = new ArrayList<>();
        buildScene(s);
        // celestiaqa.commands="locate structure #minecraft:village;..." runs server commands before the modes; their replies
        // land in client.log as "System chat" lines (for finding new scene locations in the QA seed)
        String extra = System.getProperty("celestiaqa.commands", "");
        if (!extra.isBlank()) {
            for (String c : extra.split(";")) {
                if (c.isBlank()) continue;
                s.add(once(mc -> cmd(mc, c.trim())));
                s.add(ticks(60)); // (lets a teleport's chunks load before a command that reads them)
            }
        }
        s.add(once(mc -> configure()));
        s.add(settle(30, 600, null));
        var modes = new HashSet<String>();
        for (String token : System.getProperty("celestiaqa.modes", "shots").split(",", -1)) {
            String mode = token.trim();
            if (!modes.add(mode)) throw new IllegalArgumentException("Repeated mode " + mode);
            if (!CELESTIA && List.of("profile", "perf", "lights", "packs", "scales").contains(mode)) {
                throw new IllegalArgumentException(mode + " requires Celestia Metal");
            }
            s.add(once(mc -> log("mode " + mode)));
            switch (mode) {
                case "shots" -> Shots.add(s);
                case "profile" -> Modes.profile(s);
                case "perf" -> Modes.perf(s);
                case "lights" -> Modes.lights(s);
                case "packs" -> Modes.packs(s);
                case "scales" -> Modes.scales(s);
                case "frames" -> Modes.frames(s);
                default -> throw new IllegalArgumentException("Unknown mode " + mode);
            }
            s.add(once(mc -> log("finished " + mode)));
        }
        s.add(Qa::screenshotsReady);
        s.add(once(mc -> {
            log("saved " + captures + " screenshots");
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
            boolean showHud = Boolean.getBoolean("celestiaqa.showHud");
            if (mc.gui.hud.isHidden() == showHud) mc.gui.hud.toggle();
            if (CELESTIA) CelestiaHooks.configurePerformanceHud(showHud);
            try {
                Integer frameLimit = Integer.getInteger("celestiaqa.frameLimit");
                if (frameLimit != null) mc.options.framerateLimit().set(frameLimit);
                Integer weatherRadius = Integer.getInteger("celestiaqa.weatherRadius");
                if (weatherRadius != null) mc.options.weatherRadius().set(weatherRadius);
                Integer renderDistance = Integer.getInteger("celestiaqa.renderDistance");
                if (renderDistance != null) mc.options.renderDistance().set(renderDistance);
                STEPS.addAll(build());
            } catch (RuntimeException e) {
                fail(mc, e);
                return;
            }
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
            } catch (RuntimeException e) {
                fail(mc, e);
                return;
            }
            if (!done) return;
            lastWaitTicks = elapsed();
            step++;
            stepStart = t;
            stepFrames = frames;
        }
    }

    private static void fail(Minecraft mc, RuntimeException e) {
        log("failed at step " + step + ": " + e);
        e.printStackTrace();
        mc.stop();
    }

    public static void frame(Minecraft mc) {
        frames++;
        if (frameTimes != null && timedFrames < frameTimes.length) {
            long now = System.nanoTime();
            if (lastFrameTime != 0L) frameTimes[timedFrames++] = (now - lastFrameTime) * 1e-6;
            lastFrameTime = now;
            if (timedPanYaw != 0f) {
                mc.player.setYRot(mc.player.getYRot() + timedPanYaw);
                mc.player.setOldPosAndRot();
            }
        }
        Modes.onFrame(mc);
    }

    static String fmt(String f, Object... a) {
        return String.format(Locale.ROOT, f, a);
    }
}
