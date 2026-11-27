package celestiaqa;

import static celestiaqa.Qa.*;

import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.function.DoubleConsumer;
import net.minecraft.client.Minecraft;

final class Modes {
    static final int PERF_TICKS = 100;
    private static final String[] PERF_OPTIONS = {
        "SHADOWS_ENABLED=false", "SSAO_ENABLED=false", "WATER_REFLECTIONS=SKY_ONLY", "WATER_ENABLED=false",
        "CLOUDS_ENABLED=false", "GOD_RAYS=false", "BLOOM_ENABLED=false", "WEATHER_ENABLED=false",
        "DYNAMIC_LIGHTS=false", "COLORED_LIGHTS=false", "SMOOTH_BLOCK_LIGHT=false", "STARFIELD_ENABLED=false"
    };
    private static final String[] DEV_PROPERTIES = {
        "celestiametal.shade.water.devSsr", "celestiametal.shade.water.ssrBudget",
        "celestiametal.shade.dev", "celestiametal.shade.cloudDev"
    };
    private static int frameCount, frameLimit;
    private static final double START_Y = 147.2;
    private static final double FRAME_X = 0.5, FRAME_Z = -14.5;

    private Modes() {}

    private static List<Shots.Scene> timingScenes() {
        return System.getProperty("celestiaqa.scenes", "").isBlank()
            ? List.of(Shots.byName("pond-morning"), Shots.byName("underwater"), Shots.byName("vista-sunset"))
            : Shots.selected();
    }

    static void perf(List<Step> steps) {
        for (Shots.Scene scene : timingScenes()) {
            double[] a = new double[1];
            steps.add(once(mc -> CelestiaHooks.presetWith("Ultra", null)));
            steps.add(Shots.enter(scene));
            steps.add(Shots.settle(scene));
            steps.add(once(mc -> screenshot(mc, "perf-" + scene.name())));
            sample(steps, value -> a[0] = value);
            // The trailing Ultra window is also the leading Ultra window of the next comparison.
            for (String option : PERF_OPTIONS) {
                String name = "-" + option.substring(0, option.indexOf('=')).toLowerCase(Locale.ROOT);
                compare(steps, scene, name, a, () -> CelestiaHooks.presetWith("Ultra", option));
            }
            for (String preset : List.of("Quality", "Balanced", "Performance")) {
                compare(steps, scene, "preset " + preset, a, () -> CelestiaHooks.presetWith(preset, null));
            }
            compare(steps, scene, "pack off", a, () -> CelestiaHooks.selectPack("off"));
        }
        steps.add(once(mc -> configure()));
    }

    private static void compare(List<Step> steps, Shots.Scene scene, String name, double[] a, Runnable change) {
        double[] b = new double[1];
        steps.add(once(mc -> change.run()));
        sample(steps, value -> b[0] = value);
        steps.add(once(mc -> CelestiaHooks.presetWith("Ultra", null)));
        sample(steps, value -> {
            double base = (a[0] + value) / 2.0;
            System.out.println(fmt("[PERF] %-13s %-24s ultra %6.2f ms  this %6.2f ms  delta %+6.2f ms",
                scene.name(), name, base, b[0], b[0] - base));
            a[0] = value;
        });
    }

    private static void sample(List<Step> steps, DoubleConsumer result) {
        steps.add(ticks(70));
        steps.add(once(mc -> startSampling()));
        steps.add(ticks(PERF_TICKS));
        steps.add(once(mc -> {
            double[] times = finishSampling();
            if (times.length != PERF_TICKS) throw new IllegalStateException("Missing GPU timing samples");
            Arrays.sort(times);
            result.accept((times[PERF_TICKS / 2 - 1] + times[PERF_TICKS / 2]) / 2);
        }));
    }

    static void profile(List<Step> steps) {
        int every = Integer.getInteger("celestiaqa.profileEvery", 120);
        if (every < 10 || every > 999_999 || !"1".equals(System.getenv("CELESTIA_GPU_PROFILE"))) {
            throw new IllegalArgumentException("Launch profile with -PqaProfile[=<submits per report>]");
        }
        steps.add(once(mc -> {
            if (!CelestiaHooks.isMetal4()) throw new IllegalStateException("The GPU profiler requires Metal 4");
        }));
        String[] devs = System.getProperty("celestiaqa.devs", "0").split(",", -1);
        for (String token : devs) {
            if (!token.matches("[bsc]?[0-9]+")) throw new IllegalArgumentException("Invalid profile token " + token);
            Integer.parseInt(token.replaceFirst("^[bsc]", ""));
        }
        String[] original = Arrays.stream(DEV_PROPERTIES).map(System::getProperty).toArray(String[]::new);
        for (Shots.Scene scene : timingScenes()) {
            steps.add(Shots.enter(scene));
            steps.add(Shots.settle(scene));
            for (String token : devs) {
                steps.add(once(mc -> {
                    log("profile " + scene.name() + " " + token);
                    // Each token measures one knob against the original settings.
                    restoreDevProperties(original);
                    switch (token.charAt(0)) {
                        case 'b' -> System.setProperty(DEV_PROPERTIES[1], token.substring(1));
                        case 's' -> System.setProperty(DEV_PROPERTIES[2], token.substring(1));
                        case 'c' -> System.setProperty(DEV_PROPERTIES[3], token.substring(1));
                        default -> System.setProperty(DEV_PROPERTIES[0], token);
                    }
                }));
                steps.add(Qa.frames(2 * every + 5));
            }
            steps.add(once(mc -> {
                log("profile-end");
                restoreDevProperties(original);
            }));
        }
    }

    private static void restoreDevProperties(String[] original) {
        for (int i = 0; i < DEV_PROPERTIES.length; i++) {
            if (original[i] == null) System.clearProperty(DEV_PROPERTIES[i]);
            else System.setProperty(DEV_PROPERTIES[i], original[i]);
        }
    }

    static void lights(List<Step> steps) {
        Lights.add(steps);
    }

    static void frames(List<Step> steps) {
        int count = Integer.getInteger("celestiaqa.frames", 180);
        if (count < 1) throw new IllegalArgumentException("celestiaqa.frames must be positive");
        var scene = new Shots.Scene("descent", 1500, "clear", fmt("tp @a %.1f %.1f %.1f 0 -4", FRAME_X, START_Y, FRAME_Z));
        steps.add(Shots.enter(scene));
        steps.add(Shots.settle(scene));
        steps.add(once(mc -> {
            frameCount = 0;
            frameLimit = count;
            log("capturing " + count + " descent frames");
        }));
        steps.add(mc -> frameCount == frameLimit);
        steps.add(once(mc -> log("captured " + frameCount + " descent frames")));
    }

    static void onFrame(Minecraft mc) {
        if (frameCount >= frameLimit) return;
        if (frameCount == 0 || frameCount == frameLimit - 1) {
            var camera = mc.gameRenderer.mainCamera();
            log("frame " + frameCount + " eye " + camera.position() + " fluid " + camera.getFluidInCamera());
        }
        captureFrame(mc, fmt("%s-frame-%03d", prefix(), frameCount));
        frameCount++;
        if (frameCount < frameLimit) {
            // Move the local spectator between renders to avoid quantizing the descent to server ticks.
            double y = Math.max(141.1, START_Y - 0.012 * frameCount);
            mc.player.setPos(FRAME_X, y, FRAME_Z);
            mc.player.setOldPosAndRot();
        }
    }
}
