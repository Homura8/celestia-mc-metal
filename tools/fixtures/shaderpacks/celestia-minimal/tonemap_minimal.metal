fragment half4 celestia_min_tonemap_fs(
    CelestiaFullscreenOut in [[stage_in]],
    texture2d<half> sceneTex [[texture(0)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]]
) {
    half3 col = sceneTex.sample(linearSamp, in.uv).rgb * (half)EXPOSURE;
    half3 mapped = celestia_tonemap_agx(col);
    half lum = celestia_luminance(mapped);
    mapped = max(half3(0.0h), mix(half3(lum), mapped, (half)SATURATION));
    return half4(mapped, 1.0h);
}
