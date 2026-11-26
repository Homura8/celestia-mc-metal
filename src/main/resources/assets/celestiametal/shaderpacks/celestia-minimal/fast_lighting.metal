fragment half4 celestia_min_lighting_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> gAlbedoTex [[texture(0)]],
    texture2d<half> gDataTex [[texture(1)]],
    texture2d<float> depthTex [[texture(2)]],
    texture2d<half> skyLutTex [[texture(3)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    float depth = depthTex.sample(linearSamp, in.uv).r;
    float3 worldPos = celestia_reconstruct_world(in.uv, depth, u);
    float3 viewDir = normalize(worldPos);
    float3 sunDir = normalize(u.sunDirDaylight.xyz);

    if (celestia_is_sky(depth)) {
        return half4(celestia_sample_sky_lut(skyLutTex, linearSamp, viewDir, sunDir), 1.0h);
    }

    half4 alb = gAlbedoTex.sample(linearSamp, in.uv);
    half4 gdata = gDataTex.sample(linearSamp, in.uv);
    half3 normal = celestia_decode_octahedral(gdata.rg);
    half blockLight = gdata.b;
    half skyLight = gdata.a;

    half ndotl = saturate(dot(normal, (half3)sunDir));
    half daylight = (half)u.sunDirDaylight.w;
    half3 sunCol = mix(half3(0.24h, 0.30h, 0.48h), half3(2.25h, 2.05h, 1.80h), daylight);
    half3 skyAmb = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(normal), sunDir) * 0.55h;

    half3 torch = half3(0.0h);
#if WARM_TORCHLIGHT
    torch = half3(1.55h, 0.88h, 0.40h) * (blockLight * blockLight);
#else
    torch = half3(blockLight * blockLight);
#endif

    half3 lit = alb.rgb * (sunCol * ndotl * skyLight + max(half3(0.08h), skyAmb * skyLight) + torch);

#if AERIAL_FOG
    float dist = length(worldPos);
    half fogFactor = saturate((half)((dist - u.fogRanges.z) / max(16.0f, u.fogRanges.w - u.fogRanges.z)));
    fogFactor *= fogFactor * 0.75h;
    half3 fogCol = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(viewDir.x, max(0.04f, viewDir.y), viewDir.z), sunDir);
    lit = mix(lit, fogCol, fogFactor);
#endif

    return half4(lit, 1.0h);
}
