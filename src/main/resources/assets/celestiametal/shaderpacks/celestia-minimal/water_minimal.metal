fragment half4 celestia_min_water_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> sceneColorTex [[texture(0)]],
    texture2d<half> waterMaskTex [[texture(1)]],
    texture2d<float> depthTex [[texture(2)]],
    texture2d<half> skyLutTex [[texture(3)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    half4 baseScene = sceneColorTex.sample(linearSamp, in.uv);
    half4 mask = waterMaskTex.sample(linearSamp, in.uv);
    if (mask.r < 0.1h) return baseScene;

#if !WATER_SPECULAR
    return baseScene;
#endif

    float depth = depthTex.sample(linearSamp, in.uv).r;
    float3 viewDir = normalize(celestia_reconstruct_world(in.uv, depth, u));
    float3 sunDir = normalize(u.sunDirDaylight.xyz);
    half3 n = half3(0.0h, 1.0h, 0.0h);
    half fresnel = 0.03h + 0.97h * pow(1.0h - saturate(- (half)viewDir.y), 5.0h);
    float3 reflDir = reflect(viewDir, float3(n));
    half3 reflCol = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(reflDir.x, max(0.02f, reflDir.y), reflDir.z), sunDir);
    half3 halfVec = normalize((half3)sunDir - (half3)viewDir);
    half spec = pow(saturate(dot(n, halfVec)), 128.0h) * (half)u.sunDirDaylight.w * mask.g;

    return half4(mix(baseScene.rgb, mix(baseScene.rgb * half3(0.70h, 0.88h, 0.96h), reflCol, fresnel) + half3(2.0h, 1.8h, 1.5h) * spec, mask.r), 1.0h);
}
