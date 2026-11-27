// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/ShadeLook.java & Look2.java
// (Portions adapted from Photon Shaders by Benjamin Stott / sixthsurge, MIT License, LICENSES/MIT-Photon.txt)
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
import org.joml.Matrix4f;

/**
 * Art layer & post-processing uniforms packed in the exact 1136-byte layout of
 * {@code struct ShadeLook} in {@code shaders/ported/shade_look.metal} at {@code buffer(25)}.
 */
public final class ShadeLook {
    public static final int SIZE = 1136;
    public static final int VIEW_PROJ = 0, PREV_VIEW_PROJ = 64, CELESTIAL = 128, CLOUD_SHADOW_VP = 192,
        SUN_GEOM = 256, SUN_ART = 272, AMBIENT_ART = 288, BOUNCE = 304,
        GRADE0 = 320, GRADE1 = 336, GRADE2 = 352, GRADE3 = 368, TONEMAP = 384, OUTPUT = 400, BLOOM = 416,
        FOG_R = 432, FOG_M = 448, FOG_MISC = 464, VL = 480, WET = 496, WIND = 512, CLOUDS0 = 528, CLOUDS1 = 544,
        WATER_SHADOW = 560, WATER = 576, DIM_TINT = 592, TINT_RECT = 608, EYE = 624, SKY_GOLD_H = 640, SKY_GOLD_Z = 656,
        NIGHT = 672, SSR = 688, CLOCK2 = 704, RENDER_SCALE = 720, EXPOSURE_CFG = 736, WEATHER_B = 752, FLASH = 768, DT = 784,
        TIER = 800, GRADE_IN = 816, GRADE_OUT = 864, GRADE_IN_INV = 912, GRADE_OUT_INV = 960, EXPOSURE_REF = 1008,
        USER0 = 1024, USER1 = 1040, USER2 = 1056, USER3 = 1072, USER4 = 1088, LOOK2A = 1104, LOOK2B = 1120;

    public static final int FEATURE_HDR = 1, FEATURE_BLOOM = 2, FEATURE_AUTO_EXPOSURE = 4,
        FEATURE_PCSS = 8, FEATURE_STARS = 16, FEATURE_HAZE = 32, FEATURE_LIGHT_V2 = 64;

    public boolean cloudsEnabled;
    public int cloudSteps;
    public float cloudPhase;
    public float auroraStrength;
    public boolean auroraTexActive;
    private ShadeSettings options;
    public float cloudBase, wetness, puddles, snow;
    public float waterShaftSurface;
    /** ShadeWeather.compute's eight daily cloud weather values (ShadeAtmosphere fills them each frame). */
    public final float[] cloudWeather = {0.40f, 0.55f, 0.30f, 0.50f, 0.40f, 0.50f, 0f, 0f};
    public float flashX, flashY, flashZ, flashStrength;

    // elevation, chroma gamma, light mul, ambient rgb (3), saturation, contrast a, bloom mix, VL k, mist sigma, white balance (mired)
    private static final float[][] KEYS = {
        {-15, 1.00f, 1.00f, 0.80f, 0.88f, 1.16f, 0.74f, 1.30f, 0.130f, 0.30f, 1.5f, -20},
        {-9,  1.00f, 1.00f, 0.84f, 0.86f, 1.20f, 0.82f, 1.32f, 0.120f, 0.15f, 2.0f, -25},
        {-4,  1.00f, 1.00f, 0.86f, 0.84f, 1.22f, 1.10f, 1.34f, 0.110f, 0.05f, 2.5f, -30},
        {0,   1.30f, 0.85f, 1.04f, 0.93f, 1.03f, 1.20f, 1.36f, 0.100f, 1.00f, 5.0f,  40},
        {5,   1.22f, 1.00f, 1.02f, 0.95f, 1.00f, 1.18f, 1.38f, 0.090f, 0.85f, 4.0f,  42},
        {12,  1.12f, 1.00f, 1.01f, 0.97f, 0.99f, 1.14f, 1.40f, 0.085f, 0.55f, 2.5f,  32},
        {25,  1.04f, 1.00f, 0.98f, 0.99f, 1.03f, 1.08f, 1.40f, 0.080f, 0.32f, 1.2f,  15},
        {45,  1.00f, 1.00f, 0.95f, 1.00f, 1.08f, 1.02f, 1.40f, 0.075f, 0.22f, 0.6f,   0},
        {65,  1.00f, 1.00f, 0.95f, 1.00f, 1.10f, 1.00f, 1.42f, 0.075f, 0.18f, 0.5f,  -5},
    };
    private static final float[][] SKY_GOLD = {
        {-6, 1.00f, 1.00f, 1.00f, 1.00f, 1.00f, 1.00f},
        {-2, 1.10f, 0.94f, 0.96f, 1.08f, 0.93f, 1.02f},
        {2,  1.16f, 0.97f, 0.84f, 1.12f, 0.94f, 0.98f},
        {8,  1.13f, 0.99f, 0.87f, 1.08f, 0.97f, 0.98f},
        {16, 1.08f, 1.00f, 0.92f, 1.04f, 0.99f, 0.99f},
        {28, 1.03f, 1.00f, 0.97f, 1.01f, 1.00f, 1.00f},
        {40, 1.00f, 1.00f, 1.00f, 1.00f, 1.00f, 1.00f},
    };
    private static final float[][] SKY_ROSE = {
        {-6, 0f}, {-3, 0.32f}, {0, 0.64f}, {4, 0.70f}, {9, 0.56f}, {16, 0.28f}, {26, 0.07f}, {34, 0f}
    };
    private static final float[] ROSE_LOOK = {1f, 1.15f, 0.6f, 1.4f};
    static final float ROSE_AMOUNT = 0.25f;

    private static final int K_GAMMA = 1, K_LIGHT = 2, K_AMB = 3, K_SAT = 6, K_CONTRAST = 7, K_BLOOM = 8, K_VL = 9, K_MIST = 10, K_WB = 11;

    // looks: 0 EPIC, 1 STORYBOOK, 2 NATURAL, 3 PASTEL (alpha.25: "Leica Vibrant, but more pastel and cuter": vibrant midtones
    // through the vibrance step, softer airy contrast, highlights that whiten sooner (inset), rosy lifted blacks and a faint pink
    // highlight gain, pinker sunsets, a little more bloom)
    private static final float[] PRESET_GAMMA = {1.0f, 1.15f, 0.9f, 1.05f}, PRESET_SAT = {0.08f, 0.14f, 0.02f, 0.26f},
        PRESET_CONTRAST = {1.05f, 0.97f, 0.95f, 0.84f}, PRESET_BLOOM = {1.0f, 1.25f, 0.8f, 1.45f},
        PRESET_LAMBDA = {0.55f, 0.40f, 0.70f, 0.50f}, PRESET_INSET = {0.20f, 0.16f, 0.24f, 0.34f},
        PRESET_VL = {1.0f, 1.25f, 0.8f, 1.1f}, PRESET_SPECTRUM = {0.6f, 0.9f, 0.3f, 0.75f},
        PRESET_VIBRANCE = {0.10f, 0.18f, 0.10f, 0.36f},
        PRESET_EV = {0f, 0f, 0f, 0.3f}; // exposure bias (EV): pastel is a bright, high-key look
    // display lift (linear, added after the tone curve) and gain per look
    private static final float[][] PRESET_LIFT = {{0f, 0f, 0f}, {0f, 0f, 0f}, {0f, 0f, 0f}, {0.030f, 0.019f, 0.030f}},
        PRESET_GAIN = {{1f, 1f, 1f}, {1f, 1f, 1f}, {1f, 1f, 1f}, {1.0f, 0.93f, 0.965f}};
    // a white-balance tint per look, applied with the white balance before the tone curve (PASTEL: rose through the midtones)
    private static final float[][] PRESET_TINT = {{1f, 1f, 1f}, {1f, 1f, 1f}, {1f, 1f, 1f}, {1.03f, 0.96f, 1.0f}};
    public static final int LOOKS = 4, PASTEL = 3;
    private float pastelK = 1f;

    /** A look parameter: PASTEL blends from EPIC's value by Pastel Strength (0 = Epic, 1 = Pastel, up to 1.5 beyond it). */
    private float lk(float[] a) {
        return this.lookPreset == PASTEL ? a[0] + (a[PASTEL] - a[0]) * this.pastelK : a[this.lookPreset];
    }

    private float[] lk3(float[][] a) {
        if (this.lookPreset != PASTEL) return a[this.lookPreset];
        float[] r = new float[3];
        for (int i = 0; i < 3; i++) r[i] = a[0][i] + (a[PASTEL][i] - a[0][i]) * this.pastelK;
        return r;
    }

    static final float MID_IN = 0.18f, MID_OUT = 0.20f, WHITE = 12f, SHOULDER = 0.92f;
    static final float METER_KEY = 0.30f, EV_DOWN = 1.75f, EV_UP = 1.75f, EV_UP_NIGHT = 0.6f, TAU_UP = 0.6f, TAU_DOWN = 2.2f;
    static final float[] HAZE_SIGMA = {0.22e-3f * 0.40f, 0.48e-3f * 0.40f, 1.0e-3f * 0.40f};
    static final float MIST_SCALE = 0.35f;
    public static final float HAZE_H = 48f, HAZE_BASE = 16f, MIST_H = 10f, MIST_BASE = 4f, MIST_ALBEDO = 0.9f, SEA = 63f;
    static final float SUN_RADIUS = (float) Math.toRadians(1.0), MOON_RADIUS = (float) Math.toRadians(0.65);

    public float elevation, rising, chromaGamma, lightMul, saturation, contrast, bloomMix, vlStrength, mistSigma, whiteBalance;
    public final float[] ambientTint = new float[3], wbGain = {1f, 1f, 1f};
    public final float[] skyGold = {1f, 1f, 1f, 1f, 1f, 1f};
    public float skyRose;
    public float toneB, toneBeta, inset, exposureRef = 1f;
    public float starBrightness, moonPhaseAngle, borderRadius;
    public float outdoor = 1f;
    private float eyeSky = 1f;
    private float rainFog;
    private final float[][] gradeIn = new float[3][3], gradeOut = new float[3][3], gradeInInv = new float[3][3], gradeOutInv = new float[3][3];
    private final Matrix4f celestial = new Matrix4f();
    private final Matrix4f scratchMat = new Matrix4f();
    private final float[] scratchGold = new float[7];
    private boolean snapExposure = true;
    private boolean hasPrevScene;
    private float dt;
    private int features;
    private int lookPreset;

    private float l2Bounce = 1f, l2Ev = 0f, l2Lambda = 1f, l2Sheen = 0f, l2Face = 0f;
    private final float[] l2Sky = {1f, 1f, 1f}, l2Tint = new float[3];

    public ShadeLook() {
        // Initialize valid default Lottes curve & identity grade matrices before first world frame.
        this.contrast = 1.40f;
        double wa = Math.pow(WHITE, this.contrast), ma = Math.pow(MID_IN, this.contrast);
        double wad = Math.pow(WHITE, this.contrast * SHOULDER), mad = Math.pow(MID_IN, this.contrast * SHOULDER);
        this.toneB = (float) ((wa / 1.0 - ma / MID_OUT) / (wad - mad));
        this.toneBeta = (float) (ma / MID_OUT - mad * this.toneB);
        this.inset = PRESET_INSET[0];
        this.saturation = 1.0f;
        this.bloomMix = 0.08f;
        satMatrix(Math.max(0.05f, this.saturation * (1f - this.inset)), this.gradeIn);
        satMatrix(1f / (1f - 0.6f * this.inset), this.gradeOut);
        invert(this.gradeIn, this.gradeInInv);
        invert(this.gradeOut, this.gradeOutInv);
        this.features = FEATURE_HDR | FEATURE_BLOOM | FEATURE_AUTO_EXPOSURE | FEATURE_STARS | FEATURE_HAZE | FEATURE_LIGHT_V2;
    }

    public void snapExposure() {
        this.snapExposure = true;
        this.hasPrevScene = false;
    }

    public void setHasPrevScene(boolean hasPrevScene) {
        this.hasPrevScene = hasPrevScene;
    }

    public void setOptions(ShadeSettings options) {
        this.options = options;
        setLookPreset(options.post().look());
        this.pastelK = Math.max(0f, Math.min(1.5f, options.post().pastel()));
    }

    public void setLookPreset(int preset) {
        this.lookPreset = Math.max(0, Math.min(LOOKS - 1, preset));
    }

    /** The bloom pyramid's level weighting exponent for the current look. */
    public float bloomSpectrum() {
        return lk(PRESET_SPECTRUM);
    }

    public int lookPreset() {
        return this.lookPreset;
    }

    public int features() {
        return this.features;
    }

    public void update(ShadeFrame f, int moonPhaseIndex, float dtSeconds) {
        this.dt = Math.max(0f, Math.min(dtSeconds, 0.25f));
        int look = this.lookPreset;
        float sunY = Math.max(-1f, Math.min(1f, f.sunDir.y));
        this.elevation = (float) Math.toDegrees(Math.asin(sunY));
        this.rising = f.dayTime > 0.5f ? 1f : -1f;
        float[] k = keyframe(this.elevation);
        float rain = f.rain, thunder = f.thunder;
        this.chromaGamma = k[K_GAMMA] * lk(PRESET_GAMMA);
        this.lightMul = k[K_LIGHT];
        for (int i = 0; i < 3; i++) this.ambientTint[i] = k[K_AMB + i];
        this.saturation = k[K_SAT] + lk(PRESET_SAT);
        this.contrast = k[K_CONTRAST] * lk(PRESET_CONTRAST);
        this.bloomMix = k[K_BLOOM] * lk(PRESET_BLOOM);
        this.vlStrength = k[K_VL] * lk(PRESET_VL);
        this.mistSigma = k[K_MIST];
        this.whiteBalance = k[K_WB];

        float lowSun = smooth(-12f, -2f, this.elevation) * (1f - smooth(15f, 35f, this.elevation));
        if (this.rising > 0f) {
            this.mistSigma *= 1f + 0.6f * lowSun;
            this.whiteBalance -= 10f * lowSun;
            this.saturation -= 0.04f * lowSun;
        } else {
            this.mistSigma *= 1f - 0.1f * lowSun;
            this.whiteBalance += 8f * lowSun;
        }

        float[] sg = SKY_GOLD[SKY_GOLD.length - 1];
        if (this.elevation <= SKY_GOLD[0][0]) sg = SKY_GOLD[0];
        for (int i = 0; i + 1 < SKY_GOLD.length; i++) {
            if (this.elevation >= SKY_GOLD[i][0] && this.elevation < SKY_GOLD[i + 1][0]) {
                float t = (this.elevation - SKY_GOLD[i][0]) / (SKY_GOLD[i + 1][0] - SKY_GOLD[i][0]);
                sg = this.scratchGold;
                for (int c = 1; c < 7; c++) sg[c] = SKY_GOLD[i][c] + (SKY_GOLD[i + 1][c] - SKY_GOLD[i][c]) * t;
                break;
            }
        }
        float goldK = (this.rising > 0f ? 0.7f : 1f) * (1f - rain);
        for (int c = 0; c < 6; c++) this.skyGold[c] = 1f + (sg[c + 1] - 1f) * goldK;

        float rose = 0f;
        for (int i = 0; i + 1 < SKY_ROSE.length; i++) {
            if (this.elevation >= SKY_ROSE[i][0] && this.elevation < SKY_ROSE[i + 1][0]) {
                float t = (this.elevation - SKY_ROSE[i][0]) / (SKY_ROSE[i + 1][0] - SKY_ROSE[i][0]);
                rose = SKY_ROSE[i][1] + (SKY_ROSE[i + 1][1] - SKY_ROSE[i][1]) * t;
                break;
            }
        }
        this.skyRose = rose * goldK * lk(ROSE_LOOK) * ROSE_AMOUNT;
        ShadeSky.sunsetArt = true;

        float rainFog = rain;
        this.rainFog = rainFog;
        float night = 1f - smooth(-10f, -2f, this.elevation);
        this.saturation += (Math.max(this.saturation, 1f) - this.saturation) * night;
        this.saturation *= 1f - 0.25f * rain;
        this.contrast -= 0.08f * rain;
        this.bloomMix += 0.03f * rain;
        this.mistSigma *= 1f + 4f * rainFog;
        this.whiteBalance -= 10f * rain;
        this.lightMul *= 1f - 0.1f * thunder;

        this.outdoor = smooth(0f, 0.5f, this.eyeSky);
        if (this.outdoor < 1f) {
            float[] day = keyframe(45f);
            float in = 1f - this.outdoor;
            this.whiteBalance += (day[K_WB] - this.whiteBalance) * in;
            this.contrast += (day[K_CONTRAST] * lk(PRESET_CONTRAST) - this.contrast) * in;
            this.saturation += (day[K_SAT] + lk(PRESET_SAT) - this.saturation) * in;
            this.bloomMix += (day[K_BLOOM] * lk(PRESET_BLOOM) - this.bloomMix) * in;
        }

        float lightK = 1f;
        if (f.naturalLighting > 0f) lightK *= 1f + 0.35f * f.naturalLighting;
        gradeLight(f.sky.light, f.sky.sunLight ? this.chromaGamma : 1f, this.lightMul * lightK);
        look2Pre(f, rain);

        float mired = 1e6f / 6504f + this.whiteBalance;
        float[] target = blackbody(1e6f / Math.max(mired, 20f)), d65 = blackbody(6504f);
        float[] tint = lk3(PRESET_TINT);
        for (int i = 0; i < 3; i++) this.wbGain[i] = (1f + (target[i] / d65[i] - 1f) * 0.5f) * tint[i];
        float l = luma(this.wbGain[0], this.wbGain[1], this.wbGain[2]);
        for (int i = 0; i < 3; i++) this.wbGain[i] /= l;

        float a = this.contrast, d = SHOULDER;
        double wa = Math.pow(WHITE, a), ma = Math.pow(MID_IN, a), wad = Math.pow(WHITE, a * d), mad = Math.pow(MID_IN, a * d);
        this.toneB = (float) ((wa / 1.0 - ma / MID_OUT) / (wad - mad));
        this.toneBeta = (float) (ma / MID_OUT - mad * this.toneB);

        this.inset = lk(PRESET_INSET);
        if (options != null) {
            this.saturation *= options.post().saturation();
            this.bloomMix *= options.post().bloomStrength();
        }
        float sIn = Math.max(0.05f, this.saturation * (1f - this.inset));
        float sOut = 1f / (1f - 0.6f * this.inset);
        satMatrix(sIn, this.gradeIn);
        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) this.gradeIn[r][c] *= this.wbGain[c];
        satMatrix(sOut, this.gradeOut);
        invert(this.gradeIn, this.gradeInInv);
        invert(this.gradeOut, this.gradeOutInv);

        this.exposureRef = f.exposure * (float) Math.pow(2.0, -0.7f * rain * this.outdoor + this.l2Ev * this.outdoor);
        this.eyeSky += (f.eyeSkyLight / 15f - this.eyeSky) * (1f - (float) Math.exp(-this.dt / 1.5f));
        this.starBrightness = f.starBrightness * (1f - rain);
        this.moonPhaseAngle = (float) Math.toRadians(45.0 * Math.floorMod(moonPhaseIndex, 8));

        float t = (float) Math.toRadians(ShadeSky.SUN_TILT);
        float px = 0f, py = (float) -Math.sin(t), pz = (float) Math.cos(t);
        float sx = f.sunDir.x, sy = f.sunDir.y, sz = f.sunDir.z;
        float ex = py * sz - pz * sy, ey = pz * sx - px * sz, ez = px * sy - py * sx;
        this.celestial.set(sx, sy, sz, 0, ex, ey, ez, 0, px, py, pz, 0, 0, 0, 0, 1);

        this.borderRadius = f.fogRenderStart < f.fogRenderEnd && f.fogRenderEnd < 1e5f ? Math.max(f.fogRenderEnd - 8f, 16f) : 0f;
        this.features = FEATURE_HDR | FEATURE_AUTO_EXPOSURE | FEATURE_LIGHT_V2;
        if (options == null || options.post().bloom()) this.features |= FEATURE_BLOOM;
        if (options == null || options.sky().stars()) this.features |= FEATURE_STARS;
        if (options == null || options.sky().haze()) this.features |= FEATURE_HAZE;
    }

    public void pack(ByteBuffer out, ShadeFrame f) {
        ByteBuffer b = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        putMat(this.scratchMat.translation(-f.jitterX, -f.jitterY, 0f).mul(f.viewProj), b, VIEW_PROJ);
        putMat(this.scratchMat.translation(-f.prevJitterX, -f.prevJitterY, 0f).mul(f.prevViewProj), b, PREV_VIEW_PROJ);
        putMat(this.celestial, b, CELESTIAL);
        putMat(this.scratchMat.identity(), b, CLOUD_SHADOW_VP);
        put4(b, WATER_SHADOW, 0f, 0f, 0f, 0f);
        put4(b, WATER, 0f, 0f, 0f, 0f);
        put4(b, DIM_TINT, 0f, 0f, 0f, 0f);
        put4(b, TINT_RECT, 1f, 1f, -1f, -1f);
        put4(b, SUN_GEOM, (float) Math.toRadians(ShadeSky.SUN_TILT), SUN_RADIUS, MOON_RADIUS, (float) Math.toRadians(this.elevation));
        float[] l = f.sky.light;
        put4(b, SUN_ART, l[0], l[1], l[2], 1f);
        put4(b, AMBIENT_ART, this.ambientTint[0], this.ambientTint[1], this.ambientTint[2], 0.06f * (1f - 0.7f * f.rain) * this.l2Bounce);
        put4(b, BOUNCE, 0.62f, 0.56f, 0.44f, 0f);
        put4(b, GRADE0, (options == null ? 0f : options.post().exposureEv()) + lk(PRESET_EV), this.saturation,
            lk(PRESET_VIBRANCE), 1f);
        put4(b, GRADE1, this.wbGain[0], this.wbGain[1], this.wbGain[2], 0.55f);
        float[] lift = lk3(PRESET_LIFT), gain = lk3(PRESET_GAIN);
        put4(b, GRADE2, lift[0], lift[1], lift[2], 0.0025f);
        put4(b, GRADE3, gain[0], gain[1], gain[2], this.inset);
        put4(b, TONEMAP, this.contrast, SHOULDER, this.toneB, this.toneBeta);
        float inverseMax = Math.min(0.80f, 0.95f / (this.toneB * SHOULDER));
        put4(b, OUTPUT, 1f, 1f, 1f, inverseMax);
        put4(b, BLOOM, this.bloomMix, lk(PRESET_SPECTRUM), 0.06f * (1f + f.rain), 1f);
        float hazeScale = options == null ? 1f : options.sky().hazeStrength();
        float haze = (1f + this.rainFog) * hazeScale;
        put4(b, FOG_R, HAZE_SIGMA[0] * haze, HAZE_SIGMA[1] * haze, HAZE_SIGMA[2] * haze, HAZE_H);
        put4(b, FOG_M, this.mistSigma * 1e-3f * MIST_SCALE * hazeScale, MIST_H * (1f + 2f * this.rainFog), SEA + MIST_BASE, MIST_ALBEDO + (0.6f - MIST_ALBEDO) * f.rain);
        double glow = 0.6 * (1f - f.rain) * Math.exp(-Math.pow((this.elevation + 1.0) / 2.5, 2.0));
        float borderFrac = this.rainFog > 0f ? 0.78f - 0.18f * this.rainFog : 0.78f;
        put4(b, FOG_MISC, SEA + HAZE_BASE, borderFrac, this.borderRadius, (float) glow);
        put4(b, VL, options == null ? 12f : options.atmosphere().lightSteps(),
            options == null ? 1f : options.atmosphere().lightStrength(), waterShaftSurface, 0f);
        put4(b, WET, wetness, puddles, snow, f.rain);
        float[] w = this.cloudWeather; // (ShadeWeather: weatherA cumulus / altocumulus coverage, weatherB the rest)
        put4(b, WIND, w[0], w[1], w[2], w[3]);
        // clouds0: x cumulus base (block y), y coverage scale (clouds.metal cloudLayer), w volumetric clouds on
        // (z: -Dcelestiametal.shade.cloudDev, live, pricing: 1 no altocumulus, 2 no cirrus, 4 no cumulus, 8 trace nothing)
        put4(b, CLOUDS0, cloudBase, options == null ? 1f : options.atmosphere().cloudCoverage(),
            (float) Integer.getInteger("celestiametal.shade.cloudDev", 0), cloudsEnabled ? 1f : 0f);
        put4(b, CLOUDS1, cloudsEnabled ? 1f : 0f, cloudSteps,
            options == null ? 1f : options.atmosphere().cloudDensity(), cloudPhase);
        put4(b, EYE, 0.5f, 0.5f, 1f, this.eyeSky);
        put4(b, SKY_GOLD_H, this.skyGold[0], this.skyGold[1], this.skyGold[2], 1f);
        put4(b, SKY_GOLD_Z, this.skyGold[3], this.skyGold[4], this.skyGold[5], this.skyRose);
        put4(b, NIGHT, this.starBrightness, 1f, this.auroraStrength, this.moonPhaseAngle);
        put4(b, SSR, this.hasPrevScene ? 1f : 0f, 0f, 0f, 0f);
        float nightUp = EV_UP - (EV_UP - EV_UP_NIGHT) * (1f - smooth(-10f, -2f, this.elevation)) * this.outdoor;
        put4(b, EXPOSURE_CFG, EV_DOWN, nightUp, TAU_UP, TAU_DOWN);
        put4(b, WEATHER_B, w[4], w[5], w[6], w[7]);
        put4(b, FLASH, flashX, flashY, flashZ, flashStrength);
        put4(b, RENDER_SCALE, f.renderScale, (float) (Math.log(Math.max(f.mipScale, 1e-4f)) / Math.log(2.0)), f.width, f.height);
        put4(b, DT, this.dt, f.gameTimeSeconds, 0f, this.rising);
        float airSky = smooth(2f / 15f, 10f / 15f, this.eyeSky);
        put4(b, CLOCK2, f.skyTime, airSky, 1f, airSky);
        b.putInt(TIER, 1).putInt(TIER + 4, this.features).putInt(TIER + 8, this.lookPreset).putInt(TIER + 12, f.debug);
        putRows(b, GRADE_IN, this.gradeIn);
        putRows(b, GRADE_OUT, this.gradeOut);
        putRows(b, GRADE_IN_INV, this.gradeInInv);
        putRows(b, GRADE_OUT_INV, this.gradeOutInv);
        float lambda = Math.min(lk(PRESET_LAMBDA) * this.l2Lambda, 1f);
        put4(b, EXPOSURE_REF, this.exposureRef, lambda, METER_KEY, this.snapExposure ? 1f : 0f);
        this.snapExposure = false;
        put4(b, USER0, SUN_RADIUS, 0.12f, 1f, 1f);
        put4(b, USER1, 1f, 1f, options == null ? 1f : options.water().foam(), 1f);
        put4(b, USER2, 1f, 1f, 0f, 0.45f);
        put4(b, USER3, f.naturalLighting, 1f, 1f, 1f);
        put4(b, USER4, 2f, 0f, 3f, 1f);
        put4(b, LOOK2A, this.l2Sheen, this.l2Face, 0.75f, 80f);
        put4(b, LOOK2B, this.l2Sky[0], this.l2Sky[1], this.l2Sky[2], 0.1f);
    }

    private void look2Pre(ShadeFrame f, float rain) {
        this.l2Bounce = 1f;
        this.l2Ev = 0f;
        this.l2Lambda = 1f;
        this.l2Sheen = 0f;
        this.l2Face = 0f;
        this.l2Sky[0] = this.l2Sky[1] = this.l2Sky[2] = 1f;
        if (f.dimension != ShadeFrame.DIM_OVERWORLD) return;
        float e = this.elevation, sunY = (float) Math.sin(Math.toRadians(e));
        boolean sun = f.sky.sunLight;
        float day = smooth(-6f, 6f, e);
        if (sun) {
            // Rose-gold low sun tint (adapted from Photon Shaders, MIT License).
            float p = Math.max(0f, 1f - Math.abs(sunY - 0.17f) / 0.40f);
            float w = Math.min(p * p * (1f - rain), 1.5f);
            float l = luma(1.05f, 0.84f, 0.93f);
            this.l2Tint[0] = 1f + (1.05f / l - 1f) * w;
            this.l2Tint[1] = 1f + (0.84f / l - 1f) * w;
            this.l2Tint[2] = 1f + (0.93f / l - 1f) * w;
            for (int i = 0; i < 3; i++) f.sky.light[i] *= this.l2Tint[i];
            gradeLight(f.sky.light, 1f + 0.25f * day * (1f - rain), 1f);
        }
        float kd = day * (1f - rain);
        if (sun && kd > 0f) for (int i = 0; i < 3; i++) f.sky.light[i] *= 1f + 0.2f * kd;
        this.whiteBalance += 22f * day * (1f - rain) * this.outdoor;
        if (day > 0f) {
            float amb = 1f + (0.55f - 1f) * day;
            // (alpha.26: the sky light keeps the sky's blue, like Photon's; was a warm {1.05, 1, 0.84})
            float[] warm = {0.86f, 1f, 1.14f};
            for (int i = 0; i < 3; i++) this.ambientTint[i] *= amb * (1f + (warm[i] - 1f) * day);
            this.l2Bounce = 1f + (0.6f - 1f) * day;
            this.l2Face = 0.12f * day;
        }
        float w = smooth(30f, 3f, e) * smooth(-8f, 2f, e) * (this.rising > 0f ? 0f : 1f);
        this.l2Ev = -0.6f * w * (1f - 0.5f * rain) + 0.3f * smooth(25f, 50f, e);
        this.l2Lambda = (1f - 0.5f * Math.min(w, 1f)) * (1f - 0.5f * day);
        this.contrast *= 1f + 0.03f * day * this.outdoor;
        this.l2Lambda = 1f - (1f - this.l2Lambda) * this.outdoor;
        if (rain * this.outdoor > 0f) {
            float kr = rain * this.outdoor;
            this.saturation *= 1f + 0.45f * kr;
            this.whiteBalance -= 16f * kr;
            this.l2Ev -= 0.35f * kr;
        }
        float dw = smooth(8f, 25f, e) * (1f - rain);
        float bh = (float) Math.exp(-Math.pow((e + 3.5f) / 2.8f, 2.0)) * (1f - rain);
        float[] dg = {0.86f, 0.78f, 0.74f}, bg = {0.55f, 0.62f, 1.25f};
        for (int i = 0; i < 3; i++) this.l2Sky[i] = (1f + (dg[i] - 1f) * dw) * (1f + (bg[i] - 1f) * Math.min(bh, 1f));
        this.skyRose *= 1f - Math.min(bh, 1f);
        for (int c = 0; c < 6; c++) this.skyGold[c] = 1f + (this.skyGold[c] - 1f) * (1f - Math.min(bh, 1f));
        for (float[] h : f.sky.horizon) for (int i = 0; i < 3; i++) h[i] *= this.l2Sky[i];
        if (sun) {
            Matrix4f vp = f.viewProj;
            float fx = vp.m03(), fy = vp.m13(), fz = vp.m23(), fl = (float) Math.sqrt(fx * fx + fy * fy + fz * fz);
            float[] ld = f.sky.lightDir;
            float mu = fl > 0f ? (fx * ld[0] + fy * ld[1] + fz * ld[2]) / fl : 0f;
            float g = 0.5f, x = 1f + g * g - 2f * g * mu;
            float hg = 0.0795775f * (1f - g * g) / (float) Math.pow(Math.max(x, 1e-4f), 1.5);
            this.l2Sheen = 0.55f * hg * linearStep(-0.8f, -0.2f, mu) * (1f - rain) * smooth(-2f, 4f, e);
        }
    }

    static float[] keyframe(float e) {
        int n = KEYS.length;
        float[] out = new float[KEYS[0].length];
        if (e <= KEYS[0][0]) return KEYS[0].clone();
        if (e >= KEYS[n - 1][0]) return KEYS[n - 1].clone();
        int i = 0;
        while (KEYS[i + 1][0] < e) i++;
        float t = (e - KEYS[i][0]) / (KEYS[i + 1][0] - KEYS[i][0]);
        float[] p0 = KEYS[Math.max(i - 1, 0)], p1 = KEYS[i], p2 = KEYS[i + 1], p3 = KEYS[Math.min(i + 2, n - 1)];
        for (int c = 1; c < out.length; c++) {
            boolean colour = c >= K_AMB && c < K_AMB + 3;
            float a0 = colour ? (float) Math.sqrt(p0[c]) : p0[c], a1 = colour ? (float) Math.sqrt(p1[c]) : p1[c];
            float a2 = colour ? (float) Math.sqrt(p2[c]) : p2[c], a3 = colour ? (float) Math.sqrt(p3[c]) : p3[c];
            float v = catmullRom(a0, a1, a2, a3, t);
            v = Math.max(Math.min(a1, a2), Math.min(Math.max(a1, a2), v));
            out[c] = colour ? v * v : v;
        }
        out[0] = e;
        return out;
    }

    private static float catmullRom(float p0, float p1, float p2, float p3, float t) {
        float t2 = t * t, t3 = t2 * t;
        return 0.5f * (2f * p1 + (p2 - p0) * t + (2f * p0 - 5f * p1 + 4f * p2 - p3) * t2 + (3f * p1 - p0 - 3f * p2 + p3) * t3);
    }

    static void gradeLight(float[] c, float gamma, float mul) {
        float y = luma(c[0], c[1], c[2]);
        if (y <= 0f) return;
        float q0 = (float) Math.pow(Math.max(c[0] / y, 0f), gamma);
        float q1 = (float) Math.pow(Math.max(c[1] / y, 0f), gamma);
        float q2 = (float) Math.pow(Math.max(c[2] / y, 0f), gamma);
        float ql = luma(q0, q1, q2);
        if (ql <= 0f) return;
        float s = y * mul / ql;
        c[0] = q0 * s; c[1] = q1 * s; c[2] = q2 * s;
    }

    static void satMatrix(float s, float[][] m) {
        float[] w = {0.2126f, 0.7152f, 0.0722f};
        for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++) m[r][c] = (1f - s) * w[c] + (r == c ? s : 0f);
    }

    static void invert(float[][] m, float[][] out) {
        float a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2];
        float A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
        float det = a * A + b * B + c * C;
        float inv = Math.abs(det) > 1e-12f ? 1f / det : 0f;
        out[0][0] = A * inv; out[0][1] = -(b * i - c * h) * inv; out[0][2] = (b * f - c * e) * inv;
        out[1][0] = B * inv; out[1][1] = (a * i - c * g) * inv; out[1][2] = -(a * f - c * d) * inv;
        out[2][0] = C * inv; out[2][1] = -(a * h - b * g) * inv; out[2][2] = (a * e - b * d) * inv;
    }

    static float[] blackbody(float kelvin) {
        double[] lam = {610e-9, 550e-9, 465e-9};
        float[] out = new float[3];
        for (int i = 0; i < 3; i++) out[i] = (float) (1.0 / (Math.pow(lam[i], 5) * (Math.exp(1.4388e-2 / (lam[i] * kelvin)) - 1.0)));
        float l = luma(out[0], out[1], out[2]);
        for (int i = 0; i < 3; i++) out[i] /= l;
        return out;
    }

    public float[] display(float[] x) {
        float[] c = new float[3];
        for (int r = 0; r < 3; r++) c[r] = Math.max(0f, this.gradeIn[r][0] * x[0] + this.gradeIn[r][1] * x[1] + this.gradeIn[r][2] * x[2]);
        for (int r = 0; r < 3; r++) {
            double xa = Math.pow(Math.max(c[r], 1e-7), this.contrast), xad = Math.pow(Math.max(c[r], 1e-7), this.contrast * SHOULDER);
            c[r] = (float) Math.min(1.0, xa / (xad * this.toneB + this.toneBeta));
        }
        float[] y = new float[3];
        float[] lift = lk3(PRESET_LIFT), gain = lk3(PRESET_GAIN);
        for (int r = 0; r < 3; r++) {
            y[r] = Math.max(0f, this.gradeOut[r][0] * c[0] + this.gradeOut[r][1] * c[1] + this.gradeOut[r][2] * c[2]);
            y[r] = Math.max(0f, y[r] * gain[r] + lift[r]); // (shadeDisplay: gain, then lift)
        }
        return y;
    }

    public float[] ldrToHdr(float r, float g, float b) {
        float[] s = {r, g, b}, y = new float[3], c = new float[3], x = new float[3];
        for (int i = 0; i < 3; i++) {
            float v = Math.min(Math.max(s[i], 0f), 1f);
            s[i] = v <= 0.04045f ? v / 12.92f : (float) Math.pow((v + 0.055f) / 1.055f, 2.4f);
        }
        float max = Math.min(0.80f, 0.95f / (this.toneB * SHOULDER));
        float[] lift = lk3(PRESET_LIFT), gain = lk3(PRESET_GAIN);
        for (int i = 0; i < 3; i++) s[i] = (s[i] - lift[i]) / Math.max(gain[i], 1e-3f); // (shadeLdrToHdr: lift and gain first)
        for (int i = 0; i < 3; i++) y[i] = Math.min(max, Math.max(0f, this.gradeOutInv[i][0] * s[0] + this.gradeOutInv[i][1] * s[1] + this.gradeOutInv[i][2] * s[2]));
        for (int i = 0; i < 3; i++) {
            double yy = y[i], bb = this.toneB, d = SHOULDER, beta = this.toneBeta;
            double u = (yy * bb * (1 - d) + yy * beta) / (1 - yy * bb * d);
            for (int k = 0; k < 6; k++) {
                double ud = Math.pow(Math.max(u, 1e-12), d);
                double gv = u - yy * (bb * ud + beta), dg = 1 - yy * bb * d * ud / Math.max(u, 1e-12);
                u = Math.max(u - gv / Math.max(dg, 0.05), 0);
            }
            c[i] = (float) Math.pow(u, 1.0 / this.contrast);
        }
        for (int i = 0; i < 3; i++) x[i] = Math.max(0f, this.gradeInInv[i][0] * c[0] + this.gradeInInv[i][1] * c[1] + this.gradeInInv[i][2] * c[2]);
        return x;
    }

    private static float luma(float r, float g, float b) {
        return 0.2126f * r + 0.7152f * g + 0.0722f * b;
    }

    private static float smooth(float e0, float e1, float x) {
        float t = Math.min(Math.max((x - e0) / (e1 - e0), 0f), 1f);
        return t * t * (3f - 2f * t);
    }

    private static float linearStep(float e0, float e1, float x) {
        return Math.min(Math.max((x - e0) / (e1 - e0), 0f), 1f);
    }

    /** Recomputes Lottes tonemap parameters for a custom contrast and writes TONEMAP + OUTPUT.w. */
    static void writeTonemap(ByteBuffer L, float contrast) {
        double wa = Math.pow(WHITE, contrast), ma = Math.pow(MID_IN, contrast);
        double wad = Math.pow(WHITE, contrast * SHOULDER), mad = Math.pow(MID_IN, contrast * SHOULDER);
        float toneB = (float) ((wa / 1.0 - ma / MID_OUT) / (wad - mad));
        float toneBeta = (float) (ma / MID_OUT - mad * toneB);
        float inverseMax = Math.min(0.80f, 0.95f / (toneB * SHOULDER));
        put4(L, TONEMAP, contrast, SHOULDER, toneB, toneBeta);
        L.putFloat(OUTPUT + 12, inverseMax);
    }

    private static void putMat(Matrix4f m, ByteBuffer b, int at) {
        if (b.isDirect()) {
            m.get(at, b);
        } else {
            b.putFloat(at, m.m00()).putFloat(at + 4, m.m01()).putFloat(at + 8, m.m02()).putFloat(at + 12, m.m03())
                .putFloat(at + 16, m.m10()).putFloat(at + 20, m.m11()).putFloat(at + 24, m.m12()).putFloat(at + 28, m.m13())
                .putFloat(at + 32, m.m20()).putFloat(at + 36, m.m21()).putFloat(at + 40, m.m22()).putFloat(at + 44, m.m23())
                .putFloat(at + 48, m.m30()).putFloat(at + 52, m.m31()).putFloat(at + 56, m.m32()).putFloat(at + 60, m.m33());
        }
    }

    private static void put4(ByteBuffer b, int at, float x, float y, float z, float w) {
        b.putFloat(at, x).putFloat(at + 4, y).putFloat(at + 8, z).putFloat(at + 12, w);
    }

    private static void putRows(ByteBuffer b, int at, float[][] m) {
        for (int r = 0; r < 3; r++) put4(b, at + 16 * r, m[r][0], m[r][1], m[r][2], 0f);
    }
}
