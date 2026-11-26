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
static inline float4 shadeCloudsScreen(float3 dir, constant ShadeLook &L, texture2d<half> tex) { (void)dir; (void)L; (void)tex; return float4(0.0, 0.0, 0.0, 1.0); }
static inline float4 shadeCloudsDome(float3 dir, constant ShadeLook &L, texture2d<half> tex) { (void)dir; (void)L; (void)tex; return float4(0.0, 0.0, 0.0, 1.0); }
#endif

#ifndef MCOPT_SHADE_DIMS
#define SHADE_FEATURE_DIMS 0
#define SHADE_FEATURE_MEDIA 0
#define SHADE_FEATURE_SHIMMER 0
#define SHADE_DIMS_AURORA_TEX 1
#define SHADE_DIMS_MOTES 2
#define SHADE_DIMS_DH_SKY 4
static inline bool shadeDimsLit(constant ShadeFrame &f) { (void)f; return false; }
static inline bool shadeDimsBit(constant ShadeLook &L, int bit) { (void)L; (void)bit; return false; }
static inline int shadeDimKind(constant ShadeLook &L) { (void)L; return 0; }
static inline half3 shadeDimsMote(half3 a) { return a; }
static inline float3 shadeLitDims(half3 albedo, half3 n, half block, half shadow, bool thin, bool foliage, float3 p, constant ShadeFrame &f, constant ShadeLook &L) {
	(void)n; (void)block; (void)shadow; (void)thin; (void)foliage; (void)p; (void)f; (void)L;
	return float3(albedo);
}
static inline float3 shadeAurora(float3 dir, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> mw, float2 px) { (void)dir; (void)f; (void)L; (void)mw; (void)px; return float3(0.0); }
static inline float3 shadeAuroraTex(float3 dir, constant ShadeFrame &f, constant ShadeResources &sr, float2 px) { (void)dir; (void)f; (void)sr; (void)px; return float3(0.0); }
static inline float2 shadeShimmer(float2 uv, float dist, constant ShadeFrame &f, texture2d<half> mw) { (void)uv; (void)dist; (void)f; (void)mw; return float2(0.0); }
static inline float3 shadeEndSky(float3 dir, constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> mw, float pa) { (void)dir; (void)f; (void)L; (void)mw; (void)pa; return float3(0.0); }
static inline float3 shadeDimsFog(float3 c, float3 wp, bool hasD, constant ShadeFrame &f, constant ShadeLook &L, float ex, bool dh, texture2d<half> mw) {
	(void)wp; (void)hasD; (void)f; (void)L; (void)ex; (void)dh; (void)mw; return c;
}
static inline float3 shadeMedia(float3 c, float2 uv, float dist, constant ShadeFrame &f, texture2d<half> mw) { (void)uv; (void)dist; (void)f; (void)mw; return c; }
static inline float shadeDimsBakeNoise(float2 uv) { (void)uv; return 0.5; }
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
	float a = vanillaFog * f.fogColor.a;
	if (a <= 0.0) return c;
	float3 t = f.flags.y == 1 ? pow(1.0 - a, float3(2.6, 1.25, 1.0)) : float3(1.0 - a);
	return c * t + shadeLdrToHdr(f.fogColor.rgb, L) * (1.0 - t);
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

static float3 shadeFogAir2(float3 radiance, float3 p, float vanillaFog, float chunkFade, texture2d<half> lut, sampler s,
                           constant ShadeFrame &f, constant ShadeLook &L, constant ShadeResources *R = nullptr, bool leanFog = false) {
	if (!shadeFeature(L, SHADE_FEATURE_HAZE)) return shadeFogAir(radiance, p, vanillaFog, lut, s, f);
	float d = length(p);
	float3 v = p / max(d, 1e-4);
	bool air = f.fogColor.a < 0.5;
	float ap = (1.0 - exp(-d * f.fogSky.z)) * f.fogSky.w * (1.0 - f.fogColor.a);
	bool smoothAir = shadeAirSmooth(L);
	if (smoothAir) ap *= shadeAirSky(L);
	float apMix = smoothAir ? ap * 0.6 * smoothstep(0.002, 0.004, ap) : (ap > 0.002 ? ap * 0.6 : 0.0);
	if (shadeCloudDev(L, SHADE_CLOUD_DEV_NO_AP)) apMix = 0.0;
	if (leanFog) {
		if (apMix > 0.0) {
			float3 skyBehind = shadeSkyLookup(float3(v.x, max(v.y, 0.0), v.z), lut, s, f);
			radiance = mix(radiance, skyBehind, apMix);
		}
#ifndef MCOPT_HDR
		if (air && (smoothAir || d > 2.0)) {
			float3 T;
			float3 S = shadeHazeInscatter(p, f, L, 1.0, T);
			radiance = radiance * T + S;
		}
#endif
		return radiance;
	}
	float3 skyBehind = float3(0.0);
	float edge = 0.0;
	if (air) {
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
		(void)R;
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

#endif
