// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/ShadeFrame.java
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
import org.joml.Matrix4fc;
import org.joml.Vector3f;

/**
 * Per-frame physical atmosphere & camera uniform block packed in the exact 1024-byte layout of
 * {@code struct ShadeFrame} in {@code shaders/ported/shade_common.metal} at {@code buffer(24)}.
 */
public final class ShadeFrame {
    public static final int VIEW = 0, PROJ = 64, VIEW_PROJ = 128, INV_VIEW_PROJ = 192, PREV_VIEW_PROJ = 256, SHADOW_VIEW_PROJ = 320,
        CAMERA_BLOCK = 448, CAMERA_FRACT = 464, SUN_DIR_WORLD = 480, SUN_DIR_VIEW = 496, MOON_DIR_WORLD = 512, LIGHT_DIR_WORLD = 528,
        SUN_COLOR = 544, AMBIENT_SKY = 560, AMBIENT_GROUND = 576, AMBIENT_BLOCK = 592, FOG_COLOR = 608, FOG_RANGE = 624, FOG_SKY = 640,
        FOG_COLOR_HDR = 656, ZENITH_COLOR = 672, HORIZON = 688, CASCADE_SPLITS = 816, SHADOW_PARAMS = 832, SCREEN = 848, TIME = 864,
        WEATHER = 880, JITTER = 896, ATMOSPHERE = 912, AMBIENT_TOWARD = 928, AMBIENT_AWAY = 944, FLAGS = 960, FLAGS2 = 976, SUN_PATH = 992,
        WX_LINE = 1008;
    public static final int SIZE = 1024;

    static final int DEV_BITS = Integer.getInteger("celestiametal.shade.dev", Integer.getInteger("mcopt.shade.dev", 0));

    public static final int DEV_NO_UNDERWATER_SHAFTS = 128;

    public static int devBits() {
        return Integer.getInteger("celestiametal.shade.dev", Integer.getInteger("mcopt.shade.dev", DEV_BITS));
    }

    public static final int DIM_OVERWORLD = 0, DIM_NETHER = 1, DIM_END = 2, DIM_VANILLA = 3;
    public static final int FOG_AIR = 0, FOG_WATER = 1, FOG_LAVA = 2, FOG_POWDER_SNOW = 3;

    public final Matrix4f view = new Matrix4f(), proj = new Matrix4f(), viewProj = new Matrix4f(), invViewProj = new Matrix4f(),
        prevViewProj = new Matrix4f();
    public final Matrix4f[] shadowViewProj = {new Matrix4f(), new Matrix4f()};
    public double cameraX, cameraY, cameraZ;
    public final Vector3f sunDir = new Vector3f(0, 1, 0), moonDir = new Vector3f(0, -1, 0);
    private final Vector3f scratchSunView = new Vector3f();
    public float moonPhase = 1f;
    public final ShadeSky.Result sky = new ShadeSky.Result();
    public float sunIntensity = ShadeSky.SUN_INTENSITY, moonIntensity, mie = 1f;
    public final float[] blockLight = {2.4f, 1.2f, 0.48f};
    public float minAmbient = 0.004f;
    public float naturalLighting;
    public final float[] fogColor = new float[4];
    public float fogEnvStart, fogEnvEnd = 1e6f, fogRenderStart, fogRenderEnd = 1e6f, fogSkyEnd = 1e6f, fogCloudEnd = 1e6f, hazeDensity = 0.0008f, hazeStrength = 0.45f;
    /** fogColor's rgb through the display transform's inverse (ShadeLook.ldrToHdr), once per frame: shaders blend toward it. */
    public final float[] fogColorHdr = new float[3];
    public float rain, thunder, nightVision, starBrightness;
    public float sunsetAway = 1f;
    public float cascadeSplit0 = 32, cascadeSplit1 = 128, cascadeTexel0 = 1f / 32f, cascadeTexel1 = 1f / 8f;
    public int shadowResolution = 2048;
    public float shadowDepthBias = 0.00015f, shadowSoftness = 1f;
    public boolean shadowsEnabled;
    public int cascades = 2;
    public int width = 1, height = 1;
    public float dayTime, gameTimeSeconds, exposure = 1f, partialTick;
    public float waterTime, waterSurfaceAbove, waterSurfaceBelow;
    /** The grass block side overlay's atlas rect (u0, v0, du, dv; all 0 when unknown): a cutout quad on a solid block, not foliage. */
    public final float[] solidCutoutRect = new float[4];
    public float skyTime;
    public float jitterX, jitterY, prevJitterX, prevJitterY;
    public float mipScale = 1f;
    public float renderScale = 1f;
    public int dimension = DIM_OVERWORLD, fogType = FOG_AIR, debug;
    public int frameIndex;
    public boolean underwater;
    public int eyeSkyLight = 15;

    public void updateAtmosphere(float dtSeconds, boolean snap) {
        ShadeSky.sunsetAway = this.sunsetAway = 1f;
        ShadeSky.Sky s = new ShadeSky.Sky(this.sunDir.x, this.sunDir.y, this.sunDir.z, this.moonDir.x, this.moonDir.y, this.moonDir.z,
            this.moonPhase, this.rain, this.thunder);
        ShadeSky.compute(s, this.sky);
        this.sunIntensity = s.sunIntensity();
        this.moonIntensity = s.moonIntensity();
        this.mie = s.mie();
        this.hazeDensity = 0.0008f * (1f + 8f * this.rain);
        this.hazeStrength = Math.min(0.5f + 0.4f * this.rain, 1f);
        float eye = this.eyeSkyLight / 15f;
        float eyeCurve = eye / (4f - 3f * eye);
        float scene = this.sky.sceneLuma * eyeCurve + 0.05f * (1f - eyeCurve) + this.minAmbient;
        if (this.naturalLighting > 0f) {
            float extra = Math.max(this.naturalLighting - 1f, 0f);
            float floor = this.sky.sceneLuma * (0.125f * (1f + extra)) + this.minAmbient;
            scene += Math.min(this.naturalLighting, 1f) * (Math.max(scene, floor) - scene);
        }
        float target = ShadeSky.KEY / (float) Math.pow(Math.max(scene, 1e-4f), ShadeSky.ADAPTATION);
        target *= 1f + 1.5f * this.nightVision;
        target *= 1f - 0.3f * this.rain * eyeCurve;
        target *= 1f + (s.exposureBias() - 1f) * eyeCurve;
        target = Math.min(Math.max(target, ShadeSky.EXPOSURE_MIN), ShadeSky.EXPOSURE_MAX * (1f + this.nightVision));
        if (snap || !(this.exposure > 0f)) {
            this.exposure = target;
        } else {
            float k = 1f - (float) Math.exp(-Math.max(dtSeconds, 0f) / ShadeSky.ADAPT_SECONDS);
            this.exposure = (float) Math.exp(Math.log(this.exposure) + (Math.log(target) - Math.log(this.exposure)) * k);
        }
    }

    public static void output(float[] radiance, float exposure, float[] out) {
        float r = Math.max(radiance[0], 0f) * exposure, g = Math.max(radiance[1], 0f) * exposure, b = Math.max(radiance[2], 0f) * exposure;
        float m = Math.max(Math.max(r, g), Math.max(b, 1e-6f));
        float tm = curve(m);
        float w = ShadeSky.smoothstep(0.6f, 1f, tm) * 0.6f;
        float[] c = {r, g, b};
        for (int k = 0; k < 3; k++) {
            float v = c[k] * tm / m;
            v = v + (curve(c[k]) - v) * w;
            v = Math.min(Math.max(v, 0f), 1f);
            out[k] = v <= 0.0031308f ? v * 12.92f : 1.055f * (float) Math.pow(v, 1 / 2.4) - 0.055f;
        }
    }

    private static float curve(float x) {
        float y = 1f - (float) Math.exp(-1.1f * Math.max(x, 0f));
        return y * y * 1.006f / (y + 0.006f);
    }

    public void pack(ByteBuffer out) {
        ByteBuffer b = out.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        putMat(this.view, b, VIEW);
        putMat(this.proj, b, PROJ);
        putMat(this.viewProj, b, VIEW_PROJ);
        putMat(this.invViewProj, b, INV_VIEW_PROJ);
        putMat(this.prevViewProj, b, PREV_VIEW_PROJ);
        putMat(this.shadowViewProj[0], b, SHADOW_VIEW_PROJ);
        putMat(this.shadowViewProj[1], b, SHADOW_VIEW_PROJ + 64);
        double bx = Math.floor(this.cameraX), by = Math.floor(this.cameraY), bz = Math.floor(this.cameraZ);
        put4(b, CAMERA_BLOCK, (float) bx, (float) by, (float) bz, this.mipScale);
        put4(b, CAMERA_FRACT, (float) (this.cameraX - bx), (float) (this.cameraY - by), (float) (this.cameraZ - bz), (float) (this.cameraY - 63));
        put4(b, SUN_DIR_WORLD, this.sunDir.x, this.sunDir.y, this.sunDir.z, this.sunDir.y);
        Vector3f sv = this.view.transformDirection(this.scratchSunView.set(this.sunDir));
        put4(b, SUN_DIR_VIEW, sv.x, sv.y, sv.z, 0);
        put4(b, MOON_DIR_WORLD, this.moonDir.x, this.moonDir.y, this.moonDir.z, this.moonPhase);
        float[] l = this.sky.lightDir;
        put4(b, LIGHT_DIR_WORLD, l[0], l[1], l[2], this.sky.sunLight ? 1 : 0);
        float[] c = this.sky.light;
        put4(b, SUN_COLOR, c[0], c[1], c[2], ShadeSky.luma(c[0], c[1], c[2]));
        put3(b, AMBIENT_SKY, this.sky.ambientSky, 0);
        put3(b, AMBIENT_GROUND, this.sky.ambientGround, 0);
        put3(b, AMBIENT_BLOCK, this.blockLight, this.minAmbient);
        put4(b, FOG_COLOR, this.fogColor[0], this.fogColor[1], this.fogColor[2], this.fogColor[3]);
        put4(b, FOG_RANGE, this.fogEnvStart, this.fogEnvEnd, this.fogRenderStart, this.fogRenderEnd);
        put4(b, FOG_SKY, this.fogSkyEnd, this.fogCloudEnd, this.hazeDensity, this.hazeStrength);
        put4(b, FOG_COLOR_HDR, this.fogColorHdr[0], this.fogColorHdr[1], this.fogColorHdr[2], 1 - this.rain);
        put3(b, ZENITH_COLOR, this.sky.zenith, this.sunsetAway);
        for (int i = 0; i < 8; i++) put3(b, HORIZON + 16 * i, this.sky.horizon[i], 0);
        put4(b, CASCADE_SPLITS, this.cascadeSplit0, this.cascadeSplit1, this.cascadeTexel0, this.cascadeTexel1);
        put4(b, SHADOW_PARAMS, 1f / this.shadowResolution, this.shadowResolution, this.shadowDepthBias, this.shadowSoftness);
        put4(b, SCREEN, this.width, this.height, 1f / this.width, 1f / this.height);
        put4(b, TIME, this.dayTime, this.gameTimeSeconds, this.exposure, this.partialTick);
        put4(b, WEATHER, this.rain, this.thunder, this.nightVision, this.starBrightness);
        put4(b, JITTER, this.jitterX, this.jitterY, this.prevJitterX, this.prevJitterY);
        put4(b, ATMOSPHERE, this.sunIntensity, this.moonIntensity, this.mie, ShadeSky.SKY_BRIGHTNESS);
        put3(b, AMBIENT_TOWARD, this.sky.ambientToward, 0);
        put3(b, AMBIENT_AWAY, this.sky.ambientAway, 0);
        b.putInt(FLAGS, this.dimension).putInt(FLAGS + 4, this.fogType).putInt(FLAGS + 8, this.shadowsEnabled ? 1 : 0).putInt(FLAGS + 12, this.debug);
        b.putInt(FLAGS2, this.frameIndex).putInt(FLAGS2 + 4, this.underwater ? 1 : 0).putInt(FLAGS2 + 8, this.cascades).putInt(FLAGS2 + 12, this.eyeSkyLight);
        put4(b, SUN_PATH, (float) Math.sin(Math.toRadians(ShadeSky.SUN_TILT)), (float) Math.cos(Math.toRadians(ShadeSky.SUN_TILT)), devBits(), this.waterTime);
        put4(b, WX_LINE, this.waterSurfaceBelow, this.solidCutoutRect[0], this.solidCutoutRect[1],
            Float.intBitsToFloat((Float.floatToFloat16(this.solidCutoutRect[2]) & 0xffff)
                | ((Float.floatToFloat16(this.solidCutoutRect[3]) & 0xffff) << 16)));
    }

    public void setShadow(boolean enabled, int cascades, Matrix4fc cascade0, Matrix4fc cascade1, float split0, float split1, int resolution,
                          float depthBias, float softness) {
        this.shadowsEnabled = enabled;
        this.cascades = cascades;
        this.shadowViewProj[0].set(cascade0);
        this.shadowViewProj[1].set(cascade1);
        this.cascadeSplit0 = split0;
        this.cascadeSplit1 = split1;
        this.shadowResolution = resolution;
        this.shadowDepthBias = depthBias;
        this.shadowSoftness = softness;
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

    private static void put3(ByteBuffer b, int at, float[] v, float w) {
        put4(b, at, v[0], v[1], v[2], w);
    }
}
