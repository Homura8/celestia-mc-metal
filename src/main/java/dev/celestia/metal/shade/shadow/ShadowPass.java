// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/shadow/ShadowPass.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.shadow;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.textures.GpuTextureView;
import dev.celestia.metal.backend.CelestiaTextureView;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeSettings;
import dev.celestia.metal.shade.ShadeSky;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.world.level.dimension.DimensionType;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.slf4j.Logger;

/**
 * Manages the 2-cascade sun/moon shadow depth array ({@code texture(16)}), cascade scheduling,
 * adaptive sun quantization, and dispatch to {@link SodiumShadowCasters} or {@link VanillaShadowCasters}.
 */
public final class ShadowPass {
    private static final Logger LOGGER = LogUtils.getLogger();

    private static final double MIN_ELEVATION = Math.sin(Math.toRadians(2.0));
    private static final double NEAR_BACK = 96.0;
    private static final double FAR_BACK = 64.0;
    private static final double DEPTH_FRONT = 32.0;
    private static final double CASTER_REACH = 192.0;
    private static final float SLOPE_BIAS_DEFAULT = 1.0f;
    private static final float BIAS_TEXELS_DEFAULT = 1.0f;
    private static final float BIAS_CLAMP = 0.01f;

    private final ShadowCascade[] cascades = {new ShadowCascade(), new ShadowCascade()};
    private final float[] matrices = new float[32];
    private final Matrix4f mat0 = new Matrix4f();
    private final Matrix4f mat1 = new Matrix4f();
    private final double[] light = new double[3];
    private final double[] dirScratch = new double[3];
    private final Vector3f viewFwdScratch = new Vector3f();
    private final boolean[] draw = new boolean[2];

    private long shadowTex;
    private long atlasSampler;
    private ShadowCasterSource casterSource;
    private boolean initialized;
    private boolean disabled;
    private boolean active;

    private int resolution, failedResolution;
    private double farDistance;
    private int depthBits;
    private double camX, camY, camZ;
    private long lightKey;
    private long farLightKey;
    private int framesSinceFar;
    private int lastNearQuads;
    private int lastFarQuads;

    public static boolean isShadowsEnabled() {
        return !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.shadows", "true"));
    }

    public boolean isActive() {
        return active && shadowTex != 0L && initialized && !disabled;
    }

    public long texture() {
        return shadowTex;
    }

    public int resolution() {
        return resolution;
    }

    public String sourceName() {
        return casterSource != null ? casterSource.name() : "None";
    }

    public int lastNearQuads() {
        return lastNearQuads;
    }

    public int lastFarQuads() {
        return lastFarQuads;
    }

    private synchronized boolean ensureInitialized(long ctx, int requestedResolution) {
        if (initialized) return !disabled;
        if (disabled || ctx == 0L) return false;
        try {
            resolution = requestedResolution;
            depthBits = Integer.getInteger("celestiametal.shade.shadowDepth", 16) == 32 ? 32 : 16;
            int depthFmt = depthBits == 32 ? MetalConst.FMT_D32_FLOAT : MetalConst.FMT_D16_UNORM;

            shadowTex = MetalNative.textureCreate(ctx, depthFmt, resolution, resolution, 2, 1,
                false, true, true, false, "CelestiaShadow.Map");
            atlasSampler = MetalNative.samplerCreate(ctx, 1, 1, 0, 0, 0, 1, false, 0);
            if (shadowTex == 0L || atlasSampler == 0L) {
                throw new IllegalStateException("Failed creating shadow map texture or atlas sampler");
            }

            boolean hasSodium = FabricLoader.getInstance().isModLoaded("sodium");
            if (hasSodium) {
                try {
                    casterSource = new SodiumShadowCasters(ctx, depthFmt);
                } catch (Throwable t) {
                    LOGGER.warn("Sodium shadow casters unavailable ({}); using vanilla casters", t.getMessage());
                    casterSource = new VanillaShadowCasters(ctx, depthFmt);
                }
            } else {
                casterSource = new VanillaShadowCasters(ctx, depthFmt);
            }

            initialized = true;
            LOGGER.info("CelestiaShade P2 shadows initialized ({}x{}x2 Depth{}, backend={})",
                resolution, resolution, depthBits, casterSource.name());
            return true;
        } catch (Throwable t) {
            disabled = true;
            LOGGER.error("Failed initializing CelestiaShade shadow pass; continuing without shadows", t);
            close(ctx);
            return false;
        }
    }

    /**
     * Fits cascade 0 (and cascade 1 when due) before {@link ShadeFrame} is packed and published.
     */
    public void prepare(long ctx, CameraRenderState camera, SkyRenderState sky, ShadeFrame frame, ShadeSettings.Shadows options) {
        active = false;
        draw[0] = false;
        draw[1] = false;
        if (!options.enabled() || !isShadowsEnabled() || sky == null || sky.skybox != DimensionType.Skybox.OVERWORLD || camera == null) {
            cascades[1].valid = false;
            frame.shadowsEnabled = false;
            frame.cascades = 0;
            return;
        }
        int requestedResolution = clampInt(Integer.getInteger("celestiametal.shade.shadowRes", options.resolution()), 512, 4096);
        if (!ensureInitialized(ctx, requestedResolution)) {
            frame.shadowsEnabled = false;
            frame.cascades = 0;
            return;
        }

        if (requestedResolution != resolution && requestedResolution != failedResolution) {
            int depthFmt = depthBits == 32 ? MetalConst.FMT_D32_FLOAT : MetalConst.FMT_D16_UNORM;
            long replacement = MetalNative.textureCreate(ctx, depthFmt, requestedResolution, requestedResolution, 2, 1,
                false, true, true, false, "CelestiaShadow.Map");
            if (replacement != 0L) {
                MetalNative.textureDestroy(ctx, shadowTex);
                shadowTex = replacement;
                resolution = requestedResolution;
                failedResolution = 0;
                cascades[1].valid = false;
            } else {
                LOGGER.warn("Could not resize shadow maps to {}; keeping {}", requestedResolution, resolution);
                failedResolution = requestedResolution;
            }
        }

        chooseLight(sky.sunAngle, sky.moonAngle);
        double x = camera.pos.x, y = camera.pos.y, z = camera.pos.z;
        this.camX = x;
        this.camY = y;
        this.camZ = z;

        double dist = clampDouble(floatProp("celestiametal.shade.shadowDist", options.distance()), 16.0, 512.0);
        double near = clampDouble(floatProp("celestiametal.shade.shadowNear", (float) (dist / 4.0)), 4.0, dist);
        int farEvery = clampInt(Integer.getInteger("celestiametal.shade.shadowFarEvery", options.farInterval()), 1, 64);

        Vector3f fwd = camera.orientation.transform(viewFwdScratch.set(0f, 0f, -1f));
        double shift = 0.4 * near;
        cascades[0].fit(light, x + fwd.x * shift, y + fwd.y * shift, z + fwd.z * shift,
            near, resolution, NEAR_BACK, DEPTH_FRONT, CASTER_REACH);
        draw[0] = true;

        ShadowCascade far = cascades[1];
        double dx = x - far.cx, dy = y - far.cy, dz = z - far.cz;
        boolean moved = dx * dx + dy * dy + dz * dz > (dist / 8.0) * (dist / 8.0);
        boolean farDue = !far.valid || dist != farDistance || moved || farLightKey != lightKey || framesSinceFar >= farEvery - 1;
        if (farDue) {
            far.fit(light, x, y, z, dist, resolution, FAR_BACK, DEPTH_FRONT, CASTER_REACH);
            draw[1] = true;
            farLightKey = lightKey;
            farDistance = dist;
            framesSinceFar = 0;
        } else {
            framesSinceFar++;
        }

        cascades[0].matrix(x, y, z, matrices, 0);
        far.matrix(x, y, z, matrices, 16);
        mat0.set(matrices, 0);
        mat1.set(matrices, 16);

        float split0 = (float) ((0.85 - 0.4) * near);
        float split1 = (float) ((0.85 - 0.125) * dist);
        frame.cascadeTexel0 = (float) (2.0 * near / resolution);
        frame.cascadeTexel1 = (float) (2.0 * dist / resolution);
        frame.setShadow(true, 2, mat0, mat1, split0, split1, resolution, 0f, options.softness());
        active = true;
    }

    /** Encodes shadow depth render passes right before the level's {@code FrameGraphBuilder.execute}. */
    public void render(long ctx) {
        if (!active || disabled || !initialized || shadowTex == 0L || casterSource == null) return;
        long atlasTex = blockAtlasHandle();
        float slopeScale = floatProp("celestiametal.shade.shadowBias", SLOPE_BIAS_DEFAULT);
        float biasTexels = floatProp("celestiametal.shade.shadowBiasTexels", BIAS_TEXELS_DEFAULT);

        for (int c = 0; c < 2; c++) {
            if (!draw[c]) continue;
            ShadowCascade cas = cascades[c];
            float depthBias = (float) (biasTexels * cas.texelWorld() / Math.max(1.0, cas.depthRange()));
            float[] vp = new float[16];
            System.arraycopy(matrices, c * 16, vp, 0, 16);
            int q = casterSource.renderCascade(ctx, shadowTex, c, resolution, cas, vp, depthBias,
                camX, camY, camZ, light, c == 1, atlasTex, atlasSampler, slopeScale, BIAS_CLAMP, false);
            if (q < 0) {
                if (casterSource instanceof SodiumShadowCasters) {
                    LOGGER.warn("Switching shadow backend from Sodium to Vanilla casters");
                    casterSource.close(ctx);
                    int depthFmt = depthBits == 32 ? MetalConst.FMT_D32_FLOAT : MetalConst.FMT_D16_UNORM;
                    casterSource = new VanillaShadowCasters(ctx, depthFmt);
                    q = casterSource.renderCascade(ctx, shadowTex, c, resolution, cas, vp, depthBias,
                        camX, camY, camZ, light, c == 1, atlasTex, atlasSampler, slopeScale, BIAS_CLAMP, false);
                }
                if (q < 0) {
                    disabled = true;
                    active = false;
                    return;
                }
            }
            if (c == 0) lastNearQuads = q;
            else lastFarQuads = q;
        }
    }

    private void chooseLight(double sunAngle, double moonAngle) {
        boolean useMoon = Math.cos(sunAngle) * Math.cos(Math.toRadians(ShadeSky.SUN_TILT)) < -0.06;
        double raw = useMoon ? moonAngle : sunAngle;
        double step = adaptiveSunStep(raw);
        double quantized = step <= 0.0 ? raw : Math.round(raw / step) * step;
        ShadeSky.celestial(quantized, dirScratch);
        double lx = dirScratch[0], ly = dirScratch[1], lz = dirScratch[2];
        if (ly < MIN_ELEVATION) {
            double h = Math.sqrt(1.0 - MIN_ELEVATION * MIN_ELEVATION);
            double n = Math.sqrt(lx * lx + lz * lz);
            if (n < 1e-9) {
                lx = h;
                lz = 0.0;
            } else {
                lx = lx / n * h;
                lz = lz / n * h;
            }
            ly = MIN_ELEVATION;
        }
        light[0] = lx;
        light[1] = ly;
        light[2] = lz;
        lightKey = Double.doubleToLongBits(quantized) ^ (useMoon ? 1L : 0L);
    }

    private double adaptiveSunStep(double angle) {
        double base = Math.toRadians(clampDouble(floatProp("celestiametal.shade.shadowSunStep", 0.1f), 0f, 5f));
        if (base <= 0.0) return 0.0;
        ShadeSky.celestial(angle, dirScratch);
        double s = Math.max(Math.abs(dirScratch[1]), MIN_ELEVATION);
        double allowed = 0.01 * s * s;
        int n = 0;
        while (n < 8 && base / (1 << n) > allowed) n++;
        return base / (1 << n);
    }

    private static long blockAtlasHandle() {
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.getTextureManager() == null) return 0L;
        GpuTextureView view = mc.getTextureManager().getTexture(TextureAtlas.LOCATION_BLOCKS).getTextureView();
        return (view instanceof CelestiaTextureView ctv) ? ctv.handle() : 0L;
    }

    private static float floatProp(String key, float fallback) {
        String v = System.getProperty(key);
        if (v == null) return fallback;
        try {
            return Float.parseFloat(v.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static int clampInt(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    private static double clampDouble(double v, double lo, double hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    public synchronized void close(long ctx) {
        active = false;
        if (casterSource != null) {
            casterSource.close(ctx);
            casterSource = null;
        }
        if (ctx != 0L) {
            if (shadowTex != 0L) MetalNative.textureDestroy(ctx, shadowTex);
            if (atlasSampler != 0L) MetalNative.samplerDestroy(ctx, atlasSampler);
        }
        shadowTex = 0L;
        atlasSampler = 0L;
        initialized = false;
    }
}
