// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/dims/ShadeDims.java
// Daily aurora palette cycle and night curve adapted from Photon Shaders (commit 26c2906e, MIT, LICENSES/MIT-Photon.txt).
//
// Copyright 2026 mcopt-shade & Celestia Metal contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.atmosphere;

import dev.celestia.metal.shade.ShadeFrame;
import dev.celestia.metal.shade.ShadeSettings;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.Biome;

/**
 * Overworld aurora state, daily/preset linear colour palettes, ambient sky tint, and {@code AuroraPush} packing.
 */
public final class ShadeAurora {
    public static final int MODE_OFF = 0, MODE_COLD_BIOMES = 1, MODE_AUTO = 2, MODE_ALWAYS = 3;
    public static final int PALETTE_DAILY = 0, PALETTE_CLASSIC = 1, PALETTE_PASTEL = 2;

    static final float FREQ = 0.000032f;
    static final float STEPS = 40f;
    static final float RAYS = 0.55f;

    // Linear RGB bottom -> top aurora curtain palettes (curated from Photon commit 26c2906e).
    private static final float[][] DAILY_BOTTOM = {
        {0.04f, 1.00f, 0.30f}, // emerald green
        {0.05f, 1.00f, 0.36f}, // emerald green
        {0.08f, 0.96f, 0.52f}, // jade green
        {0.18f, 0.92f, 0.78f}, // aqua mint
        {0.58f, 0.64f, 1.00f}, // lavender periwinkle
        {0.78f, 0.36f, 1.00f}, // violet magenta
        {0.96f, 0.52f, 0.88f}, // rose pink
        {0.06f, 0.98f, 0.34f}, // green -> violet
        {0.95f, 0.24f, 0.28f}, // crimson
        {1.00f, 0.62f, 0.24f}, // golden peach
    };
    private static final float[][] DAILY_TOP = {
        {0.28f, 0.56f, 1.00f}, // sky blue
        {0.46f, 0.36f, 1.00f}, // soft violet
        {0.34f, 0.64f, 1.00f}, // arctic blue
        {0.62f, 0.38f, 1.00f}, // amethyst violet
        {0.88f, 0.44f, 0.96f}, // soft orchid
        {0.26f, 0.34f, 1.00f}, // deep blue
        {0.58f, 0.36f, 0.96f}, // plum violet
        {0.78f, 0.30f, 0.92f}, // purple
        {0.72f, 0.44f, 0.94f}, // rose lavender
        {0.96f, 0.38f, 0.62f}, // rose coral
    };
    private static final float[] CLASSIC_BOTTOM = {0.05f, 1.00f, 0.35f};
    private static final float[] CLASSIC_TOP = {0.48f, 0.35f, 1.00f};
    private static final float[] PASTEL_BOTTOM = {0.22f, 0.98f, 0.76f};
    private static final float[] PASTEL_TOP = {0.96f, 0.52f, 0.94f};

    private float cold;
    private float aurora;
    private float strength;
    private int sampleTick;
    private final float[] colorBottom = CLASSIC_BOTTOM.clone();
    private final float[] colorTop = CLASSIC_TOP.clone();

    public void reset() {
        cold = 0f;
        aurora = 0f;
        strength = 0f;
        sampleTick = 0;
    }

    public float strength() {
        return strength;
    }

    public void update(ClientLevel level, BlockPos camera, ShadeFrame frame, float dt, boolean snap, ShadeSettings.Sky skyOptions) {
        if (skyOptions == null || skyOptions.auroraMode() == MODE_OFF || skyOptions.auroraBrightness() <= 0f
            || level == null || frame.dimension != ShadeFrame.DIM_OVERWORLD
            || "false".equalsIgnoreCase(System.getProperty("celestiametal.shade.aurora", "true"))
            || Boolean.getBoolean("celestiametal.shade.aurora.pause")) {
            if (snap) {
                aurora = 0f;
            } else {
                float k = 1f - (float) Math.exp(-Math.max(dt, 0f) / 4f);
                aurora += (0f - aurora) * k;
            }
            strength = aurora * (skyOptions == null ? 0f : Math.max(0f, skyOptions.auroraBrightness()));
            return;
        }

        if ((sampleTick++ & 7) == 0 || snap) {
            if (camera != null) {
                Holder<Biome> h = level.getBiomeManager().getBiome(camera);
                float temp = h.value().getBaseTemperature();
                float target = temp < 0.15f ? 1f : temp < 0.30f ? 0.6f : 0f;
                cold = snap ? target : cold + (target - cold) * (1f - (float) Math.exp(-8f * Math.max(dt, 0f) / 6f));
            }
        }

        long day = noonDayIndex(level.getOverworldClockTime());
        int overrideDay = Integer.getInteger("celestiametal.shade.auroraDay", -1);
        long paletteDay = overrideDay >= 0 ? overrideDay : day;

        float want = computeWant(skyOptions.auroraMode(), cold, day, frame.sunDir.y, frame.rain);
        float k = snap ? 1f : 1f - (float) Math.exp(-Math.max(dt, 0f) / 4f);
        aurora += (want - aurora) * k;
        strength = aurora * Math.max(0f, skyOptions.auroraBrightness());

        selectPalette(skyOptions.auroraPalette(), paletteDay, colorBottom, colorTop);

        if (strength > 1e-3f) {
            float l = 0.2126f * frame.sky.ambientSky[0] + 0.7152f * frame.sky.ambientSky[1] + 0.0722f * frame.sky.ambientSky[2];
            float r = 0.65f * colorBottom[0] + 0.35f * colorTop[0];
            float g = 0.65f * colorBottom[1] + 0.35f * colorTop[1];
            float b = 0.65f * colorBottom[2] + 0.35f * colorTop[2];
            float ml = Math.max(0.2126f * r + 0.7152f * g + 0.0722f * b, 1e-5f);
            float gain = strength * Math.max(l, 1e-5f) * 0.45f / ml;
            frame.sky.ambientSky[0] += r * gain;
            frame.sky.ambientSky[1] += g * gain;
            frame.sky.ambientSky[2] += b * gain;
        }
    }

    /** Packs the 48-byte {@code AuroraPush} struct matching {@code aurora.metal}. */
    public void packPush(MemorySegment dst, int frameIndex) {
        dst.set(ValueLayout.JAVA_FLOAT, 0, colorBottom[0]);
        dst.set(ValueLayout.JAVA_FLOAT, 4, colorBottom[1]);
        dst.set(ValueLayout.JAVA_FLOAT, 8, colorBottom[2]);
        dst.set(ValueLayout.JAVA_FLOAT, 12, strength);
        dst.set(ValueLayout.JAVA_FLOAT, 16, colorTop[0]);
        dst.set(ValueLayout.JAVA_FLOAT, 20, colorTop[1]);
        dst.set(ValueLayout.JAVA_FLOAT, 24, colorTop[2]);
        dst.set(ValueLayout.JAVA_FLOAT, 28, FREQ);
        dst.set(ValueLayout.JAVA_FLOAT, 32, STEPS);
        dst.set(ValueLayout.JAVA_FLOAT, 36, RAYS);
        dst.set(ValueLayout.JAVA_FLOAT, 40, 0f);
        dst.set(ValueLayout.JAVA_FLOAT, 44, frameIndex & 0xffff);
    }

    /** Noon-to-noon day index so aurora visibility and palette never flip at midnight. */
    public static long noonDayIndex(long overworldClockTime) {
        return Math.floorDiv(overworldClockTime - 6000L, 24000L);
    }

    public static float nightFactor(float sunY) {
        return 1f - smooth(-0.22f, -0.04f, sunY);
    }

    public static float computeWant(int mode, float cold, long day, float sunY, float rain) {
        boolean chanceDay = Integer.remainderUnsigned(ShadeWeather.lowbias32((int) day), 100) < 35;
        float base = switch (mode) {
            case MODE_OFF -> 0f;
            case MODE_COLD_BIOMES -> cold;
            case MODE_ALWAYS -> 1f;
            default -> Math.max(cold, chanceDay ? 0.65f : 0f);
        };
        return base * nightFactor(sunY) * Math.max(0f, 1f - rain);
    }

    public static void selectPalette(int palette, long day, float[] outBottom, float[] outTop) {
        float[] srcB;
        float[] srcT;
        if (palette == PALETTE_CLASSIC) {
            srcB = CLASSIC_BOTTOM;
            srcT = CLASSIC_TOP;
        } else if (palette == PALETTE_PASTEL) {
            srcB = PASTEL_BOTTOM;
            srcT = PASTEL_TOP;
        } else {
            int idx = Integer.remainderUnsigned(ShadeWeather.lowbias32((int) day), DAILY_BOTTOM.length);
            srcB = DAILY_BOTTOM[idx];
            srcT = DAILY_TOP[idx];
        }
        System.arraycopy(srcB, 0, outBottom, 0, 3);
        System.arraycopy(srcT, 0, outTop, 0, 3);
    }

    private static float smooth(float e0, float e1, float x) {
        float t = Math.min(Math.max((x - e0) / (e1 - e0), 0f), 1f);
        return t * t * (3f - 2f * t);
    }
}
