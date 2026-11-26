// Dual Kawase bloom downsample compute kernel with Karis average firefly suppression.
kernel void celestia_bloom_down_cs(
    texture2d<half, access::write> dstTex [[texture(0)]],
    texture2d<half> srcTex [[texture(1)]],
    sampler linearSamp [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = dstTex.get_width();
    uint h = dstTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 uv = (float2(gid) + 0.5f) / float2(w, h);
    float2 halfPixel = 0.5f / float2(w, h);

    half3 c0 = srcTex.sample(linearSamp, uv).rgb;
    half3 c1 = srcTex.sample(linearSamp, uv + float2(-halfPixel.x, -halfPixel.y)).rgb;
    half3 c2 = srcTex.sample(linearSamp, uv + float2( halfPixel.x, -halfPixel.y)).rgb;
    half3 c3 = srcTex.sample(linearSamp, uv + float2(-halfPixel.x,  halfPixel.y)).rgb;
    half3 c4 = srcTex.sample(linearSamp, uv + float2( halfPixel.x,  halfPixel.y)).rgb;

    half3 avg = c0 * 0.5h + (c1 + c2 + c3 + c4) * 0.125h;
    half lum = celestia_luminance(avg);
    half knee = smoothstep(0.95h, 1.85h, lum);
    dstTex.write(half4(avg * knee, 1.0h), gid);
}
