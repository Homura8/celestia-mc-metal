package dev.celestia.metal.shade.atmosphere;

import com.mojang.logging.LogUtils;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeLook;
import dev.celestia.metal.shade.ShadeSettings;
import dev.celestia.metal.shade.ShadeShaderPatcher;
import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import net.minecraft.client.CloudStatus;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.world.entity.LightningBolt;
import net.minecraft.world.level.biome.Biome.Precipitation;
import org.slf4j.Logger;

/** Owns the low-resolution cloud and volumetric-light passes and tracks local surface weather. */
public final class ShadeAtmosphere {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final boolean VOLUMETRICS = !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.volumetrics"));
    private static final String[] ENTRIES = {
        "shade_cloud_trace", "shade_cloud_resolve", "shade_cloud_dome", "shade_vl_march", "shade_wx_noise_fs"
    };
    // (textures[CLOUD_SCREEN] is unused: the resolved clouds ping-pong between cloudHistory[0] and [1])
    private static final int CLOUD_TRACE = 0, CLOUD_SCREEN = 1, CLOUD_DOME = 2, VOLUME = 3, WEATHER_NOISE = 4;
    private static final int WEATHER_SLOT = 4, DOME_SLOT = 13, SCREEN_SLOT = 14;
    private static final int WEATHER_NOISE_SIZE = 1024;
    private static final int DOME_WIDTH = 160, DOME_HEIGHT = 64;

    private final long[] pipelines = new long[ENTRIES.length];
    private final long[] textures = new long[ENTRIES.length];
    private final long[] cloudHistory = new long[2];
    private int cloudCurrent;
    private boolean cloudHistoryValid;
    private ShadeCloudNoise cloudNoise;
    private final MemorySegment cloudPush = Arena.global().allocate(16, 16);
    private int width, height;
    private boolean failed, clouds, volume, noiseBaked, domeReady;
    private float previousCloudBase;
    private double cloudPhase;
    private ShadeSettings.Atmosphere previousOptions;
    private ClientLevel weatherLevel;
    private float wetness, puddles, snow;

    public void prepare(long ctx, ClientLevel level, CameraRenderState camera, ShadeFrame frame, ShadeLook look,
                        CloudStatus status, float cloudHeight, float dt, int w, int h, ShadeSettings.Atmosphere options) {
        clouds = volume = false;
        look.cloudsEnabled = false;
        look.waterShaftSurface = 0f;
        look.wetness = look.puddles = look.snow = look.flashStrength = 0f;
        if (level == null || frame.dimension != ShadeFrame.DIM_OVERWORLD) {
            weatherLevel = null;
            domeReady = false;
            cloudHistoryValid = false;
            return;
        }
        if (!initialize(ctx)) return;
        if (!options.equals(previousOptions)) domeReady = false;
        previousOptions = options;
        cloudPhase += dt * options.cloudSpeed();
        if (w != width || h != height) {
            destroyCloudTargets(ctx);
            destroyTexture(ctx, VOLUME);
            width = w;
            height = h;
        }
        if (weatherLevel != level) {
            wetness = puddles = snow = 0f;
            domeReady = false;
            weatherLevel = level;
        }

        float base = Float.isFinite(cloudHeight) ? cloudHeight : 192f;
        if (base != previousCloudBase) domeReady = false;
        previousCloudBase = base;
        if (options.clouds() && status != CloudStatus.OFF) {
            if (textures[CLOUD_TRACE] == 0L) {
                // half resolution resolved (ping-pong history), traced at a quarter of those pixels per frame (2x2 checkerboard)
                int hw = Math.max(1, (w + 1) / 2), hh = Math.max(1, (h + 1) / 2);
                textures[CLOUD_TRACE] = texture(ctx, CLOUD_TRACE, (hw + 1) / 2, (hh + 1) / 2);
                cloudHistory[0] = texture(ctx, CLOUD_SCREEN, hw, hh);
                cloudHistory[1] = texture(ctx, CLOUD_SCREEN, hw, hh);
                cloudHistoryValid = false;
            }
            clouds = textures[CLOUD_TRACE] != 0L && cloudHistory[0] != 0L && cloudHistory[1] != 0L;
        } else {
            domeReady = false;
            cloudHistoryValid = false;
        }
        boolean waterShafts = frame.fogType == ShadeFrame.FOG_WATER && frame.waterSurfaceAbove > 0f
            && frame.waterSurfaceAbove < 24f && frame.sky.sunLight && frame.eyeSkyLight >= 4
            && (ShadeFrame.devBits() & ShadeFrame.DEV_NO_UNDERWATER_SHAFTS) == 0;
        volume = VOLUMETRICS && options.volumetrics() && options.lightStrength() > 0f
            && (frame.fogType == ShadeFrame.FOG_AIR || waterShafts) && frame.eyeSkyLight >= 2 && frame.sky.lightDir[1] > 0.015f;
        if (volume && textures[VOLUME] == 0L) {
            textures[VOLUME] = texture(ctx, VOLUME, (w + 3) / 4, (h + 3) / 4);
        }
        volume &= textures[VOLUME] != 0L;
        if (volume && waterShafts) look.waterShaftSurface = frame.waterSurfaceAbove;

        look.cloudsEnabled = clouds;
        look.cloudSteps = status == CloudStatus.FANCY ? options.cloudSteps() : Math.max(4, Math.round(options.cloudSteps() * 4f / 7f));
        look.cloudBase = base;
        ShadeWeather.compute(level.getOverworldClockTime(), frame.rain, options.cloudCoverage(), Integer.getInteger("celestiametal.shade.weatherDay", -1),
            look.cloudWeather);
        look.cloudPhase = (float) cloudPhase;
        if (!options.weather()) {
            wetness = puddles = snow = 0f;
            return;
        }

        Precipitation precipitation = level.getPrecipitationAt(camera.blockPos);
        boolean rainsHere = precipitation == Precipitation.RAIN;
        wetness = approach(wetness, rainsHere ? frame.rain : 0f, 14f, 75f, dt);
        float puddleTarget = rainsHere ? Math.clamp((wetness - 0.35f) / 0.55f, 0f, 1f) : 0f;
        puddles = approach(puddles, puddleTarget, 10f, 110f, dt);
        snow = approach(snow, precipitation == Precipitation.SNOW ? frame.rain : 0f, 30f, 240f, dt);
        look.wetness = wetness;
        look.puddles = puddles;
        look.snow = snow;
        int flashTicks = level.getSkyFlashTime();
        if (flashTicks > 0) updateFlash(level, camera, look, Math.min(1f, 0.5f * flashTicks));
    }

    private static float approach(float current, float target, float rise, float dry, float dt) {
        float amount = (float) -Math.expm1(-dt / (target > current ? rise : dry));
        return Math.fma(target - current, amount, current);
    }

    private static void updateFlash(ClientLevel level, CameraRenderState camera, ShadeLook look, float intensity) {
        double nearest = 256.0 * 256.0;
        for (var entity : level.entitiesForRendering()) {
            if (!(entity instanceof LightningBolt)) continue;
            double dx = entity.getX() - camera.pos.x;
            double dy = entity.getY() + 16.0 - camera.pos.y;
            double dz = entity.getZ() - camera.pos.z;
            double distanceSq = dx * dx + dy * dy + dz * dz;
            if (distanceSq >= nearest) continue;
            nearest = distanceSq;
            double invDist = 1.0 / Math.sqrt(Math.max(distanceSq, 1.0));
            look.flashX = (float) (dx * invDist);
            look.flashY = (float) (dy * invDist);
            look.flashZ = (float) (dz * invDist);
            look.flashStrength = (float) (1.4 * intensity / (1.0 + distanceSq / 4096.0));
        }
    }

    public void renderClouds(long ctx, int frameIndex, MemorySegment texArgs) {
        if (textures[WEATHER_NOISE] != 0L && !noiseBaked) {
            draw(ctx, WEATHER_NOISE, 0L, texArgs);
            noiseBaked = true;
        }
        MetalNative.shadeSetResource(ctx, WEATHER_SLOT, textures[WEATHER_NOISE]);
        long screen = 0L;
        if (clouds) {
            long prev = cloudHistory[cloudCurrent], next = cloudHistory[cloudCurrent ^ 1];
            cloudPush.set(ValueLayout.JAVA_INT, 0, frameIndex);
            cloudPush.set(ValueLayout.JAVA_INT, 4, cloudHistoryValid ? 1 : 0);
            // trace: noise 2D, Worley, curl, (the history only for its size)
            texArgs.set(ValueLayout.JAVA_LONG, 0, cloudNoise.noise2d);
            texArgs.set(ValueLayout.JAVA_LONG, 8, cloudNoise.worley);
            texArgs.set(ValueLayout.JAVA_LONG, 16, cloudNoise.curl);
            texArgs.set(ValueLayout.JAVA_LONG, 24, prev);
            MetalNative.shadeFullscreenPass(ctx, pipelines[CLOUD_TRACE], textures[CLOUD_TRACE], texArgs, 4,
                MemorySegment.NULL, 0, cloudPush, 16);
            // resolve into the other history texture: this frame's cell plus the reprojected history
            texArgs.set(ValueLayout.JAVA_LONG, 0, textures[CLOUD_TRACE]);
            texArgs.set(ValueLayout.JAVA_LONG, 8, prev);
            MetalNative.shadeFullscreenPass(ctx, pipelines[CLOUD_SCREEN], next, texArgs, 2, MemorySegment.NULL, 0, cloudPush, 16);
            cloudCurrent ^= 1;
            cloudHistoryValid = true;
            screen = next;
            if (!domeReady || (frameIndex & 3) == 0) {
                texArgs.set(ValueLayout.JAVA_LONG, 0, cloudNoise.noise2d);
                texArgs.set(ValueLayout.JAVA_LONG, 8, cloudNoise.worley);
                texArgs.set(ValueLayout.JAVA_LONG, 16, cloudNoise.curl);
                MetalNative.shadeFullscreenPass(ctx, pipelines[CLOUD_DOME], textures[CLOUD_DOME], texArgs, 3,
                    MemorySegment.NULL, 0, MemorySegment.NULL, 0);
                domeReady = true;
            }
        } else {
            cloudHistoryValid = false;
        }
        MetalNative.shadeSetResource(ctx, SCREEN_SLOT, screen);
        MetalNative.shadeSetResource(ctx, DOME_SLOT, clouds ? textures[CLOUD_DOME] : 0L);
    }

    public long renderVolume(long ctx, long depth, MemorySegment texArgs) {
        if (!volume || depth == 0L) return 0L;
        // inputs: the depth copy, and Photon's 2D noise for the underwater light bands (vl.metal vlWaterShafts)
        texArgs.set(ValueLayout.JAVA_LONG, 0, depth);
        texArgs.set(ValueLayout.JAVA_LONG, 8, cloudNoise != null ? cloudNoise.noise2d : 0L);
        MetalNative.shadeFullscreenPass(ctx, pipelines[VOLUME], textures[VOLUME], texArgs, 2, MemorySegment.NULL, 0,
            MemorySegment.NULL, 0);
        return textures[VOLUME];
    }

    private void draw(long ctx, int pass, long input, MemorySegment texArgs) {
        texArgs.set(ValueLayout.JAVA_LONG, 0, input);
        MetalNative.shadeFullscreenPass(ctx, pipelines[pass], textures[pass], texArgs, input == 0L ? 0 : 1,
            MemorySegment.NULL, 0, MemorySegment.NULL, 0);
    }

    public boolean hasClouds() {
        return clouds;
    }

    public boolean hasVolume() {
        return volume;
    }

    private boolean initialize(long ctx) {
        if (failed) return false;
        if (pipelines[0] != 0L) return true;

        StringBuilder error = new StringBuilder();
        long lib = 0L, vertex = 0L;
        try {
            lib = MetalNative.compileMslLibrary(ctx, ShadeShaderPatcher.atmosphereSource(), "CelestiaAtmosphere", true, error);
            if (lib == 0L) throw new IllegalStateException(error.toString());
            vertex = MetalNative.compileFunction(lib, "shade_fs_vs", false, 0, 0, error);
            if (vertex == 0L) throw new IllegalStateException(error.toString());
            for (int i = 0; i < ENTRIES.length; i++) {
                long fragment = MetalNative.compileFunction(lib, ENTRIES[i], false, 0, 0, error);
                if (fragment == 0L) throw new IllegalStateException(error.toString());
                try {
                    pipelines[i] = CelestiaShade.createFullscreenPso(ctx, vertex, fragment, format(i), ENTRIES[i], error);
                } finally {
                    MetalNative.functionDestroy(fragment);
                }
            }
            try {
                cloudNoise = ShadeCloudNoise.create(ctx);
            } catch (IOException e) {
                throw new IllegalStateException("Failed to load the cloud noise textures", e);
            }
            textures[CLOUD_DOME] = texture(ctx, CLOUD_DOME, DOME_WIDTH, DOME_HEIGHT);
            textures[WEATHER_NOISE] = texture(ctx, WEATHER_NOISE, WEATHER_NOISE_SIZE, WEATHER_NOISE_SIZE);
            if (cloudNoise == null || textures[CLOUD_DOME] == 0L || textures[WEATHER_NOISE] == 0L) {
                throw new IllegalStateException("Failed to allocate atmosphere noise or dome textures");
            }
            LOGGER.info("CelestiaShade P3b clouds, volumetric lighting and weather initialized");
            return true;
        } catch (RuntimeException e) {
            close(ctx);
            failed = true;
            LOGGER.warn("CelestiaShade atmosphere initialization failed", e);
            return false;
        } finally {
            if (vertex != 0L) MetalNative.functionDestroy(vertex);
            if (lib != 0L) MetalNative.libraryDestroy(lib);
        }
    }

    private static int format(int pass) {
        return pass == WEATHER_NOISE ? MetalConst.FMT_RG16_FLOAT : MetalConst.FMT_RGBA16_FLOAT;
    }

    private static long texture(long ctx, int pass, int w, int h) {
        return MetalNative.textureCreate(ctx, format(pass), w, h, 1, 1,
            false, true, true, false, ENTRIES[pass]);
    }

    private void destroyCloudTargets(long ctx) {
        destroyTexture(ctx, CLOUD_TRACE);
        for (int i = 0; i < 2; i++) {
            if (cloudHistory[i] != 0L) MetalNative.textureDestroy(ctx, cloudHistory[i]);
            cloudHistory[i] = 0L;
        }
        cloudHistoryValid = false;
    }

    private void destroyTexture(long ctx, int index) {
        if (textures[index] != 0L) {
            MetalNative.textureDestroy(ctx, textures[index]);
            textures[index] = 0L;
        }
    }

    public void close(long ctx) {
        if (ctx == 0L) return;
        MetalNative.shadeSetResource(ctx, WEATHER_SLOT, 0L);
        MetalNative.shadeSetResource(ctx, DOME_SLOT, 0L);
        MetalNative.shadeSetResource(ctx, SCREEN_SLOT, 0L);
        destroyCloudTargets(ctx);
        if (cloudNoise != null) cloudNoise.close(ctx);
        cloudNoise = null;
        for (int i = 0; i < ENTRIES.length; i++) {
            destroyTexture(ctx, i);
            if (pipelines[i] != 0L) MetalNative.pipelineDestroy(ctx, pipelines[i]);
            pipelines[i] = 0L;
        }
        weatherLevel = null;
        clouds = volume = noiseBaked = domeReady = false;
    }
}
