// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/taa.metal
//
// Copyright 2026 mcopt-shade contributors
// Licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
//
// Halton jitter, camera-relative reprojection, depth rejection and neighborhood clipping.
// The history is display-referred RGB and view depth. A negative depth marks first-person overlays.

#include <metal_stdlib>
using namespace metal;

struct TaaIn {
    float4 position [[position]];
    float2 uv;
};

struct TaaParams {
    float4x4 inverseCurrent;
    float4x4 previousFromCurrent;
    float4x4 previousViewProj;
    float4 jitterAndHistory; // input UV jitter and valid history
};

static_assert(sizeof(TaaParams) == 208, "TaaParams layout");
constexpr sampler taaLinear(filter::linear, address::clamp_to_edge);
constexpr sampler taaNearest(filter::nearest, address::clamp_to_edge);

vertex TaaIn taa_vs(uint id [[vertex_id]]) {
    float2 p = float2(id == 1 ? 3.0 : -1.0, id == 2 ? 3.0 : -1.0);
    return {float4(p, 0.0, 1.0), float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5)};
}

fragment half4 taa_resolve(TaaIn in [[stage_in]], constant TaaParams &p [[buffer(0)]],
                           texture2d<half> scene [[texture(0)]], depth2d<float> depth [[texture(1)]],
                           texture2d<half> history [[texture(2)]], depth2d<float> hand [[texture(3)]]) {
    float2 size = float2(scene.get_width(), scene.get_height());
    uint2 sourceLimit = uint2(size) - 1u;
    uint2 handPx = min(uint2(in.uv * size), sourceLimit);
    if (hand.read(handPx) > 0.0) return half4(scene.sample(taaLinear, in.uv).rgb, -1.0h);

    float2 uv = clamp(in.uv + p.jitterAndHistory.xy, 0.5 / size, 1.0 - 0.5 / size);
    uint2 px = min(uint2(uv * size), sourceLimit);
    float z = depth.read(px);
    float2 pixelUv = (float2(px) + 0.5) / size;
    float4 world = p.inverseCurrent * float4(pixelUv * 2.0 - 1.0, z, 1.0);
    float distance = z > 0.0 ? min(1.0 / max(world.w, 1e-6), 60000.0) : 0.0;
    half3 current = scene.sample(taaLinear, uv).rgb;
    if (p.jitterAndHistory.z < 0.5) return half4(current, half(distance));

    float4 last = z > 0.0 ? p.previousFromCurrent * world : p.previousViewProj * float4(world.xyz, 0.0);
    if (last.w <= 1e-6) return half4(current, half(distance));
    // Add the offset from the selected depth texel center back after reprojection.
    float2 lastUv = last.xy / last.w * 0.5 + 0.5 + (uv - pixelUv);
    if (any(lastUv < 0.0) || any(lastUv > 1.0)) return half4(current, half(distance));
    float historyDepth = float(history.sample(taaNearest, lastUv).a);
    float expected = z > 0.0 ? last.w / world.w : 0.0;
    if (historyDepth < 0.0 || (z > 0.0) != (historyDepth > 0.0)
        || abs(historyDepth - expected) > max(0.15, 0.035 * expected)) return half4(current, half(distance));

    float2 step = 1.0 / size;
    half3 a = scene.sample(taaLinear, uv - float2(step.x, 0.0)).rgb;
    half3 b = scene.sample(taaLinear, uv + float2(step.x, 0.0)).rgb;
    half3 c = scene.sample(taaLinear, uv - float2(0.0, step.y)).rgb;
    half3 d = scene.sample(taaLinear, uv + float2(0.0, step.y)).rgb;
    half3 lo = min(current, min(min(a, b), min(c, d)));
    half3 hi = max(current, max(max(a, b), max(c, d)));
    half3 past = history.sample(taaLinear, lastUv).rgb;
    half3 clipped = clamp(past, lo, hi);
    half difference = max(max(abs(past.r - clipped.r), abs(past.g - clipped.g)), abs(past.b - clipped.b));
    float speed = length((lastUv - in.uv) * size);
    half response = half(max(0.12 + 0.20 * saturate(speed * 0.125), saturate(float(difference) * 3.5)));
    return half4(mix(clipped, current, response), half(distance));
}

fragment half4 taa_output(TaaIn in [[stage_in]], texture2d<half> history [[texture(0)]]) {
    int2 p = int2(in.position.xy);
    int2 limit = int2(history.get_width(), history.get_height()) - 1;
    half4 center = history.read(uint2(p));
    if (center.a < 0.0h) return half4(center.rgb, 1.0h);
    half3 a = history.read(uint2(max(p - int2(1, 0), 0))).rgb;
    half3 b = history.read(uint2(min(p + int2(1, 0), limit))).rgb;
    half3 c = history.read(uint2(max(p - int2(0, 1), 0))).rgb;
    half3 d = history.read(uint2(min(p + int2(0, 1), limit))).rgb;
    half3 lo = min(center.rgb, min(min(a, b), min(c, d)));
    half3 hi = max(center.rgb, max(max(a, b), max(c, d)));
    half3 sharpened = center.rgb + 0.22h * (center.rgb - 0.25h * (a + b + c + d));
    return half4(clamp(sharpened, lo, hi), 1.0h);
}

// MetalFX Temporal's camera motion (TemporalUpscaler, METALFX_TEMPORAL): per input pixel, where the surface it shows was
// last frame, as previous - current in un-jittered UV (+y down). First-person overlays move with the camera: zero.
struct TaaMotionParams {
    float4x4 inverseCurrent;      // jittered: reconstructs the depth texel's camera-relative position
    float4x4 currentViewProj;     // un-jittered
    float4x4 previousFromCurrent; // last frame's un-jittered view-projection, moved by the camera's step
    float4x4 previousViewProj;    // the same without the step (directions: the sky)
};

static_assert(sizeof(TaaMotionParams) == 256, "TaaMotionParams layout");

fragment half2 taa_motion(TaaIn in [[stage_in]], constant TaaMotionParams &p [[buffer(0)]],
                          depth2d<float> depth [[texture(0)]], depth2d<float> hand [[texture(1)]]) {
    uint2 px = uint2(in.position.xy);
    if (hand.read(px) > 0.0) return half2(0.0h);
    float2 size = float2(depth.get_width(), depth.get_height());
    float2 uv = (float2(px) + 0.5) / size;
    float z = depth.read(px);
    // (TAA's convention: the matrices are GL's, flipped after projection, so UV = NDC * 0.5 + 0.5 with no y flip)
    float4 world = p.inverseCurrent * float4(uv * 2.0 - 1.0, z, 1.0);
    float4 cur = z > 0.0 ? p.currentViewProj * world : p.currentViewProj * float4(world.xyz, 0.0);
    float4 last = z > 0.0 ? p.previousFromCurrent * world : p.previousViewProj * float4(world.xyz, 0.0);
    if (cur.w <= 1e-6 || last.w <= 1e-6) return half2(0.0h);
    float2 curUv = cur.xy / cur.w * 0.5 + 0.5;
    float2 lastUv = last.xy / last.w * 0.5 + 0.5;
    return half2(lastUv - curUv);
}
