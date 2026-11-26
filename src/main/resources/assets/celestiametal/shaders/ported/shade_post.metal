// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shade_post.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// P1 Post chain: bloom (13-tap down / 4-tap bilinear tent up), exposure histogram + reduce, Milky Way bake,
// height haze + Purkinje + vignette + vibrance + Shade Filmic display transform + IGN dither.

struct ShadeFsOut { float4 position [[position]]; float2 uv; };

vertex ShadeFsOut shade_fs_vs(uint vid [[vertex_id]]) {
	ShadeFsOut o;
	float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
	o.position = float4(p, 0.0, 1.0);
	o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
	return o;
}

constexpr sampler shadeLinearClamp(filter::linear, address::clamp_to_edge);

static inline half3 shadeDown13(texture2d<half> src, float2 uv, float2 texel, bool karis) {
	half3 a = src.sample(shadeLinearClamp, uv + texel * float2(-2, -2)).rgb;
	half3 b = src.sample(shadeLinearClamp, uv + texel * float2(0, -2)).rgb;
	half3 c = src.sample(shadeLinearClamp, uv + texel * float2(2, -2)).rgb;
	half3 d = src.sample(shadeLinearClamp, uv + texel * float2(-2, 0)).rgb;
	half3 e = src.sample(shadeLinearClamp, uv).rgb;
	half3 f = src.sample(shadeLinearClamp, uv + texel * float2(2, 0)).rgb;
	half3 g = src.sample(shadeLinearClamp, uv + texel * float2(-2, 2)).rgb;
	half3 h = src.sample(shadeLinearClamp, uv + texel * float2(0, 2)).rgb;
	half3 i = src.sample(shadeLinearClamp, uv + texel * float2(2, 2)).rgb;
	half3 j = src.sample(shadeLinearClamp, uv + texel * float2(-1, -1)).rgb;
	half3 k = src.sample(shadeLinearClamp, uv + texel * float2(1, -1)).rgb;
	half3 l = src.sample(shadeLinearClamp, uv + texel * float2(-1, 1)).rgb;
	half3 m = src.sample(shadeLinearClamp, uv + texel * float2(1, 1)).rgb;
	half3 g0 = (j + k + l + m) * 0.25h, g1 = (a + b + d + e) * 0.25h, g2 = (b + c + e + f) * 0.25h, g3 = (d + e + g + h) * 0.25h, g4 = (e + f + h + i) * 0.25h;
	if (!karis) return g0 * 0.5h + (g1 + g2 + g3 + g4) * 0.125h;
	half w0 = 1.0h / (1.0h + shadeLumaH(g0)), w1 = 1.0h / (1.0h + shadeLumaH(g1)), w2 = 1.0h / (1.0h + shadeLumaH(g2)),
	     w3 = 1.0h / (1.0h + shadeLumaH(g3)), w4 = 1.0h / (1.0h + shadeLumaH(g4));
	w0 *= 0.5h; w1 *= 0.125h; w2 *= 0.125h; w3 *= 0.125h; w4 *= 0.125h;
	return (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4);
}

static inline half3 shadeBloomInput(half3 sample) {
	return select(min(max(sample, 0.0h), 30000.0h), half3(0.0h), (as_type<ushort3>(sample) & ushort3(0x7c00)) == ushort3(0x7c00));
}

fragment half4 shade_bloom_down0(ShadeFsOut in [[stage_in]], texture2d<half> src [[texture(0)]], constant float4 &p [[buffer(0)]],
                                  device ShadeGpu &gw [[buffer(CM_SHADE_BUF_GPU)]]) {
	float2 texel = 1.0 / float2(src.get_width(), src.get_height());
	float2 uv = in.uv * p.xy, lo = texel, hi = p.xy - texel;
	half3 a = shadeBloomInput(src.sample(shadeLinearClamp, clamp(uv + texel * float2(-1, -1), lo, hi)).rgb);
	half3 b = shadeBloomInput(src.sample(shadeLinearClamp, clamp(uv + texel * float2(1, -1), lo, hi)).rgb);
	half3 c = shadeBloomInput(src.sample(shadeLinearClamp, clamp(uv + texel * float2(-1, 1), lo, hi)).rgb);
	half3 d = shadeBloomInput(src.sample(shadeLinearClamp, clamp(uv + texel * float2(1, 1), lo, hi)).rgb);
	half wa = 1.0h / (1.0h + shadeLumaH(a)), wb = 1.0h / (1.0h + shadeLumaH(b)), wc = 1.0h / (1.0h + shadeLumaH(c)), wd = 1.0h / (1.0h + shadeLumaH(d));
	(void)gw;
	return half4((a * wa + b * wb + c * wc + d * wd) / (wa + wb + wc + wd), 1.0h);
}

fragment half4 shade_bloom_down(ShadeFsOut in [[stage_in]], texture2d<half> src [[texture(0)]]) {
	float2 texel = 1.0 / float2(src.get_width(), src.get_height());
	return half4(shadeDown13(src, in.uv, texel, false), 1.0h);
}

struct ShadeBloomUp { float4 w; };

fragment half4 shade_bloom_up(ShadeFsOut in [[stage_in]], texture2d<half> level [[texture(0)]], texture2d<half> coarser [[texture(1)]],
                              constant ShadeBloomUp &p [[buffer(0)]]) {
	half3 l = level.sample(shadeLinearClamp, in.uv).rgb;
	float2 t = 1.0 / float2(coarser.get_width(), coarser.get_height());
	float2 o = t * 0.70710678;
	half3 u = coarser.sample(shadeLinearClamp, in.uv + o).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv - o).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv + float2(o.x, -o.y)).rgb * 0.25h
	        + coarser.sample(shadeLinearClamp, in.uv + float2(-o.x, o.y)).rgb * 0.25h;
	return half4(half3(min(float3(l) * p.w.x + float3(u) * p.w.y, 60000.0)), 1.0h);
}

struct ShadeFinalParams { float4 p; float4 q; float4 v; float4 r; float4 x; float4 a; };

static inline float shadeL4(float2 a) { float2 q = a * a; return sqrt(sqrt(dot(q, q))); }
static inline float shadeHazeBorderKeep(float3 p, constant ShadeLook &L) {
	float Rb = L.fogMisc.z;
	float loR = L.fogMisc.y * Rb;
	if (dot(p.xz, p.xz) <= loR * loR) return 1.0;
	return 1.0 - smoothstep(loR, Rb, shadeL4(p.xz));
}

static inline float3 shadeWorldFromDepth(float2 uv, float d, constant ShadeFrame &f) {
	float2 ndc = uv * 2.0 - 1.0;
	float4 w = f.invViewProj * float4(ndc, d, 1.0);
	return w.xyz / w.w;
}

static inline float3 shadeBlackFloor(float3 y, float phi) {
	if (phi > 0.0 && any(y < 16.0 * phi)) y += phi * exp(-y / max(phi, 1e-6));
	return y;
}

static inline half3 shadeLinearToSrgbFast(half3 y) {
	half3 hi = 1.055h * exp2(log2(max(y, 1e-6h)) * half(1.0 / 2.4)) - 0.055h;
	return select(hi, y * 12.92h, y <= 0.0031308h);
}

fragment float4 shade_final(ShadeFsOut in [[stage_in]],
                            texture2d<half> scene [[texture(0)]],
                            texture2d<half> bloom [[texture(1)]],
                            depth2d<float> depth [[texture(2)]],
                            texture2d<half> bloom0 [[texture(3)]],
#ifdef CELESTIA_VL_COMPOSITE
                            texture2d<half> volume [[texture(4)]],
#endif
#ifdef CELESTIA_SSAO
                            texture2d<half> ambientOcclusion [[texture(5)]],
#endif
                            constant ShadeFinalParams &P [[buffer(0)]],
                            constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                            constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                            constant ShadeGpu &g [[buffer(CM_SHADE_BUF_GPU)]]) {
	uint2 px = uint2(in.position.xy);
	float ex = max(g.exposure.x, 1e-6);
	float2 dsize = P.r.x > 0.0 ? P.r.xy : float2(depth.get_width(), depth.get_height());
	uint2 dpx = min(uint2(in.uv * dsize), uint2(dsize) - 1u);
	float d = depth.read(dpx);
	float3 c = float3(scene.read(px).rgb);
	float3 T = float3(1.0);
	bool hazeOn = (L.tier.y & SHADE_FEATURE_HAZE) != 0 && f.flags.x == SHADE_DIM_OVERWORLD && f.fogColor.a < 0.5;
	float hazeNear = shadeAirSmooth(L) ? 0.0 : 4.0;
	bool aoOn = false;
#ifdef CELESTIA_SSAO
	aoOn = P.v.y > 0.5;
#endif
	if (d > 0.0 && (hazeOn || aoOn)) {
		float3 wp = shadeWorldFromDepth(in.uv, d, f);
#ifdef CELESTIA_SSAO
		if (aoOn) c *= float(shadeAoSample(ambientOcclusion, in.uv, length(wp)));
#endif
		if (hazeOn && dot(wp, wp) > hazeNear) {
			float3 S = shadeHazeInscatter(wp, f, L, 1.0, T);
			if (L.user4.x > 1.5 && L.fogMisc.z > 0.0) {
				float kk = shadeHazeBorderKeep(wp, L);
				T = mix(float3(1.0), T, kk);
				S *= kk;
			}
			c = c * T + S * ex;
		}
	}
	if (P.p.y > 0.5) {
		float3 b = float3(bloom.sample(shadeLinearClamp, in.uv).rgb + bloom0.sample(shadeLinearClamp, in.uv).rgb * half(P.q.x)) * P.p.x;
		float mSky = L.bloom.z * 0.25;
		float mTerr = L.bloom.z * (1.0 - shadeLuma(T));
		float m = L.bloom.x + (d > 0.0 ? mTerr : mSky);
		c = mix(c, b, saturate(m));
	}
#ifdef CELESTIA_VL_COMPOSITE
	if (P.v.x > 0.5) c += vlUpsample(volume, in.uv, vlDistance(in.uv, d, shadeEye(f.invViewProj), f)) * ex;
#endif
	c = select(c, float3(0.0), (as_type<uint3>(c) & uint3(0x7f800000u)) == uint3(0x7f800000u));
	half3 ch = half3(min(max(c, 0.0), 60000.0));
	half lch = shadeLumaH(ch);
	float lum = float(lch) / ex;
	if (lum < 0.04 && L.grade1.w > 0.0) {
		half rods = half((1.0 - smoothstep(0.004, 0.04, lum)) * L.grade1.w);
		ch = mix(ch, half3(lch) * half3(0.72h, 0.88h, 1.3h), rods);
		lch = shadeLumaH(ch);
	}
	half2 rh = half2((in.uv - 0.5) * float2(float(scene.get_width()) / float(scene.get_height()), 1.0));
	half vx = saturate(length(rh) * 1.25h);
	half vr = (vx * vx) * (0.8h * sqrt(vx) + 0.2h);
	half vig = 1.0h - half(L.user0.y) * vr * (1.0h - 0.5h * saturate(lch - 1.0h));
	ch *= vig;
	half Y = lch * vig;
	half mx = max(max(ch.r, ch.g), ch.b), mn = min(min(ch.r, ch.g), ch.b);
	half chroma = (mx - mn) / max(mx, 1e-4h);
	ch = max(Y + (ch - Y) * (1.0h + half(L.grade0.z) * (1.0h - saturate(chroma * half(1.0 / 0.6)))), 0.0h);

	float3 y = shadeBlackFloor(shadeDisplay(float3(ch), L), L.grade2.w);
	half3 srgb = shadeLinearToSrgbFast(half3(saturate(y)));
	half n = half(shadeNoise(in.position.xy, int(P.p.z))) * 2.0h - 1.0h;
	half tri = sign(n) * (1.0h - sqrt(max(1.0h - abs(n), 0.0h)));
	srgb += tri * half(L.output.z / 255.0);
	if (P.p.w == 4.0) srgb = half3(half(saturate(log2(max(lum, 1e-6)) / 16.0 + 0.6)));
	return float4(float3(saturate(srgb)), 1.0);
}

#define SHADE_HIST_MIN -14.0
#define SHADE_HIST_MAX 8.0

kernel void shade_histogram(texture2d<half> src [[texture(0)]], device ShadeGpu &g [[buffer(CM_SHADE_BUF_GPU)]],
                            uint2 id [[thread_position_in_grid]], uint lid [[thread_index_in_threadgroup]]) {
	threadgroup atomic_uint bins[64];
	if (lid < 64) atomic_store_explicit(&bins[lid], 0u, memory_order_relaxed);
	threadgroup_barrier(mem_flags::mem_threadgroup);
	uint w = src.get_width(), h = src.get_height();
	uint phase = uint(g.scene.w) & 3u;
	uint2 p = id * 2u + uint2(phase & 1u, (phase >> 1u) & 1u);
	if (p.x < w && p.y < h) {
		float logEx = log2(max(g.exposure.x, 1e-6));
		float logLum = log2(max(float(shadeLumaH(src.read(p).rgb)), 1e-7)) - logEx;
		float t = (logLum - SHADE_HIST_MIN) * (1.0 / (SHADE_HIST_MAX - SHADE_HIST_MIN));
		uint bin = uint(clamp(t * 64.0, 0.0, 63.0));
		float2 r = (float2(p) + 0.5) / float2(w, h) - 0.5;
		float weight = exp(-dot(r, r) * (1.0 / 0.3));
		atomic_fetch_add_explicit(&bins[bin], uint(weight * 16.0 + 0.5), memory_order_relaxed);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (lid < 64) {
		uint v = atomic_load_explicit(&bins[lid], memory_order_relaxed);
		if (v != 0) atomic_fetch_add_explicit((device atomic_uint *)&g.histogram[lid], v, memory_order_relaxed);
	}
}

kernel void shade_exposure(device ShadeGpu &g [[buffer(CM_SHADE_BUF_GPU)]], constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                           uint id [[thread_position_in_grid]]) {
	if (id != 0) return;
	float total = 0.0;
	for (int i = 0; i < 64; i++) total += float(g.histogram[i]);
	float logRef = log2(max(L.exposureRef.x, 1e-6)) + L.grade0.x;
	float target = logRef;
	float mean = g.scene.x;
	if (total > 0.0) {
		float upper = L.user3.x > 0.0 ? mix(0.92, 0.98, min(L.user3.x, 1.0)) : 0.92;
		float lo = total * 0.40, hi = total * upper, acc = 0.0, sum = 0.0, wsum = 0.0;
		for (int i = 0; i < 64; i++) {
			float n = float(g.histogram[i]);
			float a = max(lo - acc, 0.0), b = min(hi - acc, n);
			float take = max(b - a, 0.0);
			float l = SHADE_HIST_MIN + (float(i) + 0.5) / 64.0 * (SHADE_HIST_MAX - SHADE_HIST_MIN);
			sum += take * l;
			wsum += take;
			acc += n;
		}
		if (wsum > 0.0) mean = sum / wsum;
		float metered = log2(max(L.exposureRef.z, 1e-4)) - mean;
		float lambda = L.exposureRef.y;
		target = lambda * metered + (1.0 - lambda) * logRef;
		target = clamp(target, logRef - L.exposureCfg.x, logRef + L.exposureCfg.y);
	}
	float now = log2(max(g.exposure.x, 1e-6));
	float next;
	if (L.exposureRef.w > 0.5 || !(now > -30.0 && now < 30.0)) {
		next = target;
	} else {
		float tau = target > now ? L.exposureCfg.z : L.exposureCfg.w;
		next = now + (target - now) * (1.0 - exp(-L.dt.x / max(tau, 1e-3)));
	}
	g.exposure = float4(exp2(next), exp2(target), g.exposure.x, next);
	g.scene.x = mean;
	g.scene.w += 1.0;
	for (int i = 0; i < 64; i++) g.histogram[i] = 0u;
}

static float shadeValueNoise(float3 x, uint salt) {
	float3 i = floor(x), fr = x - i;
	float3 u = fr * fr * (3.0 - 2.0 * fr);
	int3 c = int3(i);
	float n000 = shadeHash01(shadeHash3(c, salt)), n100 = shadeHash01(shadeHash3(c + int3(1, 0, 0), salt));
	float n010 = shadeHash01(shadeHash3(c + int3(0, 1, 0), salt)), n110 = shadeHash01(shadeHash3(c + int3(1, 1, 0), salt));
	float n001 = shadeHash01(shadeHash3(c + int3(0, 0, 1), salt)), n101 = shadeHash01(shadeHash3(c + int3(1, 0, 1), salt));
	float n011 = shadeHash01(shadeHash3(c + int3(0, 1, 1), salt)), n111 = shadeHash01(shadeHash3(c + int3(1, 1, 1), salt));
	return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}
static float shadeFbm(float3 x, int octaves, uint salt) {
	float s = 0.0, a = 0.5, n = 0.0;
	for (int i = 0; i < octaves; i++) {
		s += a * shadeValueNoise(x, salt + uint(i) * 101u);
		n += a;
		x = x * 2.03 + 17.1;
		a *= 0.5;
	}
	return s / n;
}

fragment half4 shade_milkyway_bake(ShadeFsOut in [[stage_in]]) {
	float lon = (in.uv.x - 0.5) * 6.2831853, lat = (in.uv.y - 0.5) * 3.1415927;
	float3 dir = float3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat));
	float lc = abs(lon);
	float b = abs(lat) * 57.29578, l = lc * 57.29578;
	float disc = exp(-b / (3.0 + 3.0 * pow(cos(lon * 0.5), 2.0))) * (0.6 + 0.4 * shadeFbm(dir * 6.0, 4, 11u));
	float bulge = 2.2 * exp(-(l * l / 144.0 + b * b / 36.0));
	float dust = 1.0 - 0.75 * (1.0 - abs(2.0 * shadeFbm(dir * 9.0, 3, 23u) - 1.0)) * exp(-b / 2.0);
	float clouds = 0.3 * pow(shadeFbm(dir * 40.0, 2, 37u), 4.0) * exp(-b / 8.0);
	float v = (disc + bulge) * dust + clouds;
	float3 col = mix(float3(1.0, 0.86, 0.66), float3(0.74, 0.82, 1.0), saturate(l / 70.0));
	return half4(half3(col * v * 0.035), half(shadeDimsBakeNoise(in.uv)));
}
