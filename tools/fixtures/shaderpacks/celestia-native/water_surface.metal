// Reflective & refractive water surface pass with multi-octave ripples, Fresnel sky/SSR reflections,
// Beer-Lambert depth absorption, and sunlit caustics.
inline float2 celestia_wave_grad(float2 p, float t) {
    float w1 = sin(p.x * 1.8f + t * 1.4f) * cos(p.y * 1.5f - t * 1.1f);
    float w2 = sin((p.x + p.y) * 3.1f - t * 2.2f);
    return float2(w1 * 0.035f + w2 * 0.018f, w1 * 0.028f - w2 * 0.021f);
}

fragment half4 celestia_water_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> sceneColorTex [[texture(0)]],
    texture2d<half> waterMaskTex [[texture(1)]],   // r=isWater, g=skyLight, b=depthDelta
    texture2d<float> depthTex [[texture(2)]],
    texture2d<half> skyLutTex [[texture(3)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    half4 baseScene = sceneColorTex.sample(linearSamp, in.uv);
    half4 mask = waterMaskTex.sample(linearSamp, in.uv);
    if (mask.r < 0.1h) {
        return baseScene;
    }

    float depth = depthTex.sample(linearSamp, in.uv).r;
    float3 worldPos = celestia_reconstruct_world(in.uv, depth, u);
    float3 absPos = worldPos + u.cameraPosTime.xyz;
    float3 viewDir = normalize(worldPos);
    float3 sunDir = normalize(u.sunDirDaylight.xyz);

    half3 n = half3(0.0h, 1.0h, 0.0h);
#if WATER_WAVES
    float2 g = celestia_wave_grad(absPos.xz, u.cameraPosTime.w);
    n = normalize(half3((half)g.x, 1.0h, (half)g.y));
#endif

    // Beer-Lambert depth absorption
    half waterDepth = max(0.25h, mask.b * 24.0h);
    half3 transmittance = exp(-half3(0.42h, 0.14h, 0.08h) * waterDepth);
    half3 refracted = baseScene.rgb;
#if WATER_WAVES
    float2 refractUv = clamp(in.uv + float2(n.xz) * 0.018f, float2(0.001f), float2(0.999f));
    refracted = sceneColorTex.sample(linearSamp, refractUv).rgb;
#endif

#if WATER_CAUSTICS
    float caust = sin(absPos.x * 2.6f + u.cameraPosTime.w * 2.1f) * sin(absPos.z * 2.6f - u.cameraPosTime.w * 1.7f);
    refracted += half3(0.18h, 0.24h, 0.28h) * saturate((half)caust) * mask.g * (half)u.sunDirDaylight.w;
#endif
    refracted *= transmittance;

    // Fresnel + reflections
    half ndotv = saturate(dot(- (half3)viewDir, n));
    half fresnel = 0.02h + 0.98h * pow(1.0h - ndotv, 5.0h);
    float3 reflDir = reflect(viewDir, float3(n));
    half3 reflCol = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(reflDir.x, max(0.02f, reflDir.y), reflDir.z), sunDir);

#if WATER_REFLECTIONS == 2
    // Fast single-step screen-space reflection blend when enabled
    float2 ssrUv = clamp(in.uv + float2(reflDir.x, -reflDir.y) * 0.12f, float2(0.01f), float2(0.99f));
    half3 ssrSample = sceneColorTex.sample(linearSamp, ssrUv).rgb;
    reflCol = mix(reflCol, ssrSample, 0.35h);
#endif

    // Sun specular glint
    half3 halfVec = normalize((half3)sunDir - (half3)viewDir);
    half spec = pow(saturate(dot(n, halfVec)), 192.0h) * (half)u.sunDirDaylight.w * mask.g;
    half3 finalCol = mix(refracted, reflCol, fresnel) + half3(2.4h, 2.1h, 1.7h) * spec;

    return half4(mix(baseScene.rgb, finalCol, mask.r), 1.0h);
}
