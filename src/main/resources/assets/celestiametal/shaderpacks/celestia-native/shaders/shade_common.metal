// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shade_common.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
#ifndef MCOPT_SHADE_COMMON
#define MCOPT_SHADE_COMMON
#include <metal_stdlib>
using namespace metal;


#ifdef SHADE_LEAN_ABOVE
#define SHADE_CAMERA_UNDERWATER(f) false
#else
#define SHADE_CAMERA_UNDERWATER(f) ((f).flags2.y != 0)
#endif

static inline bool shadeBad(half4 v) { return any((as_type<ushort4>(v) & ushort4(0x7c00)) == ushort4(0x7c00)); }
static inline bool shadeBad(float3 v) { return any((as_type<uint3>(v) & uint3(0x7f800000)) == uint3(0x7f800000)); }

static inline float3 shadeEye(float4x4 invViewProj) { float4 e = invViewProj[2]; return e.xyz / e.w; }
static inline float3 shadeViewRay(float2 ndc, float4x4 invViewProj) {
	float4 w = invViewProj * float4(ndc, 0.5, 1.0);
	return w.xyz / w.w - shadeEye(invViewProj);
}

#define SHADE_DIM_OVERWORLD 0
#define SHADE_DIM_NETHER 1
#define SHADE_DIM_END 2

static inline half3 shadeToLinear(half3 c) { return c * c * (c * 0.305306011h + 0.682171111h) + c * 0.012522878h; }
static inline half3 shadeToSrgb(half3 c) {
	half3 s1 = sqrt(c), s2 = sqrt(s1), s3 = sqrt(s2);
	return saturate(half(0.585122381) * s1 + half(0.783140355) * s2 - half(0.368262736) * s3);
}
static inline float shadeLuma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
static inline half shadeLumaH(half3 c) { return dot(c, half3(0.2126h, 0.7152h, 0.0722h)); }

static inline float shadeCurve(float x) {
	float y = 1.0 - exp2(-1.5869637 * max(x, 0.0));
	return y * y * 1.006 / (y + 0.006);
}
static inline float3 shadeCurve3(float3 x) {
	float3 y = 1.0 - exp2(-1.5869637 * max(x, 0.0));
	return y * y * 1.006 / (y + 0.006);
}

static inline float3 shadeOutput(float3 radiance, constant ShadeFrame &f) {
	float3 c = max(radiance, 0.0);
	float lin = shadeLuma(c);
	float rods = (1.0 - smoothstep(0.004, 0.04, lin)) * 0.55;
	c = mix(c, float3(lin) * float3(0.72, 0.88, 1.3), rods) * f.time.z;
	float m = max(max(c.r, c.g), max(c.b, 1e-6));
	float tm = shadeCurve(m);
	float3 o = c * (tm / m);
	if (tm > 0.6) o = mix(o, shadeCurve3(c), smoothstep(0.6, 1.0, tm) * 0.6);
	return float3(shadeToSrgb(half3(saturate(o))));
}

#define SHADE_R_GROUND 6360.0f
#define SHADE_R_TOP 6420.0f
#define SHADE_ALTITUDE 0.5f
#define SHADE_H_R 8.0f
#define SHADE_H_M 1.2f
#define SHADE_MIE_G 0.78f
#define SHADE_SAMPLES 8
#define SHADE_SKY_SATURATION 1.3f
constant float3 SHADE_BETA_R = float3(5.802e-3, 13.558e-3, 33.1e-3);
constant float SHADE_BETA_M = 3.996e-3;
constant float SHADE_BETA_M_EXT = 4.440e-3;
constant float3 SHADE_BETA_O = float3(0.650e-3, 1.881e-3, 0.085e-3) * 2.2;

static inline float shadeColumn(float r, float mu, float h) {
	float c = sqrt(r / h * 1.5707963);
	if (mu >= 0.0) return h * exp((SHADE_R_GROUND - r) / h) * c / ((c - 1.0) * mu + 1.0);
	float rt = r * sqrt(max(1.0 - mu * mu, 0.0));
	float deep = max(SHADE_R_GROUND - rt, 0.0);
	rt = max(rt, SHADE_R_GROUND);
	float ct = sqrt(rt / h * 1.5707963);
	return h * (2.0 * ct * exp((SHADE_R_GROUND - rt) / h) - exp((SHADE_R_GROUND - r) / h) * c / ((c - 1.0) * -mu + 1.0)) + deep * 1.5;
}

static inline float shadePhaseR(float mu) { return 0.0596831 * (1.0 + mu * mu); }
static inline float shadePhaseM(float mu, float g) {
	float g2 = g * g;
	return 0.1193662 * (1.0 - g2) * (1.0 + mu * mu) / ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}

static float3 shadeScatter(float3 dir, float3 lightDir, float intensity, float mie, thread float3 &transmittance) {
	float r0 = SHADE_R_GROUND + SHADE_ALTITUDE;
	float b = r0 * dir.y;
	float tEnd = -b + sqrt(max(b * b - r0 * r0 + SHADE_R_TOP * SHADE_R_TOP, 0.0));
	float dg = b * b - r0 * r0 + SHADE_R_GROUND * SHADE_R_GROUND;
	bool ground = dir.y < 0.0 && dg > 0.0;
	if (ground) tEnd = -b - sqrt(dg);
	float mu = dot(dir, lightDir);
	float pr = shadePhaseR(mu), pm = shadePhaseM(mu, SHADE_MIE_G);
	float betaM = SHADE_BETA_M * mie, betaMExt = SHADE_BETA_M_EXT * mie;
	float odR = 0.0, odM = 0.0, tPrev = 0.0;
	float3 sumR = 0.0, sumM = 0.0;
	for (int i = 0; i < SHADE_SAMPLES; i++) {
		float u = float(i + 1) / float(SHADE_SAMPLES);
		float t = tEnd * u * u, dt = t - tPrev, tm = 0.5 * (t + tPrev);
		tPrev = t;
		float3 p = float3(0.0, r0, 0.0) + dir * tm;
		float r = length(p);
		float dR = exp((SHADE_R_GROUND - r) / SHADE_H_R) * dt, dM = exp((SHADE_R_GROUND - r) / SHADE_H_M) * dt;
		float muL = dot(p, lightDir) / r;
		float cR = odR + 0.5 * dR + shadeColumn(r, muL, SHADE_H_R), cM = odM + 0.5 * dM + shadeColumn(r, muL, SHADE_H_M);
		float3 t3 = exp(-(SHADE_BETA_R + SHADE_BETA_O) * cR - betaMExt * cM);
		sumR += t3 * dR;
		sumM += t3 * dM;
		odR += dR;
		odM += dM;
	}
	transmittance = ground ? float3(0.0) : exp(-(SHADE_BETA_R + SHADE_BETA_O) * odR - betaMExt * odM);
	return intensity * (SHADE_BETA_R * pr * sumR + betaM * pm * sumM);
}

static inline float3 shadeGoldenHour(float dirY, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	float h = 1.0 - saturate(abs(dirY));
	return mix(float3(1.0), float3(1.45, 1.02, 0.72), w * (0.55 + 0.45 * h * h * h));
}

static inline float3 shadeSunsetGrade(float3 dir, float3 sun, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	if (w <= 0.0) return float3(1.0);
	float h = 1.0 - saturate(abs(dir.y));
	float dl = dot(dir.xz, dir.xz), sl = dot(sun.xz, sun.xz);
	float toward = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, sun.xz) * rsqrt(dl * sl) * 0.5 + 0.5 : 0.5;
	float band = pow(max(h, 1e-4), mix(9.0, 2.0, toward * toward));
	float3 col = toward > 0.5 ? mix(float3(1.40, 0.97, 0.82), float3(1.50, 0.96, 0.72), pow(toward * 2.0 - 1.0, 2.5))
	                          : mix(float3(1.18, 0.90, 1.06), float3(1.40, 0.97, 0.82), toward * 2.0);
	float glow = pow(saturate(dot(dir, normalize(sun))), 10.0);
	col = mix(col, float3(1.55, 1.0, 0.70), glow * 0.4);
	return mix(float3(1.0), col, w * saturate(0.2 + 0.8 * band + 0.4 * glow));
}

static inline float3 shadeSunsetChroma(float3 sky, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	float mx = max(max(sky.r, sky.g), sky.b), mn = min(min(sky.r, sky.g), sky.b);
	if (w <= 0.0 || mx <= 1e-6) return sky;
	float k = smoothstep(0.55, 1.0, 1.0 - mn / mx) * w;
	float l = dot(sky, float3(0.2126, 0.7152, 0.0722));
	float3 c = (sky - l) * (1.0 - 0.36 * k);
	c.g -= 0.06 * k * max(c.r, 0.0);
	return max(l + c, 0.0);
}

static inline float3 shadeSunsetStretch(float3 dir, float3 sun, float sunY, float rain) {
	float w = (1.0 - smoothstep(0.02, 0.32, sunY)) * smoothstep(-0.16, -0.02, sunY) * (1.0 - rain);
	if (w <= 0.0 || dir.y <= 0.0) return dir;
	float dl = dot(dir.xz, dir.xz), sl = dot(sun.xz, sun.xz);
	float toward = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, sun.xz) * rsqrt(dl * sl) * 0.5 + 0.5 : 0.5;
	float y = pow(dir.y, 1.0 + (mix(1.15, 1.45, toward * toward) - 1.0) * w);
	return float3(dir.xz * sqrt(max(1.0 - y * y, 0.0) / max(dl, 1e-8)), y).xzy;
}

static inline float3 shadeAwaySunset(float3 sky, float3 dir, constant ShadeFrame &f) {
	if (f.zenithColor.w >= 1.0) return sky;
	float dl = dot(dir.xz, dir.xz), sl = dot(f.sunDirWorld.xz, f.sunDirWorld.xz);
	float az = dl > 1e-8 && sl > 1e-8 ? dot(dir.xz, f.sunDirWorld.xz) * rsqrt(dl * sl) : 0.0;
	float k = (1.0 - saturate(f.zenithColor.w)) * (1.0 - smoothstep(-0.2, 0.4, az))
	        * (1.0 - smoothstep(0.02, 0.32, f.sunDirWorld.w)) * smoothstep(-0.16, -0.02, f.sunDirWorld.w) * (1.0 - f.weather.x);
	return mix(sky, float3(shadeLuma(sky)), k);
}

static float3 shadeSkyRadiance(float3 dir, constant ShadeFrame &f, thread float3 &transmittance, bool art = false, bool gradeAway = true) {
	float3 sky = float3(0.0);
	float3 tr = float3(1.0);
	float mie = f.atmosphere.z;
	if (f.sunDirWorld.w > -0.22) sky += shadeScatter(dir, f.sunDirWorld.xyz, f.atmosphere.x, mie, tr);
	if (f.atmosphere.y > 0.0) sky += shadeScatter(dir, f.moonDirWorld.xyz, f.atmosphere.y, mie, tr) * float3(0.85, 0.95, 1.25);
	sky += float3(0.0003, 0.00045, 0.0009) * (1.0 - 0.5 * f.weather.x);
	float rain = f.weather.x;
	float l = shadeLuma(sky);
	sky = max(l + (sky - l) * SHADE_SKY_SATURATION, sky * 0.5);
	sky *= art ? shadeSunsetGrade(dir, f.sunDirWorld.xyz, f.sunDirWorld.w, rain) : shadeGoldenHour(dir.y, f.sunDirWorld.w, rain);
	if (art) sky = shadeSunsetChroma(sky, f.sunDirWorld.w, rain);
	sky = mix(sky, float3(l) * float3(0.92, 0.96, 1.0) * (1.0 - 0.45 * f.weather.y), rain * 0.75) * f.atmosphere.w;
	transmittance = tr;
	return gradeAway ? shadeAwaySunset(sky, dir, f) : sky;
}

static inline float3 shadeHorizon(float3 dir, constant ShadeFrame &f) {
	float2 d = normalize(dir.xz + float2(1e-5, 0.0));
	float x = clamp((d.x + 1.0) * 3.5, 0.0, 6.999);
	int i = int(x);
	return mix(f.horizon[i].xyz, f.horizon[i + 1].xyz, x - float(i));
}

static inline float2 shadeSkyAxis(constant ShadeFrame &f) {
	float2 a = f.sunDirWorld.xz;
	float l = length(a);
	return l > 1e-3 ? a / l : float2(1.0, 0.0);
}

static inline half shadeSkyCurve(half s) { return s / (half(4.0) - half(3.0) * s); }
static inline half shadeBlockCurve(half b) {
	half v = b / (half(4.0) - half(3.0) * b);
	return v * v * (half(0.5) + half(0.5) * v);
}

static inline half shadeVanillaFace(half3 n, int dimension) {
	half3 a = abs(n);
	half up = dimension == SHADE_DIM_NETHER ? half(0.9) : half(1.0), down = dimension == SHADE_DIM_NETHER ? half(0.9) : half(0.5);
	half y = n.y > half(0.0) ? up : down;
	return (a.x * half(0.6) + a.z * half(0.8) + a.y * y) / max(a.x + a.y + a.z, half(1e-3));
}

static inline float shadeNoise(float2 pixel, int frame) {
	pixel += float(frame & 63) * 5.588238;
	return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

static float3 shadeLit(half3 albedo, half3 n, half sky, half block, half shadow, bool thin, bool foliage, constant ShadeFrame &f) {
	half nl = half(dot(float3(n), f.lightDirWorld.xyz));
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl) : foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5) * saturate(-nl) : saturate(nl);
	half gate = f.flags.z != 0 ? smoothstep(half(0.3), half(0.8), sky) : sky * sky * sky * sky;
	half3 direct = half3(f.sunColor.xyz) * (ndl * shadow * gate);
	float2 axis = shadeSkyAxis(f);
	half towardSun = half(dot(float2(n.xz), axis)) * half(0.5) + half(0.5);
	half3 side = mix(half3(f.ambientAway.xyz), half3(f.ambientToward.xyz), towardSun);
	half3 ambient = n.y >= half(0.0) ? mix(side, half3(f.ambientSky.xyz), n.y) : mix(side, half3(f.ambientGround.xyz), -n.y);
	ambient *= shadeSkyCurve(sky) * (foliage ? half(1.35) : half(1.0));
	half3 torch = half3(f.ambientBlock.xyz) * shadeBlockCurve(block);
	if (SHADE_CAMERA_UNDERWATER(f)) {
		direct *= half3(0.22h, 0.5h, 0.62h);
		ambient *= half3(0.35h, 0.62h, 0.8h);
	}
	return float3(albedo) * float3(direct + ambient + torch + half(f.ambientBlock.w));
}

static inline float shadeVanillaFog(float3 p, float2 env, float2 renderDistance) {
	float spherical = length(p), cylindrical = max(length(p.xz), abs(p.y));
	float a = saturate((spherical - env.x) / max(env.y - env.x, 1e-3));
	float b = saturate((cylindrical - renderDistance.x) / max(renderDistance.y - renderDistance.x, 1e-3));
	return max(a, b);
}

#define SHADE_LUT_W 128
#define SHADE_LUT_H 80

static inline float3 shadeLutDirection(float2 uv, constant ShadeFrame &f) {
	float2 axis = shadeSkyAxis(f);
	float phi = 2.0 * asin(saturate(uv.x)), y = uv.y * uv.y, c = sqrt(max(1.0 - y * y, 0.0));
	float2 h = axis * cos(phi) + float2(-axis.y, axis.x) * sin(phi);
	return float3(h.x * c, y, h.y * c);
}

static inline float3 shadeSkyLookup(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f, float uMin = 0.0) {
	float2 axis = shadeSkyAxis(f);
	float2 hz = dir.xz;
	float hl2 = dot(hz, hz);
	float c = hl2 > 1e-8 ? dot(hz, axis) * rsqrt(hl2) : 1.0;
	float u = max(sqrt(saturate(0.5 - 0.5 * c)), uMin);
	float v = sqrt(saturate(dir.y));
	float2 uv = (float2(u, v) * float2(SHADE_LUT_W - 1, SHADE_LUT_H - 1) + 0.5) / float2(SHADE_LUT_W, SHADE_LUT_H);
	float3 sky = float3(lut.sample(s, uv, level(0.0)).rgb);
	return dir.y < 0.0 ? sky * mix(1.0, 0.55, saturate(-dir.y * 3.0)) : sky;
}

static inline float3 shadeFogAir(float3 radiance, float3 p, float vanillaFog, texture2d<half> lut, sampler s, constant ShadeFrame &f) {
	float haze = (1.0 - exp(-length(p) * f.fogSky.z)) * f.fogSky.w;
	float a = max(vanillaFog, haze) * (1.0 - f.fogColor.a);
	if (shadeDev(f, SHADE_DEV_NO_FOG_LUT)) return mix(radiance, f.horizon[4].rgb, a);
	return a > 0.002 ? mix(radiance, shadeSkyLookup(normalize(p), lut, s, f), a) : radiance;
}

static inline float3 shadeFinish(float3 radiance, float vanillaFog, constant ShadeFrame &f) {
	float3 c = shadeOutput(radiance, f);
	float a = vanillaFog * f.fogColor.a;
	float3 t = f.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
	return c * t + f.fogColor.rgb * (1.0 - t);
}

static inline float2 shadeShadowUV(float3 clip) { return float2(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5); }

static inline float shadeShadowCascade(depth2d_array<float> map, sampler cmp, uint layer, float4x4 vp, float3 p, float3 offset,
                                       float texelUv, float spread, thread float &m) {
	float4 c = vp * float4(p + offset, 1.0);
	m = max(abs(c.x), abs(c.y));
	if (c.z <= 0.0 || c.z >= 1.0) m = 2.0;
	if (m >= 1.0) return 1.0;
	float2 uv = shadeShadowUV(c.xyz);
	float h = spread * texelUv;
	float s = map.sample_compare(cmp, uv + float2(-h, -h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(h, -h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(-h, h), layer, c.z);
	s += map.sample_compare(cmp, uv + float2(h, h), layer, c.z);
	return s * 0.25;
}

static half shadeShadow(depth2d_array<float> map, sampler cmp, constant ShadeFrame &f, float3 p, half3 n, bool thin) {
	if (f.flags.z == 0 || shadeDev(f, SHADE_DEV_NO_SHADOW)) return half(1.0);
	float3 L = f.lightDirWorld.xyz;
	float nl = thin ? 1.0 : dot(float3(n), L);
	if (nl <= 0.0) return half(1.0);
#ifndef SHADE_SHADOW_TAN_MAX
#define SHADE_SHADOW_TAN_MAX 30.0
#endif
	float tanT = clamp(sqrt(max(1.0 - nl * nl, 0.0)) / max(nl, 0.02), 0.0, SHADE_SHADOW_TAN_MAX);
#ifndef SHADE_SHADOW_NORMAL_K
#define SHADE_SHADOW_NORMAL_K 2.0
#endif
	float3 dir = thin ? L * 1.5 : float3(n) * SHADE_SHADOW_NORMAL_K + L * (0.5 + 0.75 * tanT);
	float texelUv = f.shadowParams.x;
	float softness = f.shadowParams.w > 0.0 ? f.shadowParams.w : 1.0;
	float m0, m1;
	float near = shadeShadowCascade(map, cmp, 0u, f.shadowViewProj[0], p, dir * f.cascadeSplits.z, texelUv, 0.75 * softness, m0);
	if (m0 < 0.85) return half(near);
	float far = shadeShadowCascade(map, cmp, 1u, f.shadowViewProj[1], p, dir * f.cascadeSplits.w, texelUv, 0.5 * softness, m1);
	far = mix(far, 1.0, smoothstep(0.85, 1.0, m1));
	return half(m0 >= 1.0 ? far : mix(near, far, smoothstep(0.85, 1.0, m0)));
}

#endif
