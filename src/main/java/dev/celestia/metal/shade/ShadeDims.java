// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/dims/ShadeDims.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.state.level.SkyRenderState;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.Biomes;
import org.joml.Matrix3f;
import org.joml.Vector3f;

/**
 * CPU side of Nether and End dimension looks: biome-blended Nether ambient, lava up-light and layered fog;
 * End fixed violet key light with shadows, procedural sky palette, dragon-fight boss fog and End flash.
 */
public final class ShadeDims {
    static final float E_REF = 0.86f;
    static final float END_EXPOSURE = 0.52f;
    public static final int FLAG_DIMS_LIT = 1 << 23;
    public static final int FEATURE_DIMS = 1 << 20, FEATURE_MEDIA = 1 << 21, FEATURE_SHIMMER = 1 << 22;

    // Nether biome palettes: fog, ambient, accent (sRGB hex); fog density multiplier; lava up-light multiplier
    private static final int[][] NETHER_HEX = {
        {0x380810, 0x822428, 0xFF7A45}, // nether wastes
        {0x340814, 0x8A2238, 0xFF9E7A}, // crimson forest
        {0x08222A, 0x227478, 0x8A5CC8}, // warped forest
        {0x0B202C, 0x2C6C86, 0x6EE2FF}, // soul sand valley
        {0x201E28, 0x5E5A6C, 0xD4CCE0}, // basalt deltas
    };
    private static final float[] NETHER_DENSITY = {1.0f, 1.15f, 1.05f, 1.2f, 1.3f};
    private static final float[] NETHER_LAVA = {1.0f, 0.8f, 0.45f, 0.35f, 0.7f};

    static final float NETHER_AMBIENT = 0.048f, NETHER_FOG_GAIN = 1.15f, NETHER_LAVA_UP = 0.50f, NETHER_LAVA_Y = 31f, NETHER_SIGMA = 0.90f;
    static final float END_KEY = 0.56f, END_AMBIENT = 0.048f, END_FOG = 0.012f, END_FOG_SIGMA = 0.0009f;
    static final float END_ELEVATION = 55f, END_AZIMUTH = 30f;

    private static final float[] netherW = {1f, 0f, 0f, 0f, 0f};
    private static final Vector3f flashDir = new Vector3f(0, 1, 0);
    private static final float[] endLight = endDirection();

    private static float flash;
    private static int lastDim = -1;
    private static volatile float vanillaFogEnd = 96f;
    private static float fogEnd = 96f;
    private static float fogDensity;
    private static boolean bossFog;
    private static volatile boolean dimsLit;
    private static volatile boolean endShadows;
    private static volatile boolean enabledOption = true;
    private static int dimension;

    private ShadeDims() {}

    public static float[] endLight() {
        return endLight;
    }

    private static float[] endDirection() {
        double e = Math.toRadians(END_ELEVATION), a = Math.toRadians(END_AZIMUTH);
        return new float[] {(float) (Math.cos(e) * Math.sin(a)), (float) Math.sin(e), (float) (Math.cos(e) * Math.cos(a))};
    }

    public static void vanillaFog(float start, float end) {
        vanillaFogEnd = end;
    }

    public static boolean on() {
        return enabledOption
            && !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.dims", "true"))
            && !Boolean.getBoolean("celestiametal.shade.dims.pause");
    }

    private static boolean on(ShadeSettings.Dimensions options) {
        return (options == null || options.enabled())
            && !"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.dims", "true"))
            && !Boolean.getBoolean("celestiametal.shade.dims.pause");
    }

    public static boolean isLit() {
        return dimsLit;
    }

    public static boolean endShadowsActive() {
        return endShadows;
    }

    public static boolean ownsFog(int dimension) {
        return on() && (dimension == ShadeFrame.DIM_NETHER || dimension == ShadeFrame.DIM_END);
    }

    /**
     * Updates Nether/End lighting, palette, fog density and exposure. Called after {@link ShadeLook#update}
     * so art grading does not alter dimension palettes, and before {@code ShadowPass.prepare} so End shadows see
     * {@link #endShadowsActive()}.
     */
    public static void update(ShadeFrame f, ShadeLook look, ClientLevel level, SkyRenderState sky, BlockPos camera,
                              float dt, boolean snap, ShadeSettings.Dimensions options) {
        enabledOption = options == null || options.enabled();
        dimension = f.dimension;
        boolean changed = lastDim != f.dimension;
        lastDim = f.dimension;
        float k = snap || changed ? 1f : 1f - (float) Math.exp(-Math.max(dt, 0f) / 3f);
        dimsLit = on(options) && (f.dimension == ShadeFrame.DIM_NETHER || f.dimension == ShadeFrame.DIM_END);
        endShadows = dimsLit && f.dimension == ShadeFrame.DIM_END && (options == null || options.endShadows());
        if (!dimsLit) {
            f.blockLight[0] = 2.4f; f.blockLight[1] = 1.2f; f.blockLight[2] = 0.48f;
            return;
        }

        fogEnd += (Math.max(vanillaFogEnd, 8f) - fogEnd) * k;
        if (f.fogType == ShadeFrame.FOG_AIR) f.fogColor[3] = 0f;
        f.exposure = f.dimension == ShadeFrame.DIM_END ? E_REF * END_EXPOSURE : E_REF;
        for (int i = 0; i < 8; i++) Arrays.fill(f.sky.horizon[i], 0f);
        if (f.dimension == ShadeFrame.DIM_NETHER) {
            nether(f, level, camera, k);
        } else {
            end(f, look, sky, k);
        }
    }

    private static void nether(ShadeFrame f, ClientLevel level, BlockPos camera, float k) {
        int b = 0;
        if (level != null && camera != null) {
            Holder<Biome> h = level.getBiomeManager().getBiome(camera);
            b = h.is(Biomes.CRIMSON_FOREST) ? 1 : h.is(Biomes.WARPED_FOREST) ? 2 : h.is(Biomes.SOUL_SAND_VALLEY) ? 3 : h.is(Biomes.BASALT_DELTAS) ? 4 : 0;
        }
        for (int i = 0; i < 5; i++) netherW[i] += ((i == b ? 1f : 0f) - netherW[i]) * k;
        float[] fog = new float[3], amb = new float[3], acc = new float[3];
        float density = 0f, lava = 0f, fogLuma = 0f;
        for (int i = 0; i < 5; i++) {
            float w = netherW[i];
            if (w < 1e-4f) continue;
            addChroma(fog, NETHER_HEX[i][0], w);
            fogLuma += luma(srgbLin(NETHER_HEX[i][0])) * w;
            addChroma(amb, NETHER_HEX[i][1], w);
            addChroma(acc, NETHER_HEX[i][2], w);
            density += NETHER_DENSITY[i] * w;
            lava += NETHER_LAVA[i] * w;
        }
        float[] warm = {1.0f, 0.9f, 0.8f};
        for (int c = 0; c < 3; c++) amb[c] = 0.5f * amb[c] + 0.5f * warm[c];
        setLuma(amb, NETHER_AMBIENT / E_REF);
        float[] up = amb.clone(), down = amb.clone(), side = amb.clone();
        scale(up, 0.85f);
        copy3(up, f.sky.ambientSky);
        copy3(down, f.sky.ambientGround);
        copy3(side, f.sky.ambientToward);
        copy3(side, f.sky.ambientAway);
        Arrays.fill(f.sky.light, 0f);
        f.sky.sunLight = false;

        setLuma(fog, fogLuma * NETHER_FOG_GAIN / E_REF);
        copy3(fog, f.sky.horizon[0]);
        float[] lavaC = {1.0f, 0.42f, 0.12f};
        setLuma(lavaC, NETHER_LAVA_UP / E_REF * lava);
        copy3(lavaC, f.sky.horizon[1]);
        setLuma(acc, fogLuma * NETHER_FOG_GAIN / E_REF);
        copy3(acc, f.sky.horizon[2]);
        fogDensity = NETHER_SIGMA / Math.max(fogEnd, 16f) * density;
        f.blockLight[0] = 4.2f; f.blockLight[1] = 2.0f; f.blockLight[2] = 0.85f;
    }

    private static void end(ShadeFrame f, ShadeLook look, SkyRenderState sky, float k) {
        f.blockLight[0] = 2.4f; f.blockLight[1] = 1.2f; f.blockLight[2] = 0.48f;
        float[] key = srgbLin(0xE89EFF);
        for (int c = 0; c < 3; c++) key[c] = 0.78f * key[c] / Math.max(luma(key), 1e-6f) + 0.22f;
        setLuma(key, END_KEY / E_REF);
        copy3(key, f.sky.light);
        f.sky.sunLight = true;
        System.arraycopy(endLight, 0, f.sky.lightDir, 0, 3);

        float[] amb = srgbLin(0x76409E);
        setLuma(amb, END_AMBIENT / E_REF);
        copy3(amb, f.sky.ambientSky);
        float[] ground = amb.clone();
        scale(ground, 0.62f);
        copy3(ground, f.sky.ambientGround);
        float[] side = amb.clone();
        scale(side, 0.85f);
        copy3(side, f.sky.ambientToward);
        copy3(side, f.sky.ambientAway);

        float[] fog = srgbLin(0x0E071A);
        setLuma(fog, END_FOG / E_REF);
        copy3(fog, f.sky.horizon[0]);

        putSkyLinear(f.sky.horizon[2], 0x000000, 1f);
        putSkyLinear(f.sky.horizon[3], 0x030106, 1f);
        putSkyLinear(f.sky.horizon[4], 0xB88CFF, 0.90f);
        putSkyLinear(f.sky.horizon[5], 0xE8B4FF, 0.90f);
        putSkyLinear(f.sky.horizon[6], 0x7A42B8, 0.55f);
        putSkyLinear(f.sky.horizon[7], 0xB866C8, 0.48f);

        Minecraft mc = Minecraft.getInstance();
        bossFog = mc != null && mc.gui != null && mc.gui.hud != null && mc.gui.hud.getBossOverlay().shouldCreateWorldFog();
        fogDensity = END_FOG_SIGMA * (bossFog ? 1.25f : 1f);

        float target = sky != null ? sky.endFlashIntensity : 0f;
        flash += (target - flash) * Math.min(1f, k * 6f);
        if (target > 1e-4f && sky != null) {
            Matrix3f m = new Matrix3f()
                .rotateY((float) Math.toRadians(180f - sky.endFlashYAngle))
                .rotateX((float) Math.toRadians(-90f - sky.endFlashXAngle));
            m.transform(new Vector3f(0, 1, 0), flashDir).normalize();
        }
    }

    /** Packs dimension flags, feature bits, fog/lava tint and End flash into the frame's ShadeLook and ShadeFrame buffers. */
    public static void pack(ByteBuffer look, ByteBuffer frame, ShadeFrame f, ShadeSettings.Dimensions options) {
        pack(look, frame, f, options, 0f);
    }

    /** Packs dimension flags, feature bits, fog/lava tint, lift/EV overrides and End flash. */
    public static void pack(ByteBuffer look, ByteBuffer frame, ShadeFrame f, ShadeSettings.Dimensions options,
                            float userExposureEv) {
        pack(look, frame, f, options, userExposureEv, false);
    }

    /** Packs dimension flags, feature bits, fog/lava tint, lift/EV overrides, End flash, and aurora texture bit. */
    public static void pack(ByteBuffer look, ByteBuffer frame, ShadeFrame f, ShadeSettings.Dimensions options,
                            float userExposureEv, boolean auroraTexActive) {
        ByteBuffer L = look.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer F = frame.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        int features = L.getInt(ShadeLook.TIER + 4);
        boolean on = on(options);
        if (on) features |= FEATURE_DIMS;
        if (!"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.media", "true"))) features |= FEATURE_MEDIA;
        if (on && options != null && options.netherShimmer()) features |= FEATURE_SHIMMER;
        L.putInt(ShadeLook.TIER + 4, features);

        int dimBits = (!"false".equalsIgnoreCase(System.getProperty("celestiametal.shade.dims.motes", "true")) ? 1 : 0)
            | (auroraTexActive ? 2 : 0);
        if (dimsLit) {
            boolean nether = dimension == ShadeFrame.DIM_NETHER;
            int bits = (int) F.getFloat(ShadeFrame.SUN_PATH + 8) | FLAG_DIMS_LIT;
            F.putFloat(ShadeFrame.SUN_PATH + 8, bits);

            float border = f.fogRenderStart < f.fogRenderEnd && f.fogRenderEnd < 1e5f ? f.fogRenderEnd : 0f;
            put4(L, ShadeLook.DIM_TINT, fogDensity, NETHER_LAVA_Y, border, (nether ? 1 : bossFog ? 3 : 2) + 4 * dimBits);
            put4(L, ShadeLook.FLASH, flashDir.x, flashDir.y, flashDir.z, nether ? 0f : flash);
            L.putFloat(ShadeLook.EXPOSURE_REF, f.exposure);
            L.putFloat(ShadeLook.GRADE0, userExposureEv);
            L.putFloat(ShadeLook.GRADE1 + 12, 0f);
            if (nether) {
                put4(L, ShadeLook.GRADE2, 0f, 0f, 0f, 0.0002f);
                ShadeLook.writeTonemap(L, L.getFloat(ShadeLook.TONEMAP) * 1.28f);
                L.putFloat(ShadeLook.EXPOSURE_REF + 4, 0.18f);
                L.putFloat(ShadeLook.EXPOSURE_CFG + 4, 0.45f);
                L.putFloat(ShadeLook.BLOOM, L.getFloat(ShadeLook.BLOOM) * 0.45f);
                L.putFloat(ShadeLook.BLOOM + 8, L.getFloat(ShadeLook.BLOOM + 8) * 0.35f);
            } else {
                put4(L, ShadeLook.GRADE2, 0f, 0f, 0f, 0f);
                L.putFloat(ShadeLook.EXPOSURE_REF + 4, 0.10f);
                L.putFloat(ShadeLook.EXPOSURE_CFG + 4, 0.35f);
                L.putFloat(ShadeLook.BLOOM, L.getFloat(ShadeLook.BLOOM) * 0.65f);
            }
        } else {
            put4(L, ShadeLook.DIM_TINT, 0f, 0f, 0f, 4 * dimBits);
        }
    }

    private static float[] srgbLin(int hex) {
        float[] c = {((hex >> 16) & 255) / 255f, ((hex >> 8) & 255) / 255f, (hex & 255) / 255f};
        for (int i = 0; i < 3; i++) c[i] = c[i] <= 0.04045f ? c[i] / 12.92f : (float) Math.pow((c[i] + 0.055f) / 1.055f, 2.4f);
        return c;
    }

    private static void addChroma(float[] acc, int hex, float w) {
        float[] c = srgbLin(hex);
        float l = Math.max(luma(c), 1e-6f);
        for (int i = 0; i < 3; i++) acc[i] += c[i] / l * w;
    }

    private static void putSkyLinear(float[] out, int hex, float gain) {
        float[] h = srgbLin(hex);
        for (int i = 0; i < 3; i++) out[i] = h[i] * gain / E_REF;
    }

    private static float luma(float[] c) {
        return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2];
    }

    private static void setLuma(float[] c, float y) {
        float l = luma(c);
        if (l <= 0f) return;
        for (int i = 0; i < 3; i++) c[i] *= y / l;
    }

    private static void scale(float[] c, float s) {
        for (int i = 0; i < 3; i++) c[i] *= s;
    }

    private static void copy3(float[] src, float[] dst) {
        System.arraycopy(src, 0, dst, 0, 3);
    }

    private static void put4(ByteBuffer b, int at, float x, float y, float z, float w) {
        b.putFloat(at, x).putFloat(at + 4, y).putFloat(at + 8, z).putFloat(at + 12, w);
    }
}
