// Celestia Metal Shader Pack API v1 — Common MSL Prelude
// Designed specifically for Apple Silicon TBDR GPUs (M1 / M2 / M3 / M4+):
// - half-precision color/sky/fog paths where perceptually lossless
// - reversed-Z depth linearization (near = 1.0, far = 0.0)
// - dir.y = v^2 sky LUT mapping (no asin() in fragment/compute hot loops, inspired by GaelQuinta/minecraft-metal-shaders)
// - sky-light early-out before shadow cascade lookups (zero shadow cost underground)
// - 2-cascade hardware 2x2 PCF shadows + ACES / AgX / Celestia Filmic HDR tonemapping

#ifndef CELESTIA_COMMON_METAL
#define CELESTIA_COMMON_METAL

#include <metal_stdlib>
using namespace metal;

struct CelestiaFrameUniforms {
    float4x4 viewProj;
    float4x4 invViewProj;
    float4x4 prevViewProj;
    float4x4 shadowViewProjNear;
    float4x4 shadowViewProjFar;
    float4 cameraPosTime;      // xyz camera world pos, w time seconds
    float4 sunDirDaylight;     // xyz towards sun/moon, w daylight 0..1
    float4 weatherState;       // x twilight, y rain, z thunder, w fogMode (0 air, 1 water, 2 lava, 3 snow)
    float4 skyColorFrame;      // rgb vanilla sky, w frameIndex
    float4 fogColorElevation;  // rgb vanilla fog, w sunElevation -1..1
    float4 fogRanges;          // x envStart, y envEnd, z rdStart, w rdEnd
    float4 resolutionParams;   // xy width/height, z hdrPeakNits, w edrHeadroom
    float4 qualityFlags;       // x dynLightPower, y gamma, z nightVision, w underwater
};

struct CelestiaFullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex CelestiaFullscreenOut celestia_fullscreen_vs(uint vid [[vertex_id]]) {
    CelestiaFullscreenOut out;
    float2 pos = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? 3.0f : -1.0f);
    out.position = float4(pos, 0.0f, 1.0f);
    out.uv = float2((pos.x + 1.0f) * 0.5f, 1.0f - (pos.y + 1.0f) * 0.5f);
    return out;
}

// Reconstruct camera-relative world position from UV [0..1] and reversed-Z depth [1..0].
inline float3 celestia_reconstruct_world(float2 uv, float depth, constant CelestiaFrameUniforms& u) {
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 clip = float4(ndc, depth, 1.0f);
    float4 world = u.invViewProj * clip;
    return world.xyz / max(abs(world.w), 1e-6f);
}

inline bool celestia_is_sky(float depth) {
    return depth <= 1e-5f;
}

// Encode/decode unit normal using fast octahedral mapping (2 channels in RG16F / RGBA8).
inline half2 celestia_encode_octahedral(half3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z) + 1e-5h);
    if (n.z < 0.0h) {
        half2 wrapped = (1.0h - abs(n.yx)) * select(half2(-1.0h), half2(1.0h), n.xy >= 0.0h);
        n.xy = wrapped;
    }
    return n.xy * 0.5h + 0.5h;
}

inline half3 celestia_decode_octahedral(half2 enc) {
    half2 f = enc * 2.0h - 1.0h;
    half3 n = half3(f.x, f.y, 1.0h - abs(f.x) - abs(f.y));
    half t = saturate(-n.z);
    n.xy += select(half2(t), half2(-t), n.xy >= 0.0h);
    return normalize(n);
}

// Sky LUT parameterization using dir.y = v^2 to concentrate horizon detail without asin().
inline float2 celestia_dir_to_skylut_uv(float3 dir, float3 sunDir) {
    float3 d = normalize(dir);
    float v = sqrt(saturate(max(d.y, 0.0f)));
    float2 horizD = normalize(float2(d.x, d.z) + float2(1e-5f, 0.0f));
    float2 horizS = normalize(float2(sunDir.x, sunDir.z) + float2(1e-5f, 0.0f));
    float cosAz = clamp(dot(horizD, horizS), -1.0f, 1.0f);
    float u = 0.5f + 0.5f * cosAz;
    return float2(u, v);
}

inline half3 celestia_sample_sky_lut(texture2d<half> lut, sampler samp, float3 dir, float3 sunDir) {
    return lut.sample(samp, celestia_dir_to_skylut_uv(dir, sunDir)).rgb;
}

// 2-cascade reversed-Z shadow lookup with hardware 2x2 PCF comparison sampler.
inline half celestia_sample_shadow_pcf(
    float3 worldPos,
    half skyLight,
    depth2d_array<float> shadowMap,
    sampler shadowSamp,
    constant CelestiaFrameUniforms& u
) {
    // Underground / deep cave early-out: zero shadow bandwidth spent when skyLight is zero.
    if (skyLight < 0.02h) {
        return 0.0h;
    }
    float4 nearClip = u.shadowViewProjNear * float4(worldPos, 1.0f);
    float3 nearUvd = float3(nearClip.x * 0.5f + 0.5f, 0.5f - nearClip.y * 0.5f, nearClip.z);
    if (all(nearUvd.xy > float2(0.01f)) && all(nearUvd.xy < float2(0.99f)) && nearUvd.z > 0.0f && nearUvd.z < 1.0f) {
        return (half)shadowMap.sample_compare(shadowSamp, nearUvd.xy, 0, nearUvd.z + 0.0005f);
    }
    float4 farClip = u.shadowViewProjFar * float4(worldPos, 1.0f);
    float3 farUvd = float3(farClip.x * 0.5f + 0.5f, 0.5f - farClip.y * 0.5f, farClip.z);
    if (all(farUvd.xy > float2(0.01f)) && all(farUvd.xy < float2(0.99f)) && farUvd.z > 0.0f && farUvd.z < 1.0f) {
        return (half)shadowMap.sample_compare(shadowSamp, farUvd.xy, 1, farUvd.z + 0.0012f);
    }
    return 1.0h;
}

inline half celestia_luminance(half3 c) {
    return dot(c, half3(0.2126h, 0.7152h, 0.0722h));
}

// ACES Filmic approximation in half3
inline half3 celestia_tonemap_aces(half3 x) {
    const half a = 2.51h;
    const half b = 0.03h;
    const half c = 2.43h;
    const half d = 0.59h;
    const half e = 0.14h;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// AgX-inspired soft highlight roll-off (preserves bright sky & sunset pastels without hue skew)
inline half3 celestia_tonemap_agx(half3 x) {
    half3 l = log2(max(x, half3(1e-5h)) + 1.0h);
    half3 s = l / (1.0h + l * 0.78h);
    return saturate(pow(s, half3(1.12h)));
}

// Celestia Filmic: crisp twilight warmth & luminous highlight preservation
inline half3 celestia_tonemap_filmic(half3 x) {
    half3 peak = x / (1.0h + x * 0.85h);
    return saturate(mix(peak, celestia_tonemap_aces(x), 0.35h));
}

inline half3 celestia_linear_to_srgb(half3 c) {
    half3 lo = c * 12.92h;
    half3 hi = 1.055h * pow(max(c, half3(0.0h)), half3(1.0h / 2.4h)) - 0.055h;
    return select(hi, lo, c <= 0.0031308h);
}

inline float celestia_hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

#endif // CELESTIA_COMMON_METAL
