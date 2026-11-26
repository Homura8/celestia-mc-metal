// Precomputed 64x32 upper-hemisphere atmospheric scattering LUT (Rayleigh + Mie + Celestia twilight).
kernel void celestia_sky_lut_cs(
    texture2d<half, access::write> outLut [[texture(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outLut.get_width();
    uint h = outLut.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float cosAz = uv.x * 2.0f - 1.0f;
    float sinAz = sqrt(max(0.0f, 1.0f - cosAz * cosAz));

    // dir.y = v^2 concentrate samples near the horizon without asin().
    float dy = uv.y * uv.y;
    float horizLen = sqrt(max(0.0f, 1.0f - dy * dy));

    float3 sunDir = normalize(u.sunDirDaylight.xyz);
    float2 sunHoriz = normalize(float2(sunDir.x, sunDir.z) + float2(1e-5f, 0.0f));
    float2 perpHoriz = float2(-sunHoriz.y, sunHoriz.x);
    float2 viewHoriz = sunHoriz * cosAz + perpHoriz * sinAz;
    float3 dir = normalize(float3(viewHoriz.x * horizLen, dy, viewHoriz.y * horizLen));

    half daylight = (half)u.sunDirDaylight.w;
    half twilight = (half)u.weatherState.x;
    half rain = (half)u.weatherState.y;

    float mu = dot(dir, sunDir);
    half zenithFactor = saturate((half)dir.y);
    half horizonGlow = pow(1.0h - zenithFactor, 3.2h);

    // Day Rayleigh + twilight lavender/peach palette inspired by CelestiaGlow
    half3 dayZenith = half3(0.14h, 0.36h, 0.82h);
    half3 dayHorizon = half3(0.56h, 0.75h, 0.96h);
    half3 twilightHorizon = half3(0.96h, 0.52h, 0.62h);
    half3 twilightZenith = half3(0.24h, 0.22h, 0.48h);
    half3 nightZenith = half3(0.015h, 0.020h, 0.045h);
    half3 nightHorizon = half3(0.045h, 0.055h, 0.105h);

    half3 sky = mix(nightZenith, dayZenith, daylight);
    half3 hor = mix(nightHorizon, dayHorizon, daylight);
    sky = mix(sky, twilightZenith, twilight * 0.85h);
    hor = mix(hor, twilightHorizon, twilight);

    half3 baseCol = mix(hor, sky, pow(zenithFactor, 0.58h));

    // Mie forward scattering lobe
    const float g = 0.76f;
    float miePhase = (1.0f - g * g) / (4.0f * 3.1415926f * pow(max(0.05f, 1.0f + g * g - 2.0f * g * mu), 1.5f));
    half3 mieColor = mix(half3(0.45h, 0.55h, 0.85h), half3(1.0h, 0.78h, 0.55h), saturate(daylight + twilight));
    baseCol += mieColor * (half)clamp(miePhase * 0.22f, 0.0f, 3.5f) * (0.25h + 0.75h * horizonGlow);

    // Subtle rain desaturation
    half lum = celestia_luminance(baseCol);
    baseCol = mix(baseCol, half3(lum * 0.82h, lum * 0.86h, lum * 0.94h), rain * 0.68h);

    outLut.write(half4(max(baseCol, half3(0.0h)), 1.0h), gid);
}
