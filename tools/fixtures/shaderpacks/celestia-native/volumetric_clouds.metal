// Half-resolution volumetric cloud raymarch with Mie silver lining and subtle god-ray scattering.
inline float celestia_cloud_density(float2 p, float t) {
    float n1 = sin(p.x * 0.018f + t * 0.04f) * cos(p.y * 0.018f - t * 0.03f);
    float n2 = sin(p.x * 0.043f - t * 0.07f + p.y * 0.031f);
    float d = (n1 * 0.6f + n2 * 0.4f) * 0.5f + 0.5f;
    return smoothstep(0.48f, 0.85f, d);
}

kernel void celestia_clouds_cs(
    texture2d<half, access::write> outClouds [[texture(0)]],
    texture2d<float> depthTex [[texture(1)]],
    texture2d<half> skyLutTex [[texture(2)]],
    sampler linearSamp [[sampler(0)]],
    constant CelestiaFrameUniforms& u [[buffer(14)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = outClouds.get_width();
    uint h = outClouds.get_height();
    if (gid.x >= w || gid.y >= h) return;

#if !CLOUDS_ENABLED
    outClouds.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
    return;
#endif

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float depth = depthTex.sample(linearSamp, uv).r;
    if (!celestia_is_sky(depth)) {
        outClouds.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
        return;
    }

    float3 viewDir = normalize(celestia_reconstruct_world(uv, 0.0f, u));
    if (viewDir.y <= 0.02f) {
        outClouds.write(half4(0.0h, 0.0h, 0.0h, 1.0h), gid);
        return;
    }

    float3 sunDir = normalize(u.sunDirDaylight.xyz);
    half3 skyAmb = celestia_sample_sky_lut(skyLutTex, linearSamp, float3(0.0f, 0.6f, 0.0f), sunDir);

    float cloudBase = 180.0f;
    float cloudTop = 240.0f;
    float t0 = (cloudBase - u.cameraPosTime.y) / max(viewDir.y, 0.05f);
    float t1 = (cloudTop - u.cameraPosTime.y) / max(viewDir.y, 0.05f);
    t0 = max(t0, 0.0f);
    t1 = min(max(t1, t0 + 10.0f), t0 + 400.0f);

    const int steps = CLOUD_STEPS;
    float dt = (t1 - t0) / float(steps);
    float jitter = celestia_hash12(float2(gid) + u.skyColorFrame.w);

    half transmittance = 1.0h;
    half3 scatter = half3(0.0h);
    float mu = dot(viewDir, sunDir);
    half silverLining = pow(saturate((half)mu), 8.0h) * 1.4h + 0.35h;
    half3 sunCol = mix(half3(0.25h, 0.30h, 0.45h), half3(1.8h, 1.65h, 1.45h), (half)u.sunDirDaylight.w) * silverLining;

    for (int i = 0; i < steps; i++) {
        float t = t0 + (float(i) + jitter) * dt;
        float3 p = u.cameraPosTime.xyz + viewDir * t;
        float dens = celestia_cloud_density(p.xz, u.cameraPosTime.w);
        if (dens > 0.01f) {
            half stepAlpha = (half)(dens * 0.28f);
            half3 stepCol = sunCol * (0.45h + 0.55h * (half)i / (half)steps) + skyAmb * 0.45h;
            scatter += transmittance * stepCol * stepAlpha;
            transmittance *= (1.0h - stepAlpha);
            if (transmittance < 0.02h) break;
        }
    }

    // Distance fade near horizon
    half horizonFade = smoothstep(0.02h, 0.14h, (half)viewDir.y);
    scatter *= horizonFade;
    transmittance = mix(1.0h, transmittance, horizonFade);

    outClouds.write(half4(scatter, transmittance), gid);
}
