// Deferred world lighting pass: G-buffer decode, 2-cascade hardware PCF shadows (with cave early-out),
// SSAO, warm/colored block light, dynamic held-item glow, and atmospheric aerial perspective.
fragment half4 celestia_deferred_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> gAlbedoTex [[texture(0)]],      // rgb albedo, a material id
    texture2d<half> gDataTex [[texture(1)]],        // rg octahedral normal, b blockLight, a skyLight
    texture2d<float> depthTex [[texture(2)]],
    texture2d<half> skyLutTex [[texture(3)]],
    depth2d_array<float> shadowMap [[texture(4)]],
    sampler linearSamp [[sampler(0)]],
    sampler shadowSamp [[sampler(1)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    float depth = depthTex.sample(linearSamp, in.uv).r;
    float3 worldPos = celestia_reconstruct_world(in.uv, depth, u);
    float3 viewDir = normalize(worldPos);
    float3 sunDir = normalize(u.sunDirDaylight.xyz);

    if (celestia_is_sky(depth)) {
        half3 sky = celestia_sample_sky_lut(skyLutTex, linearSamp, viewDir, sunDir);
#if STARFIELD_ENABLED
        if (u.sunDirDaylight.w < 0.35f && viewDir.y > 0.02f) {
            float2 starCell = floor(viewDir.xz / max(0.15f, viewDir.y) * 190.0f);
            float h = celestia_hash12(starCell);
            if (h > 0.9965f) {
                float twinkle = 0.65f + 0.35f * sin(u.cameraPosTime.w * 2.5f + h * 100.0f);
                sky += half3(0.85h, 0.88h, 1.0h) * (half)(twinkle * (1.0f - u.sunDirDaylight.w * 2.8f));
            }
        }
#endif
        // Sun / moon disc
        float sunDot = dot(viewDir, sunDir);
        if (sunDot > 0.9992f) {
            half disc = smoothstep(0.9992h, 0.9997h, (half)sunDot);
            sky += mix(half3(0.75h, 0.85h, 1.15h), half3(5.5h, 4.4h, 3.0h), (half)u.sunDirDaylight.w) * disc;
        }
        return half4(sky, 1.0h);
    }

    half4 alb = gAlbedoTex.sample(linearSamp, in.uv);
    half4 gdata = gDataTex.sample(linearSamp, in.uv);
    half3 normal = celestia_decode_octahedral(gdata.rg);
    half blockLight = gdata.b;
    half skyLight = gdata.a;

    half daylight = (half)u.sunDirDaylight.w;
    half rain = (half)u.weatherState.y;

    // 1. Directional sun/moon light with cave early-out shadow PCF
    half ndotl = saturate(dot(normal, (half3)sunDir));
    half shadow = 1.0h;
#if SHADOWS_ENABLED
    if (ndotl > 0.0h) {
        shadow = celestia_sample_shadow_pcf(worldPos, skyLight, shadowMap, shadowSamp, u);
    }
#endif
    half3 sunColor = mix(half3(0.28h, 0.34h, 0.56h), half3(2.85h, 2.55h, 2.15h), daylight);
    sunColor = mix(sunColor, half3(2.4h, 1.15h, 0.85h), (half)u.weatherState.x * 0.75h);
    sunColor *= (1.0h - rain * 0.65h);

    // 2. Hemisphere ambient from sky LUT + subtle ground bounce
    half3 skyAmb = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(normal), sunDir);
    half3 ambient = mix(half3(0.06h, 0.065h, 0.09h), skyAmb * 0.55h, saturate(skyLight * 1.1h));

    // 3. Fast 4-tap screen-space ambient occlusion
    half ao = 1.0h;
#if SSAO_ENABLED
    float2 texel = 1.5f / max(u.resolutionParams.xy, float2(1.0f));
    float d0 = depthTex.sample(linearSamp, in.uv + float2(texel.x, 0)).r;
    float d1 = depthTex.sample(linearSamp, in.uv - float2(texel.x, 0)).r;
    float d2 = depthTex.sample(linearSamp, in.uv + float2(0, texel.y)).r;
    float d3 = depthTex.sample(linearSamp, in.uv - float2(0, texel.y)).r;
    float diff = max(0.0f, (d0 + d1 + d2 + d3) * 0.25f - depth);
    ao = clamp(1.0h - (half)(diff * 42.0f), 0.45h, 1.0h);
#endif

    // 4. Warm block light + optional held-item dynamic light
    half blPow = blockLight * blockLight;
    half3 torchLight = half3(1.65h, 0.92h, 0.42h) * blPow;
#if DYNAMIC_LIGHTS
    float distSq = dot(worldPos, worldPos);
    half dynAtten = (half)(u.qualityFlags.x / (1.0f + distSq * 0.08f));
    torchLight += half3(1.25h, 0.76h, 0.38h) * dynAtten * 0.45h;
#endif

    half3 direct = sunColor * ndotl * shadow * (0.2h + 0.8h * skyLight);
    half3 lit = alb.rgb * (direct + ambient * ao + torchLight);

    // 5. Atmospheric aerial perspective fog
#if AERIAL_FOG
    float dist = length(worldPos);
    half fogFactor = saturate((half)((dist - u.fogRanges.z) / max(16.0f, u.fogRanges.w - u.fogRanges.z)));
    fogFactor = fogFactor * fogFactor * 0.82h;
    half3 fogCol = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(viewDir.x, max(0.04f, viewDir.y), viewDir.z), sunDir);
    lit = mix(lit, fogCol, fogFactor);
#endif

    return half4(lit, 1.0h);
}
