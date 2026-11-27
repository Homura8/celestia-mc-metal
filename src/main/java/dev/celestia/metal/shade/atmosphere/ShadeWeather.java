package dev.celestia.metal.shade.atmosphere;

/**
 * Daily cloud weather (alpha.25), after Photon Shaders' include/misc/weather.glsl and its WEATHER_D* settings at commit 26c2906e
 * (MIT, LICENSES/MIT-Photon.txt): each Minecraft day hashes to one of twelve skies, which blend into the next around dawn, and
 * rain pushes every layer toward overcast. Computed once per frame on the CPU (free for the GPU) and passed to clouds.metal in
 * ShadeLook's weatherA / weatherB.
 */
public final class ShadeWeather {
    // cumulus min, max, altocumulus min, max, cirrus, cirrocumulus, cumulus congestus amount, stratus amount (Photon's D0..D11)
    static final float[][] DAYS = {
        {0.40f, 0.60f, 0.20f, 0.50f, 0.00f, 0.53f, 0.00f, 0.00f},
        {0.40f, 0.50f, 0.25f, 0.40f, 0.30f, 0.57f, 0.00f, 0.00f},
        {0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 1.00f, 0.00f},
        {0.45f, 0.60f, 0.80f, 1.00f, 0.80f, 0.00f, 0.00f, 0.00f},
        {0.00f, 0.00f, 0.10f, 0.55f, 0.10f, 0.49f, 1.00f, 0.00f},
        {0.00f, 0.00f, 0.30f, 0.50f, 0.40f, 0.60f, 0.00f, 0.00f},
        {0.00f, 0.00f, 0.00f, 0.00f, 0.33f, 0.33f, 0.00f, 0.00f},
        {0.40f, 0.55f, 0.00f, 0.00f, 0.50f, 0.00f, 0.00f, 1.00f},
        {0.44f, 0.55f, 0.25f, 0.40f, 0.10f, 0.63f, 0.00f, 0.00f},
        {0.44f, 0.55f, 0.20f, 0.45f, 0.40f, 0.00f, 0.00f, 0.70f},
        {0.35f, 0.45f, 0.20f, 0.30f, 0.23f, 0.50f, 0.00f, 0.00f},
        {0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f, 0.00f},
    };
    /** Fallback cumulus coverage when the dedicated cumulus congestus toggle is disabled. */
    static final float[] CONGESTUS_FALLBACK_CUMULUS = {0.40f, 0.55f};

    private ShadeWeather() {}

    static int lowbias32(int x) {
        x ^= x >>> 16;
        x *= 0x7feb352d;
        x ^= x >>> 15;
        x *= 0x846ca68b;
        x ^= x >>> 16;
        return x;
    }

    static int dayIndex(long worldDay, long timeOfDay) {
        long d = worldDay - (timeOfDay <= 6000 ? 1 : 0); // a day's weather runs noon to noon
        return Integer.remainderUnsigned(lowbias32((int) d), DAYS.length);
    }

    /**
     * out[0..7] = cumulus min, max, altocumulus min, max, cirrus, cirrocumulus, congestus, stratus.
     *
     * @param dayTime  the level's day time (ticks, unbounded)
     * @param rain     rain strength 0..1 (Photon's wetness)
     * @param coverage the Cloud Coverage option (scales every layer)
     * @param fixedDay -1 for the daily cycle, else always that sky (0..11)
     */
    public static void compute(long dayTime, float rain, float coverage, int fixedDay, float[] out) {
        compute(dayTime, rain, coverage, fixedDay, true, out);
    }

    /**
     * out[0..7] = cumulus min, max, altocumulus min, max, cirrus, cirrocumulus, congestus, stratus.
     *
     * @param dayTime           the level's day time (ticks, unbounded)
     * @param rain              rain strength 0..1 (Photon's wetness)
     * @param coverage          the Cloud Coverage option (scales every layer)
     * @param fixedDay          -1 for the daily cycle, else always that sky (0..11)
     * @param congestusEnabled  whether days 2 and 4 use the distant cumulus congestus layer instead of fallback cumulus
     */
    public static void compute(long dayTime, float rain, float coverage, int fixedDay, boolean congestusEnabled, float[] out) {
        long day = Math.floorDiv(dayTime, 24000L), t = Math.floorMod(dayTime, 24000L);
        float[] a, b;
        float m;
        if (fixedDay >= 0 && fixedDay < DAYS.length) {
            a = b = DAYS[fixedDay];
            m = 0f;
        } else {
            a = DAYS[dayIndex(day, t)];
            b = DAYS[dayIndex(day + 1, t)];
            float x = (float) (t / 24000.0 - 0.25);
            x -= (float) Math.floor(x);
            m = x * x * (3f - 2f * x);
        }
        for (int i = 0; i < 8; i++) out[i] = a[i] + (b[i] - a[i]) * m;
        if (!congestusEnabled && out[6] > 0f) {
            float con = out[6];
            out[0] += (CONGESTUS_FALLBACK_CUMULUS[0] - out[0]) * con;
            out[1] += (CONGESTUS_FALLBACK_CUMULUS[1] - out[1]) * con;
            out[6] = 0f;
        }
        // weather influence (Photon's clouds_weather_variation)
        out[0] += (0.6f - out[0]) * rain;
        out[1] += (0.8f - out[1]) * rain;
        out[2] += (0.4f - out[2]) * rain * 0.75f;
        out[3] += (0.9f - out[3]) * rain * 0.75f;
        out[4] += (0.7f - out[4]) * rain * 0.5f;
        out[6] *= 1f - rain;
        out[7] = Math.min(1f, out[7] + 0.7f * rain);
        for (int i = 0; i < 6; i++) out[i] *= coverage;
    }
}
