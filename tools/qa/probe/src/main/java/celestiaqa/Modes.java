package celestiaqa;

import static celestiaqa.Qa.*;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.function.DoubleConsumer;
import javax.imageio.ImageIO;
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
    private static float panYaw;
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

    /**
     * Multi-pack: switches the world renderer live between Celestia Native and the example world pack
     * (examples/shaderpacks/celestia-example-world, copied into the run's shaderpacks/ by run.sh), changes one of the pack's
     * recompile options, and switches back. Each step must leave CelestiaShade ready (a failed rebuild throws).
     */
    static void packs(List<Step> steps) {
        var scene = Shots.byName("vista-up");
        // Clouds off (cloudDev 7: no altocumulus, cirrus or cumulus): they drift with real time, so a deck overhead would make
        // the sky shots differ for reasons that have nothing to do with the pack.
        String cloudDev = System.getProperty(DEV_PROPERTIES[3]);
        steps.add(once(mc -> {
            System.setProperty(DEV_PROPERTIES[3], "7");
            CelestiaHooks.presetWith("Ultra", null);
        }));
        steps.add(Shots.enter(scene));
        steps.add(Shots.settle(scene));
        packStep(steps, "native", () -> {});
        packStep(steps, "example-rose", () -> {
            CelestiaHooks.refreshPacks();
            CelestiaHooks.selectPack(CelestiaHooks.EXAMPLE_PACK);
        });
        packStep(steps, "example-mint", () -> CelestiaHooks.options("SKY_TINT=MINT,SKY_TINT_STRENGTH=1"));
        packStep(steps, "native-again", () -> CelestiaHooks.selectPack(CelestiaHooks.NATIVE));
        // (warm: the example's libraries are in Metal's cache now) a switch must look the same however long its compile took
        packStep(steps, "example-warm", () -> CelestiaHooks.selectPack(CelestiaHooks.EXAMPLE_PACK));
        packStep(steps, "native-warm", () -> CelestiaHooks.selectPack(CelestiaHooks.NATIVE));
        steps.add(once(mc -> {
            if (cloudDev == null) System.clearProperty(DEV_PROPERTIES[3]);
            else System.setProperty(DEV_PROPERTIES[3], cloudDev);
            configure();
        }));
    }

    private static void packStep(List<Step> steps, String name, Runnable change) {
        long[] t0 = new long[1];
        steps.add(once(mc -> {
            t0[0] = System.nanoTime();
            change.run();
        }));
        steps.add(Qa.frames(3));
        steps.add(once(mc -> System.out.println(fmt("[PACKS] %-13s %-16s rebuilt and drew 3 frames in %7.1f ms",
            name, CelestiaHooks.worldPack(), (System.nanoTime() - t0[0]) / 1e6))));
        steps.add(ticks(60));
        steps.add(once(mc -> {
            CelestiaHooks.requireWorldReady(name);
            screenshot(mc, "packs-" + name);
        }));
    }

    static void lights(List<Step> steps) {
        Lights.add(steps);
    }

    static void scales(List<Step> steps) {
        var scene = Shots.byName("vista-sunset");
        steps.add(Shots.enter(scene));
        steps.add(Shots.settle(scene));
        int[] nativeContrast = {0};
        scaleStep(steps, "native", 100, "TAAU", "native", nativeContrast);
        scaleStep(steps, "taau", 65, "TAAU", "TAAU ", nativeContrast);
        scaleStep(steps, "spatial", 75, "METALFX_SPATIAL", "MetalFX Spatial ", nativeContrast);
        scaleStep(steps, "native-again", 100, "TAAU", "native", nativeContrast);
        steps.add(once(mc -> CelestiaHooks.setRenderScale(Integer.getInteger("celestiaqa.renderScale", 100))));
    }

    private static void scaleStep(List<Step> steps, String name, int scale, String upscaler, String expected, int[] nativeContrast) {
        String capture = "scales-" + name;
        steps.add(once(mc -> CelestiaHooks.setRenderScale(scale, upscaler)));
        steps.add(Qa.frames(120));
        steps.add(once(mc -> {
            CelestiaHooks.requireWorldReady(capture);
            String actual = CelestiaHooks.renderScaleLabel();
            if (!actual.startsWith(expected)) throw new IllegalStateException(capture + " used " + actual);
            screenshot(mc, capture);
        }));
        steps.add(Qa::screenshotsReady);
        steps.add(once(mc -> {
            // The upper sunset sky has an obvious gradient when the sky pass targets this frame's world.
            // A missed pass leaves the nearly uniform fog clear color. The region avoids the HUD and terrain.
            try {
                var png = mc.gameDirectory.toPath().resolve("screenshots").resolve(capture + ".png");
                var image = ImageIO.read(png.toFile());
                int width = image.getWidth(), height = image.getHeight();
                int darkest = 765, brightest = 0;
                for (int row = 10; row <= 40; row += 2) {
                    for (int column = 8; column <= 88; column += 2) {
                        int rgb = image.getRGB(width * column / 100, height * row / 100);
                        int brightness = ((rgb >> 16) & 255) + ((rgb >> 8) & 255) + (rgb & 255);
                        darkest = Math.min(darkest, brightness);
                        brightest = Math.max(brightest, brightness);
                    }
                }
                int contrast = brightest - darkest;
                int minimum = Math.max(36, nativeContrast[0] * 2 / 3);
                if (contrast < minimum) {
                    throw new IllegalStateException(capture + " has no sunset sky gradient (" + contrast + " vs " + minimum + ")");
                }
                if (nativeContrast[0] == 0) nativeContrast[0] = contrast;
                log(capture + " sky gradient " + contrast + " | " + CelestiaHooks.renderScaleLabel());
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }));
    }

    static void frames(List<Step> steps) {
        int count = Integer.getInteger("celestiaqa.frames", 180);
        if (count < 1) throw new IllegalArgumentException("celestiaqa.frames must be positive");
        panYaw = Float.parseFloat(System.getProperty("celestiaqa.panYaw", "0"));
        var scene = panYaw != 0f
            ? Shots.byName(System.getProperty("celestiaqa.panScene", "pond-noon"))
            : new Shots.Scene("descent", 1500, "clear", fmt("tp @a %.1f %.1f %.1f 0 -4", FRAME_X, START_Y, FRAME_Z));
        steps.add(Shots.enter(scene));
        steps.add(Shots.settle(scene));
        steps.add(once(mc -> {
            frameCount = 0;
            frameLimit = count;
            log(panYaw != 0f ? "capturing " + count + " pan frames (" + panYaw + " deg/frame)"
                : "capturing " + count + " descent frames");
        }));
        steps.add(mc -> frameCount == frameLimit);
        steps.add(once(mc -> log("captured " + frameCount + (panYaw != 0f ? " pan frames" : " descent frames"))));
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
            if (panYaw != 0f) {
                mc.player.setYRot(mc.player.getYRot() + panYaw);
                mc.player.setOldPosAndRot();
            } else {
                // Move the local spectator between renders to avoid quantizing the descent to server ticks.
                double y = Math.max(141.1, START_Y - 0.012 * frameCount);
                mc.player.setPos(FRAME_X, y, FRAME_Z);
                mc.player.setOldPosAndRot();
            }
        }
    }
}
