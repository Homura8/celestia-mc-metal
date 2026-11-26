// Reversed-Z 2-cascade shadow depth pass with cutout alpha testing.
struct ShadowVertexIn {
    float3 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

struct ShadowVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex ShadowVertexOut celestia_shadow_vs(
    ShadowVertexIn in [[stage_in]],
    constant CelestiaFrameUniforms& u [[buffer(14)]],
    constant int& cascadeIndex [[buffer(15)]]
) {
    ShadowVertexOut out;
    float4x4 vp = (cascadeIndex == 0) ? u.shadowViewProjNear : u.shadowViewProjFar;
    out.position = vp * float4(in.position, 1.0f);
    out.uv = in.uv;
    return out;
}

fragment void celestia_shadow_fs(
    ShadowVertexOut in [[stage_in]],
    texture2d<half> albedoTex [[texture(0)]],
    sampler albedoSamp [[sampler(0)]]
) {
    half a = albedoTex.sample(albedoSamp, in.uv).a;
    if (a < 0.45h) {
        discard_fragment();
    }
}
