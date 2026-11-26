// SPDX-License-Identifier: Apache-2.0

struct AoIn { float4 position [[position]]; float2 uv; };
constexpr sampler aoLinear(filter::linear, address::clamp_to_edge);

static float3 aoPoint(uint2 pixel, float z, float2 size, constant ShadeFrame &f) {
    float2 ndc = (float2(pixel) + 0.5) * (2.0 / size) - 1.0;
    float4 p = f.invViewProj * float4(ndc, z, 1.0);
    return p.xyz / p.w;
}

static float3 aoCloserNeighbor(depth2d<float> depth, int2 pixel, int2 axis, float center,
                               float3 p, float2 size, constant ShadeFrame &f) {
    int2 limit = int2(size) - 1;
    uint2 before = uint2(clamp(pixel - axis, int2(0), limit));
    uint2 after = uint2(clamp(pixel + axis, int2(0), limit));
    float d0 = depth.read(before), d1 = depth.read(after);
    if (d0 > 0.0 && (d1 <= 0.0 || abs(d0 - center) < abs(d1 - center))) {
        return p - aoPoint(before, d0, size, f);
    }
    if (d1 > 0.0) return aoPoint(after, d1, size, f) - p;
    return 0.0;
}

fragment half4 shade_ambient_occlusion(AoIn in [[stage_in]],
                                       constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                       depth2d<float> depth [[texture(0)]]) {
    uint2 dim = uint2(depth.get_width(), depth.get_height());
    float2 size = float2(dim);
    uint2 pixel = min(uint2(in.uv * size), dim - 1u);
    float z = depth.read(pixel);
    if (z <= 0.0) return half4(1.0h, 0.0h, 0.0h, 1.0h);
    float3 p = aoPoint(pixel, z, size, f);
    float distance = length(p);
    if (distance >= 96.0) return half4(1.0h, half(min(distance, 60000.0)), 0.0h, 1.0h);
    float3 horizontal = aoCloserNeighbor(depth, int2(pixel), int2(1, 0), z, p, size, f);
    float3 vertical = aoCloserNeighbor(depth, int2(pixel), int2(0, 1), z, p, size, f);
    float3 normal = cross(horizontal, vertical);
    normal *= rsqrt(max(dot(normal, normal), 1e-12));
    if (dot(normal, p) > 0.0) normal = -normal;

    const float radius = 1.35;
    float pixels = clamp(0.5 * size.y * abs(f.proj[1][1]) * radius / max(distance, 0.5), 2.0, 28.0);
    constexpr float2 offsets[8] = {
        float2(0.42, 0.12), float2(-0.12, 0.42), float2(-0.42, -0.12), float2(0.12, -0.42),
        float2(0.78, 0.52), float2(-0.52, 0.78), float2(-0.78, -0.52), float2(0.52, -0.78)
    };
    float occlusion = 0.0;
    for (int i = 0; i < 8; i++) {
        uint2 tap = uint2(clamp(int2(pixel) + int2(round(offsets[i] * pixels)), int2(0), int2(dim) - 1));
        float qz = depth.read(tap);
        if (qz <= 0.0) continue;
        float3 delta = aoPoint(tap, qz, size, f) - p;
        float len = length(delta);
        occlusion += max(dot(normal, delta) / max(len, 0.015) - 0.12, 0.0) * saturate(1.0 - len / radius);
    }
    float visible = 1.0 - occlusion * 0.1 * (1.0 - smoothstep(64.0, 96.0, distance));
    return half4(half(visible), half(distance), 0.0h, 1.0h);
}

static half shadeAoSample(texture2d<half> ao, float2 uv, float distance) {
    float2 sample = float2(ao.sample(aoLinear, uv).rg);
    float depthWeight = 1.0 - smoothstep(0.15, max(0.4, distance * 0.035), abs(sample.y - distance));
    return half(mix(1.0, sample.x, depthWeight));
}
