// Final HDR composite, dual Kawase bloom blend, tone mapping (AgX / ACES / Celestia Filmic),
// EDR highlight headroom scaling, saturation, and subtle dithering.
fragment half4 celestia_tonemap_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> sceneTex [[texture(0)]],
    texture2d<half> cloudTex [[texture(1)]],
    texture2d<half> bloomTex [[texture(2)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    half3 col = sceneTex.sample(linearSamp, in.uv).rgb;
    half4 clouds = cloudTex.sample(linearSamp, in.uv);
    col = col * clouds.a + clouds.rgb;

#if BLOOM_ENABLED
    half3 bloom = bloomTex.sample(linearSamp, in.uv).rgb;
    col += bloom * (half)BLOOM_STRENGTH;
#endif

    col *= (half)EXPOSURE;

    // Preserve extra dynamic range headroom on Apple XDR / EDR displays
    half edrCap = clamp((half)u.resolutionParams.w, 1.0h, (half)HDR_EDR_BOOST);

#if TONEMAP_CURVE == 1
    half3 mapped = celestia_tonemap_aces(col);
#elif TONEMAP_CURVE == 2
    half3 mapped = celestia_tonemap_filmic(col);
#else
    half3 mapped = celestia_tonemap_agx(col);
#endif

    // Scale highlights smoothly toward EDR peak when EDR is active
    half lum = celestia_luminance(mapped);
    if (edrCap > 1.01h && lum > 0.72h) {
        half boost = mix(1.0h, edrCap, smoothstep(0.72h, 1.0h, lum));
        mapped *= boost;
    }

    // Saturation
    half finalLum = celestia_luminance(mapped);
    mapped = max(half3(0.0h), mix(half3(finalLum), mapped, (half)SATURATION));

    // Subtle filmic dither to prevent banding in dark skies
    half dither = ((half)celestia_hash12(in.position.xy) - 0.5h) * (1.0h / 255.0h);
    mapped = max(half3(0.0h), mapped + dither);

    return half4(mapped, 1.0h);
}
