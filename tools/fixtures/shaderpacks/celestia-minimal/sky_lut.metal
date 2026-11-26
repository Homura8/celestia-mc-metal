kernel void celestia_min_sky_lut_cs(
    texture2d<half, access::write> outLut [[texture(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outLut.get_width();
    uint h = outLut.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float dy = uv.y * uv.y;
    half zenith = saturate((half)dy);
    half daylight = (half)u.sunDirDaylight.w;
    half twilight = (half)u.weatherState.x;

    half3 sky = mix(half3(0.02h, 0.03h, 0.07h), half3(0.16h, 0.38h, 0.84h), daylight);
    half3 hor = mix(half3(0.06h, 0.08h, 0.14h), half3(0.58h, 0.76h, 0.96h), daylight);
    hor = mix(hor, half3(0.95h, 0.56h, 0.64h), twilight);

    half3 col = mix(hor, sky, pow(zenith, 0.6h));
    outLut.write(half4(col, 1.0h), gid);
}
