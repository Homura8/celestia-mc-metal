// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shade_m2.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M2 shading functions (P1: shadows = 1 until P2, clouds/dims/dynlight stubbed until P3/P6).
#ifndef MCOPT_SHADE_M2
#define MCOPT_SHADE_M2

// ---- P1 module stubs (replaced when P3 clouds / P6 dims & dynlights are ported) -----------------------------------------
#ifndef MCOPT_SHADE_CLOUDS
#define SHADE_CLOUD_DEV_NO_SKY 1
#define SHADE_CLOUD_DEV_NO_AP 2
#define SHADE_CLOUD_DEV_NO_FOG 4
#define SHADE_CLOUD_DEV_OLD_FOG 8
#define SHADE_CLOUD_DEV_EARLY_FOG 16
#define SHADE_CLOUD_DEV_AP_SUN 32
static inline bool shadeCloudDev(constant ShadeLook &L, int bit) { (void)L; (void)bit; return false; }
static inline float shadeCloudShadow(float3 p, constant ShadeLook &L, texture2d<half> tex) { (void)p; (void)L; (void)tex; return 1.0; }
static inline float4 shadeCloudsScreen(float3 dir, constant ShadeLook &L, texture2d<half> tex) {
	if (L.clouds0.w > 0.5) {
		float4 clip = L.viewProjNoJitter * float4(dir, 0.0);
		if (clip.w > 1e-4) {
			float2 uv = clip.xy / clip.w * 0.5 + 0.5;
			if (all(uv >= 0.0) && all(uv <= 1.0)) {
				constexpr sampler linear(filter::linear, address::clamp_to_edge);
				return float4(tex.sample(linear, uv, level(0.0)));
			}
		}
	}
	return float4(0.0, 0.0, 0.0, 1.0);
}

static inline float3 shadeAuroraScreen(float3 dir, constant ShadeLook &L, texture2d<half> tex) {
	if (L.night.z > 0.002 && ((int(L.dimTint.w) >> 2) & 2) != 0 && dir.y > 0.015) {
		float4 clip = L.viewProjNoJitter * float4(dir, 0.0);
		if (clip.w > 1e-4) {
			float2 uv = clip.xy / clip.w * 0.5 + 0.5;
			if (all(uv >= 0.0) && all(uv <= 1.0)) {
				constexpr sampler linear(filter::linear, address::clamp_to_edge);
				return float3(tex.sample(linear, uv, level(0.0)).rgb);
			}
		}
	}
	return float3(0.0);
}
static inline float4 shadeCloudsDome(float3 dir, constant ShadeLook &L, texture2d<half> tex) {
	if (L.clouds1.x > 0.5 && dir.y >= 0.0) {
		constexpr sampler linear(filter::linear, s_address::repeat, t_address::clamp_to_edge);
		float2 uv = float2(atan2(dir.z, dir.x) * (1.0 / 6.2831853) + 0.5, sqrt(saturate(dir.y)));
		return float4(tex.sample(linear, uv, level(0.0)));
	}
	return float4(0.0, 0.0, 0.0, 1.0);
}
#endif

#ifndef MCOPT_SHADE_DYNLIGHT
#define SHADE_DYN_TERRAIN 0
#define SHADE_DYN_WATER 1
#define SHADE_DYN_ENTITY 2
#define SHADE_DYN_HAND 3
#define SHADE_DYN_PARTICLE 4
struct ShadeDynIn { float3 p; float3 n; float3 albedo; float2 pixel; half sky; half block; int kind; };
static inline ShadeDynIn shadeDynIn(float3 p, float3 n, float3 albedo, float2 pixel, half sky, half block, int kind) {
	return {p, n, albedo, pixel, sky, block, kind};
}
static inline float3 shadeDynamicLights(ShadeDynIn d, constant ShadeFrame &f, constant ShadeLook &L, constant ShadeResources *R) {
	(void)d; (void)f; (void)L; (void)R;
	return float3(0.0);
}
#endif

// Water dev switches (upstream shade_common.metal parity)
#ifndef SHADE_WDEV_IS
#define SHADE_WDEV_NO_SSR 1
#define SHADE_WDEV_SSR_OLD 2
#define SHADE_WDEV_SSR_THICK 3
#define SHADE_WDEV_SSR_BEHIND 4
#define SHADE_WDEV_SSR_BOTH 5
#define SHADE_WDEV_NO_FOG 6
#define SHADE_WDEV_NO_DETAIL 7
#define SHADE_WDEV_IS(f, k) false
#endif

// ---- small utilities --------------------------------------------------------------------------------------------------
static inline uint shadeHash(uint x) { // lowbias32 (C. Wellons, public domain)
	x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
	return x;
}
static inline float shadeHash01(uint x) { return float(shadeHash(x) >> 8) * (1.0 / 16777216.0); }
static inline uint shadeHash3(int3 c, uint salt) {
	return shadeHash(uint(c.x) * 0x8da6b343u ^ shadeHash(uint(c.y) * 0xd8163841u ^ shadeHash(uint(c.z) * 0xcb1ab31fu ^ salt)));
}
static inline bool shadeFeature(constant ShadeLook &L, int bit) { return (L.tier.y & bit) != 0; }

static inline float shadeHG(float mu, float g) {
	float g2 = g * g;
	float x = max(1.0 + g2 - 2.0 * g * mu, 1e-4);
	return 0.0795775 * (1.0 - g2) / (x * sqrt(x));
}

// ---- output ---------------------------------------------------------------------------------------------------------------
static inline float shadeExposure(constant ShadeFrame &f, constant ShadeGpu &g) {
#ifdef MCOPT_HDR
	return g.exposure.x;
#else
	return f.time.z;
#endif
}

static inline float3 shadeOut(float3 radiance, constant ShadeFrame &f, float ex) {
#ifdef MCOPT_HDR
	return min(max(radiance, 0.0) * ex, 60000.0);
#else
	return shadeOutput(radiance, f);
#endif
}

static inline float3 shadeVanillaOut(float3 srgb, constant ShadeLook &L) {
#ifdef MCOPT_HDR
	return shadeLdrToHdr(srgb, L);
#else
	return srgb;
#endif
}

static inline float3 shadeFinish2(float3 radiance, float vanillaFog, constant ShadeFrame &f, constant ShadeLook &L, float ex) {
#ifdef MCOPT_HDR
	float3 c = shadeOut(radiance, f, ex);
	// (alpha.25) under water shadeFogAir2's physical water fog replaces vanilla's fog colour blend
	float a = f.flags.x == SHADE_DIM_OVERWORLD && SHADE_CAMERA_UNDERWATER(f) ? 0.0 : vanillaFog * f.fogColor.a;
	if (a <= 0.0) return c;
	float3 t = f.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
	return c * t + f.fogColorHdr.rgb * (1.0 - t); // (the fog colour in HDR: converted once per frame on the CPU)
#else
	return shadeFinish(radiance, vanillaFog, f);
#endif
}

// ---- lighting model v2 ----------------------------------------------------------------------------------------------------
static inline float shadeLook2Near(float3 p, constant ShadeLook &L) {
	return L.look2a.w > 0.0 ? 1.0 - smoothstep(0.5 * L.look2a.w, L.look2a.w, length(p)) : 1.0;
}

static float3 shadeLit2(half3 albedo, half3 n, half sky, half block, half shadow, bool thin, bool foliage, constant ShadeFrame &f,
                        constant ShadeLook &L, float look2Near = 1.0) {
	if (!shadeFeature(L, SHADE_FEATURE_LIGHT_V2)) return shadeLit(albedo, n, sky, block, shadow, thin, foliage, f);
	float3 Ld = f.lightDirWorld.xyz;
	half nl = half(dot(float3(n), Ld));
	half ndl = thin ? half(0.3) + half(0.5) * abs(nl)
		: foliage ? half(0.25) + half(0.75) * saturate(nl) + half(0.5 * L.user0.z) * saturate(-nl)
		: (nl > half(0.0) ? (nl + half(0.08)) / half(1.08) : half(0.0));
	half gate = f.flags.z != 0 ? smoothstep(half(0.3), half(0.8), sky) : sky * sky * sky * sky;
	half3 sun = half3(f.sunColor.xyz);
	half3 direct = sun * (ndl * shadow * gate);
	float2 axis = shadeSkyAxis(f);
	half towardSun = half(dot(float2(n.xz), axis)) * half(0.5) + half(0.5);
	half3 side = mix(half3(f.ambientAway.xyz), half3(f.ambientToward.xyz), towardSun);
	half3 ambient = n.y >= half(0.0) ? mix(side, half3(f.ambientSky.xyz), n.y) : mix(side, half3(f.ambientGround.xyz), -n.y);
	half g = shadeSkyCurve(sky);
	ambient *= g * (foliage ? half(1.0 + 0.35 * L.user0.z) : half(1.0)) * half3(L.ambientArt.rgb);
	half3 fill = sun * (half(L.ambientArt.w) * (half(1.0) - shadow * saturate(nl)) * g * g * gate) * half3(L.bounce.rgb);
	half3 torch = half3(0.0h);
	if (block > half(0.0)) {
		half b7 = block * block * block; b7 = b7 * b7 * block;
		half F = (half(2.2) * b7 + half(0.55) * pow(max(block, half(1e-3)), half(2.4))) * half(1.0 / 2.75);
		half day = half(saturate(f.sunDirWorld.w * 4.0 + 0.2));
		torch = half3(f.ambientBlock.xyz) * F * (half(1.0) - half(0.25) * smoothstep(half(0.5), half(1.0), sky) * day);
	}
	half3 minimum = half(f.ambientBlock.w) * mix(half3(0.9h, 1.0h, 1.38h), half3(1.0h), g);
	if (L.user3.x > 0.0) {
		half natural = half(min(L.user3.x, 1.0));
		ambient *= mix(half(1.0), mix(half(0.45), half(0.85), g), natural);
		fill *= mix(half(1.0), mix(half(0.35), half(0.65), g), natural);
		minimum *= mix(half(1.0), half(0.65), natural);
		if (L.user3.x > 1.0) {
			half extra = half(L.user3.x - 1.0);
			ambient *= mix(half(1.0), mix(half(0.65), half(0.90), g), extra);
			fill *= mix(half(1.0), mix(half(0.60), half(0.85), g), extra);
			minimum *= mix(half(1.0), half(0.75), extra);
		}
	}
	if (SHADE_CAMERA_UNDERWATER(f)) {
		direct *= half3(0.22h, 0.5h, 0.62h);
		ambient *= half3(0.35h, 0.62h, 0.8h);
		fill *= half3(0.3h, 0.55h, 0.7h);
	}
	half face = half(1.0) - half(0.06) * abs(n.x) * (half(1.0) - abs(n.y));
	if (L.look2a.y > 0.0 && !thin) face *= half(1.0 - L.look2a.y * look2Near * (1.0 - abs(float(n.y))));
	float3 lit = float3(albedo) * float3((direct + ambient + fill + torch + minimum) * face);
	if ((thin || foliage) && L.look2a.x > 0.0 && !SHADE_CAMERA_UNDERWATER(f))
		lit += float3(sun) * mix(float3(1.0), saturate(float3(albedo) / max(dot(float3(albedo), float3(0.2126, 0.7152, 0.0722)), 0.02)), L.look2a.z)
			* (L.look2a.x * look2Near * float(shadow * gate) * (thin ? 1.0 : 0.5));
	return lit;
}

// ---- caustic focusing (bottom seen through surface or underwater) ----------------------------------------------------
#define SHADE_CAUSTIC_COUNT 6
constant float4 SHADE_CAUSTIC_K[SHADE_CAUSTIC_COUNT] = {
	float4( 0.940,  0.342, 2.41660973, 2.67833043),
	float4(-0.276,  0.961, 2.99199300, 2.97900703),
	float4( 0.454, -0.891, 3.69599135, 3.31190018),
	float4(-0.866, -0.500, 4.58626664, 3.68928179),
	float4( 0.643,  0.766, 5.66052730, 4.09887836),
	float4(-0.985,  0.174, 7.05975876, 4.57597128),
};
constant float3 SHADE_CAUSTIC_A[SHADE_CAUSTIC_COUNT] = {
	float3(0.10512004, 0.2520, 0.0),
	float3(0.13428033, 0.2100, 1.9),
	float3(0.16392423, 0.1680, 3.8),
	float3(0.19982147, 0.1330, 5.7),
	float3(0.24031177, 0.1050, 7.6),
	float3(0.29904116, 0.0840, 9.5),
};

static float shadeCausticFocus(float2 x, float t, float kk, int harmonics = SHADE_CAUSTIC_COUNT) {
	half3 hs = 0.0h;
	for (int i = 0; i < harmonics; i++) {
		float4 w = SHADE_CAUSTIC_K[i];
		float3 a = SHADE_CAUSTIC_A[i];
		float th = w.z * dot(w.xy, x) + w.w * t + a.z;
		float c;
		float s = sincos(th, c);
		half e = exp2(half(s - 1.0) * 1.442695h);
		half q = half(a.x) * half(c * c - s) * e;
		half2 wd = half2(w.xy);
		hs += q * half3(wd.x * wd.x, wd.y * wd.y, wd.x * wd.y);
		x -= w.xy * (c * float(e) * a.y);
	}
	float det = (1.0 + kk * float(hs.x)) * (1.0 + kk * float(hs.y)) - kk * kk * float(hs.z) * float(hs.z);
	return min(1.0 / max(abs(det), 0.18), 4.0);
}

static inline float2 shadeCausticLod(float footprint) {
	return float2(1.0 - 0.7 * smoothstep(0.04, 0.16, footprint), 1.0 - smoothstep(0.16, 0.32, footprint));
}

// ---- height haze, mist and border fog -------------------------------------------------------------------------------------
static inline float shadeLayerDepth(float yc, float dy, float t, float y0, float H) {
	float y1 = yc + dy * t;
	float lo = min(yc, y1), hi = max(yc, y1);
	if (hi <= y0) return t;
	float invH2 = -1.44269504 / H;
	float span = hi - lo;
	if (span < 1e-3 * max(t, 1.0)) return t * exp2(max(0.5 * (yc + y1) - y0, 0.0) * invH2);
	float below = max(y0 - lo, 0.0);
	float a = max(lo, y0);
	float above = H * (exp2((a - y0) * invH2) - exp2((hi - y0) * invH2));
	return (below + above) * (t / span);
}

static float3 shadeHazeInscatterFrom(float3 p, float yc, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T,
                                     thread float3 &Ssun) {
	float t = length(p);
	float3 v = p / max(t, 1e-4);
	float dR = shadeLayerDepth(yc, v.y, t, L.fogMisc.x, L.fogR.w);
	float dM = shadeLayerDepth(yc, v.y, t, L.fogM.z, L.fogM.y);
	float3 tauR = L.fogR.rgb * dR;
	float tauM = L.fogM.x * dM;
	float3 tau = tauR + tauM;
	T = exp(-tau);
	float nu = dot(v, f.lightDirWorld.xyz);
	float phR = 0.0596831 * (1.0 + nu * nu);
#ifndef SHADE_HAZE_MIE_G
#define SHADE_HAZE_MIE_G 0.5
#endif
	float phM = 0.8 * shadeHG(nu, SHADE_HAZE_MIE_G) + 0.2 * shadeHG(nu, -0.2);
	float airSun = shadeAirSun(L);
	float3 E = f.sunColor.rgb * (3.14159265 * sunVis * airSun);
	float3 sky = f.ambientSky.rgb * (0.9 * shadeAirSky(L));
	float glow = 1.0 + L.fogMisc.w;
	float aM = L.fogM.w;
	float3 sR = (E * phR + sky) * (1.0 / (1.0 - 0.5));
	float msGain = L.user4.w > 0.0 ? L.user4.w : 1.0;
	float3 sM = (E * phM * glow * msGain + sky) * aM / (1.0 - 0.5 * aM);
	float3 w = (1.0 - T) / max(tau, 1e-6);
	Ssun = w * E * (tauR * (phR * 2.0) + tauM * (phM * glow * msGain * aM / (1.0 - 0.5 * aM)));
	float cave = (1.0 - airSun) * L.eye.x * f.ambientBlock.w;
	return w * (tauR * sR + tauM * sM) + (1.0 - T) * cave;
}
static float3 shadeHazeInscatterFrom(float3 p, float yc, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T) {
	float3 Ssun;
	return shadeHazeInscatterFrom(p, yc, f, L, sunVis, T, Ssun);
}
static float3 shadeHazeInscatter(float3 p, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T) {
	return shadeHazeInscatterFrom(p, f.cameraBlock.y + f.cameraFract.y, f, L, sunVis, T);
}
static float3 shadeHazeInscatter(float3 p, constant ShadeFrame &f, constant ShadeLook &L, float sunVis, thread float3 &T, thread float3 &Ssun) {
	return shadeHazeInscatterFrom(p, f.cameraBlock.y + f.cameraFract.y, f, L, sunVis, T, Ssun);
}

constant float SHADE_WATER_IOR = 1.333;
constant float SHADE_WATER_SCATTERING = 0.010;
constant float3 SHADE_WATER_EXTINCTION = float3(0.11, 0.040, 0.022) + SHADE_WATER_SCATTERING;

// Water-to-air exit direction and unpolarized Fresnel reflectance. The zero ray marks total internal reflection.
static inline float4 shadeSnellExit(float3 incident, float3 up) {
	float cosI = saturate(dot(incident, up));
	float cosT2 = 1.0 - SHADE_WATER_IOR * SHADE_WATER_IOR * (1.0 - cosI * cosI);
	if (cosT2 <= 0.0) return float4(0.0, 0.0, 0.0, 1.0);
	float cosT = sqrt(cosT2);
	float s = (SHADE_WATER_IOR * cosI - cosT) / (SHADE_WATER_IOR * cosI + cosT);
	float p = (cosI - SHADE_WATER_IOR * cosT) / (cosI + SHADE_WATER_IOR * cosT);
	return float4(incident * SHADE_WATER_IOR + up * (cosT - SHADE_WATER_IOR * cosI), 0.5 * (s * s + p * p));
}

// (alpha.25) Water fog seen from inside the water, after Photon's water_fog_simple (include/fog/simple_fog.glsl at commit 26c2906e,
// MIT, LICENSES/MIT-Photon.txt) with its underwater coefficients: Beer-Lambert extinction per channel over the eye-to-point
// distance, and the sun (forward-scattering phase) and sky light scattered toward the eye inside it, with Jessie's
// multiple-scattering energy. Replaces vanilla's opaque blue fog wall: near things stay clear, the far water turns deep teal.
static inline float3 shadeUnderwaterFog(float3 radiance, float3 p, constant ShadeFrame &f, constant ShadeLook &L) {
	// (alpha.25, clearer than Photon's 0.20 / 0.08 / 0.04 + 0.03 at the owner's request: clean ocean/river water, ~60 blocks of
	// visibility in blue-green, reds still gone after ~10)
	const float3 sigmaT = SHADE_WATER_EXTINCTION;
	const float3 albedo = SHADE_WATER_SCATTERING / sigmaT;
	const float3 ms = 0.84 * albedo;
	float d = length(p);
	float3 T = exp(-sigmaT * d);
	float sky = saturate(L.eye.w);
	float nu = dot(p / max(d, 1e-4), f.lightDirWorld.xyz);
	const float iso = 0.25 / M_PI_F;
	float g = 0.4, gg = g * g, den = 1.0 + gg - 2.0 * g * nu;
	float hg = iso * (1.0 - gg) / (den * sqrt(den));
	// the light has crossed ~3 blocks of water to reach the volume around the eye
	float3 sun = f.sunColor.rgb * M_PI_F * exp(-sigmaT * 3.0) * smoothstep(0.0, 0.25, sky) * (0.7 * hg + 0.3 * iso);
	if (L.vl.z > 0.0) sun = float3(0.0); // (alpha.26) the underwater sunlight pass (vl.metal vlWaterShafts) carries it, with shadows
	float3 amb = (f.ambientSky.rgb * M_PI_F * sky + f.ambientBlock.rgb * 0.25) * iso;
	float3 scatter = (sun + amb) * (1.0 - T) * albedo * (1.0 + ms / (1.0 - ms));
	return radiance * T + scatter;
}

// FogRenderer gives a horizontal render range in blocks. Finish up to one chunk inside it
// so the fade is complete when culling steps across the camera or a diagonal.
static inline bool shadeChunkEdgeEnabled(constant ShadeFrame &f, constant ShadeLook &L) {
	return f.flags.x == SHADE_DIM_OVERWORLD && f.flags.y == 0 && f.fogColor.a == 0.0 && L.fogMisc.z > 0.0
	    && !shadeDev(f, SHADE_DEV_LEGACY_CHUNK_EDGE);
}

static inline float shadeChunkEdgeFade(float3 p, constant ShadeFrame &f, constant ShadeLook &L) {
	if (!shadeChunkEdgeEnabled(f, L)) return 0.0;
	float range = L.fogMisc.z + 8.0;
	float end = max(range - 16.0, range * 0.75);
	float start = end * min(L.fogMisc.y, 0.72);
	return smoothstep(start * start, end * end, dot(p.xz, p.xz));
}

static inline float shadeChunkEdgeDepthFade(float edge) {
	return smoothstep(0.92, 1.0, edge);
}

// Compatibility for world pack overrides. Built-in materials blend to sky with continuous depth coverage.
static inline bool shadeChunkEdgeDiscard(float edge, float2 pixel) {
	return edge > 0.92 && shadeChunkEdgeDepthFade(edge) > shadeNoise(floor(pixel), 0);
}

static float3 shadeSkyBackground(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f,
                                 constant ShadeLook &L, constant ShadeResources &R);

static float3 shadeFogAir2(float3 radiance, float3 p, float vanillaFog, float chunkFade, texture2d<half> lut, sampler s,
                           constant ShadeFrame &f, constant ShadeLook &L, constant ShadeResources &R, float chunkEdge) {
#ifdef MCOPT_HDR
	if (f.flags.x == SHADE_DIM_OVERWORLD && SHADE_CAMERA_UNDERWATER(f)) return shadeUnderwaterFog(radiance, p, f, L);
#endif
	bool border = shadeChunkEdgeEnabled(f, L);
	float fade = chunkEdge;
	bool haze = shadeFeature(L, SHADE_FEATURE_HAZE);
	if (!haze && fade <= 0.002) return shadeFogAir(radiance, p, vanillaFog, lut, s, f);
	float d = length(p);
	float3 v = p / max(d, 1e-4);
	if (!haze) {
		float3 fogged = shadeFogAir(radiance, p, vanillaFog, lut, s, f);
		return mix(fogged, shadeSkyBackground(v, lut, s, f, L, R), fade);
	}
	bool air = f.fogColor.a < 0.5;
	float ap = (1.0 - exp(-d * f.fogSky.z)) * f.fogSky.w * (1.0 - f.fogColor.a);
	bool smoothAir = shadeAirSmooth(L);
	if (smoothAir) ap *= shadeAirSky(L);
	float apMix = smoothAir ? ap * 0.6 * smoothstep(0.002, 0.004, ap) : (ap > 0.002 ? ap * 0.6 : 0.0);
	if (shadeCloudDev(L, SHADE_CLOUD_DEV_NO_AP)) apMix = 0.0;
	float3 skyBehind = float3(0.0);
	// Keep the section-upload fade on the original aerial haze path.
	float edge = border ? chunkFade : 0.0;
	if (air && !border) {
		if (L.fogMisc.z > 0.0) {
			float2 q = p.xz * p.xz;
			float l4 = sqrt(sqrt(dot(q, q)));
			float Rb = L.fogMisc.z;
			edge = max(smoothstep(L.fogMisc.y * Rb, Rb, l4), chunkFade);
		} else {
			edge = vanillaFog;
		}
	}
	bool needSky = apMix > 0.0 || (air && L.fogMisc.z > 0.0 && edge > 0.002);
	if (needSky) {
		float3 vs = float3(v.x, max(v.y, 0.0), v.z);
		skyBehind = shadeSkyLookup(vs, lut, s, f);
	}
	if (apMix > 0.0) radiance = mix(radiance, skyBehind, apMix);
#ifndef MCOPT_HDR
	if (air && (smoothAir || d > 2.0)) {
		float3 T;
		float3 S = shadeHazeInscatter(p, f, L, 1.0, T);
		radiance = radiance * T + S;
	}
#endif
	if (air && edge > 0.002) radiance = mix(radiance, needSky ? skyBehind : shadeSkyLookup(float3(v.x, max(v.y, 0.0), v.z), lut, s, f), edge);
	if (fade > 0.002) radiance = mix(radiance, shadeSkyBackground(v, lut, s, f, L, R), fade);
	return radiance;
}

static inline float3 shadeAerialSunGlow(float3 p, texture2d<half> lut, sampler s, constant ShadeFrame &f, constant ShadeLook &L) {
	if (shadeCloudDev(L, SHADE_CLOUD_DEV_AP_SUN) || shadeCloudDev(L, SHADE_CLOUD_DEV_NO_AP) || !shadeFeature(L, SHADE_FEATURE_HAZE)) return float3(0.0);
	float d = length(p);
	float3 v = p / max(d, 1e-4);
	if (dot(v.xz, shadeSkyAxis(f)) <= 0.0) return float3(0.0);
	float ap = (1.0 - exp(-d * f.fogSky.z)) * f.fogSky.w * (1.0 - f.fogColor.a);
	bool smoothAir = shadeAirSmooth(L);
	if (smoothAir) ap *= shadeAirSky(L);
	float apMix = smoothAir ? ap * 0.6 * smoothstep(0.002, 0.004, ap) : (ap > 0.002 ? ap * 0.6 : 0.0);
	if (apMix <= 0.0) return float3(0.0);
	float3 vs = float3(v.x, max(v.y, 0.0), v.z);
	return apMix * max(shadeSkyLookup(vs, lut, s, f) - shadeSkyLookup(vs, lut, s, f, 0.7071068), 0.0);
}

// ---- sky (stars, Milky Way, moon, sun disc + aureole) -------------------------------------------------------------------
static inline float3 shadeBlackbody(float kelvin) {
	const float3 kLog = float3(34028.05, 37740.20, 44638.94);
	const float3 wLam = float3(0.594726, 1.000000, 2.313734);
	float3 e = exp2(kLog / kelvin) - 1.0;
	float3 b = wLam / e;
	b /= max(dot(b, float3(0.2126, 0.7152, 0.0722)), 1e-30);
	return mix(float3(1.0), b, 0.55);
}

static float3 shadeStars(float3 s, float airmass, float time, float sigmaCells) {
	float3 a = abs(s);
	float2 uv; uint face;
	if (a.x >= a.y && a.x >= a.z) { uv = s.yz / a.x; face = s.x > 0.0 ? 0u : 1u; }
	else if (a.y >= a.z) { uv = s.xz / a.y; face = s.y > 0.0 ? 2u : 3u; }
	else { uv = s.xy / a.z; face = s.z > 0.0 ? 4u : 5u; }
	const float N = 420.0;
	float2 cell = (uv * 0.5 + 0.5) * N;
	float2 base = floor(cell - 0.5);
	float sig2 = sigmaCells * sigmaCells;
	float maxR2 = 9.0 * sig2;
	float inv2Sig2 = -0.72134752 / sig2;
	float t7 = time * 7.0;
	float twAmp = 0.35 * min(airmass, 4.0);
	uint faceSalt = shadeHash(face * 0xcb1ab31fu ^ 0x5bd1e995u);
	float3 sum = float3(0.0);
	for (int j = 0; j < 4; j++) {
		int2 c = int2(base) + int2(j & 1, j >> 1);
		float2 dc = max(abs(cell - (float2(c) + 0.5)) - 0.3, 0.0);
		if (dot(dc, dc) > maxR2) continue;
		uint h = shadeHash(uint(c.x) * 0x8da6b343u ^ shadeHash(uint(c.y) * 0xd8163841u ^ faceSalt));
		if (shadeHash01(h) > 0.07) continue;
		float2 pos = float2(c) + 0.2 + 0.6 * float2(shadeHash01(h ^ 0x68e31da4u), shadeHash01(h ^ 0xb5297a4du));
		float2 dd = cell - pos;
		float r2 = dot(dd, dd);
		if (r2 > maxR2) continue;
		float mag = -1.0 + 7.5 * pow(shadeHash01(h ^ 0x1b56c4e9u), 0.45);
		float flux = exp2(-1.328771 * mag);
		float pick = shadeHash01(h ^ 0x7f4a7c15u);
		float kelvin = pick < 0.55 ? mix(3200.0, 5200.0, pick * (1.0 / 0.55)) : pick < 0.9 ? mix(5200.0, 7500.0, (pick - 0.55) * (1.0 / 0.35))
			: mix(7500.0, 15000.0, (pick - 0.9) * 10.0);
		float ph = t7 + shadeHash01(h ^ 0x2545f491u) * 64.0;
		float pf = floor(ph);
		float tw0 = shadeHash01(h ^ uint(pf)), tw1 = shadeHash01(h ^ uint(pf + 1.0));
		float twinkle = 1.0 + twAmp * (mix(tw0, tw1, ph - pf) - 0.5);
		sum += shadeBlackbody(kelvin) * (flux * twinkle * exp2(r2 * inv2Sig2));
	}
	return sum;
}

static inline float3 shadeMilkyWay(float3 s, texture2d<half> mw) {
	const float ct = 0.4540, st = 0.8910;
	float3 g = float3(s.x, ct * s.y - st * s.z, st * s.y + ct * s.z);
	float lon = atan2(g.y, g.x), lat = asin(clamp(g.z, -1.0, 1.0));
	constexpr sampler lin(filter::linear, address::repeat);
	return float3(mw.sample(lin, float2(lon * 0.1591549 + 0.5, lat * 0.3183099 + 0.5), level(0.0)).rgb);
}

static float3 shadeMoonDisc(float2 q, float3 md, float3 pole, float phase) {
	(void)md; (void)pole;
	float r2 = dot(q, q);
	float mu = sqrt(max(1.0 - r2, 0.0));
	float3 nrm = float3(q, mu);
	float3 ls = float3(sin(phase), 0.0, cos(phase));
	float mu0 = dot(nrm, ls);
	float2 sp = float2(atan2(nrm.x, nrm.z), asin(clamp(nrm.y, -1.0, 1.0)));
	float maria = 0.0;
	maria += smoothstep(0.55, 0.15, length(sp - float2(-0.35, 0.25)));
	maria += 0.8 * smoothstep(0.45, 0.1, length(sp - float2(0.25, 0.35)));
	maria += 0.7 * smoothstep(0.40, 0.05, length(sp - float2(0.05, -0.2)));
	maria += 0.5 * smoothstep(0.30, 0.05, length(sp - float2(-0.55, -0.35)));
	float albedo = mix(0.17, 0.09, saturate(maria));
	float2 cg = sp * 7.0;
	float2 ci = floor(cg);
	for (int j = 0; j < 4; j++) {
		float2 c = ci + float2(j & 1, j >> 1) - 0.5;
		uint h = shadeHash3(int3(int2(c), 7), 0x9e3779b9u);
		float2 center = c + 0.5 + 0.4 * (float2(shadeHash01(h), shadeHash01(h ^ 0x85ebca6bu)) - 0.5);
		float rad = 0.12 + 0.25 * shadeHash01(h ^ 0xc2b2ae35u);
		float d = length(cg - center) / rad;
		albedo *= d < 1.0 ? mix(0.82, 1.0, d * d) : 1.0 + 0.25 * exp(-(d - 1.0) * (d - 1.0) * 30.0);
	}
	float lit = mu0 > 0.0 ? mu0 / (mu0 + max(mu, 0.05)) : 0.0;
	float earthshine = 0.012;
	float limb = smoothstep(1.0, 0.97, sqrt(r2));
	return float3(albedo * (lit * 3.2 + earthshine)) * limb;
}

static float3 shadeSkyRadiance2(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f, constant ShadeLook &L,
                                texture2d<half> milkyWay, float pixelAngle) {
	if (shadeDev(f, SHADE_DEV_FLAT_SKY)) return float3(0.3, 0.5, 0.8);
	float3 sky = shadeSkyLookup(dir, lut, s, f);
	float rain = f.weather.x;
	float above = smoothstep(-0.03, 0.01, dir.y);
	float3 sd = f.sunDirWorld.xyz;
	float cosA = dot(dir, sd);
	float sunUp = smoothstep(-0.12, 0.0, sd.y);
	if (sunUp > 0.0 && f.sunColor.w >= 0.0) {
		float3 sunLight = f.lightDirWorld.w > 0.5 ? f.sunColor.rgb : float3(0.0);
		float aureole = (shadeHG(cosA, 0.85) - shadeHG(cosA, 0.6)) * 0.35 * f.atmosphere.z * (1.0 - 0.7 * rain);
		sky += sunLight * max(aureole, 0.0) * above;
		float rs = L.sunGeom.y;
		if (cosA > 0.99 && L.user4.y < 0.5) {
			float ang = acos(clamp(cosA, -1.0, 1.0));
			float rho = ang / rs;
			if (rho < 1.3) {
				float w = 1.5 * pixelAngle / rs;
				float mu = sqrt(saturate(1.0 - rho * rho));
				float3 u = float3(0.40, 0.55, 0.70), v = float3(0.25, 0.20, 0.12);
				float3 I = 1.0 - u * (1.0 - mu) - v * (1.0 - mu) * (1.0 - mu);
				float edge = smoothstep(1.0 + w, 1.0 - w, rho);
				sky += sunLight * (160.0 * (1.0 - 0.9 * rain)) * I * edge * above;
			}
		}
	}
	bool procedural = shadeFeature(L, SHADE_FEATURE_STARS);
	float night = L.night.x;
	if (procedural && dir.y > -0.03 && (night > 0.0 || dot(dir, f.moonDirWorld.xyz) > 0.999)) {
		float3 st = float3(dot(L.celestial[0].xyz, dir), dot(L.celestial[1].xyz, dir), dot(L.celestial[2].xyz, dir));
		float clear = (1.0 - rain) * above;
		float airmass = 1.0 / max(dir.y, 0.05);
		float ext = exp(-0.12 * min(airmass, 12.0));
		float3 behind = float3(0.0);
		if (night > 0.0 && clear > 0.0) {
			float sigma = clamp(0.7 * pixelAngle / (1.5707963 / 420.0), 0.25, 0.8);
			float3 stars = shadeStars(st, airmass, f.time.y, sigma);
			float3 mw = L.night.y > 0.001 ? shadeMilkyWay(st, milkyWay) * L.night.y : float3(0.0);
			behind = (stars * 0.9 + mw) * (night * clear * ext);
		}
		float cover = 0.0;
		float3 moonLight = float3(0.0);
		float3 md = f.moonDirWorld.xyz;
		float rm = L.sunGeom.z;
		float cm = dot(dir, md);
		if (cm > cos(rm * 1.2)) {
			float3 up = normalize(L.celestial[2].xyz - md * dot(L.celestial[2].xyz, md));
			float3 right = cross(up, md);
			float2 q = float2(dot(dir, right), dot(dir, up)) / sin(rm);
			if (dot(q, q) < 1.0) {
				float3 moon = shadeMoonDisc(q, md, up, L.night.w) * float3(0.92, 0.96, 1.05);
				float moonUp = smoothstep(-0.02, 0.02, md.y);
				cover = moonUp * (1.0 - smoothstep(0.9, 1.0, length(q)));
				moonLight = moon * 0.9 * (1.0 - 0.85 * rain);
			}
		}
		sky += behind * (1.0 - cover) + moonLight * cover;
	}
	return sky;
}

// The terrain at full fade uses the same sky, cloud coverage and lightning as the sky pass.
static float3 shadeSkyBackground(float3 dir, texture2d<half> lut, sampler s, constant ShadeFrame &f,
                                 constant ShadeLook &L, constant ShadeResources &R) {
#ifdef MCOPT_HDR
	float4 clouds = shadeCloudDev(L, SHADE_CLOUD_DEV_NO_SKY) ? float4(0.0, 0.0, 0.0, 1.0) : shadeCloudsScreen(dir, L, R.cloudScreen);
	float3 sky = clouds.rgb;
	if (clouds.a > 0.001) {
		float pixelAngle = 2.0 * atan(1.0 / max(abs(f.proj[1][1]), 1e-3)) * f.screen.w;
		float3 back = shadeSkyRadiance2(dir, lut, s, f, L, R.milkyWay, pixelAngle);
		if (L.night.z > 0.002 && !shadeDev(f, SHADE_DEV_FLAT_SKY)) back += shadeAuroraScreen(dir, L, R.aurora);
		sky += back * clouds.a;
	}
	if (L.flash.w > 0.0) {
		float3 fl = float3(0.78, 0.86, 1.0) * (L.flash.w * 0.35 * (0.35 + 0.65 * pow(saturate(dot(dir, L.flash.xyz) * 0.5 + 0.5), 3.0)));
		sky += fl * (L.clouds0.w > 0.5 ? 0.4 + 0.6 * (1.0 - clouds.a) : 1.0);
	}
#else
	float pixelAngle = 2.0 * atan(1.0 / max(abs(f.proj[1][1]), 1e-3)) * f.screen.w;
	float3 sky = shadeSkyRadiance2(dir, lut, s, f, L, R.milkyWay, pixelAngle);
	if (L.flash.w > 0.0)
		sky += float3(0.78, 0.86, 1.0) * (L.flash.w * 0.35 * (0.35 + 0.65 * pow(saturate(dot(dir, L.flash.xyz) * 0.5 + 0.5), 3.0)));
#endif
	return sky;
}

#endif
