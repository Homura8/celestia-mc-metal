// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/weather_surface.metal
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
static inline float2 shadeWxXZ(float2 rel, constant ShadeFrame &f) {
	return rel + f.cameraFract.xz + fmod(f.cameraBlock.xz, 4096.0);
}

static inline float shadeWxHash(int2 c, uint salt) {
	return shadeHash01(shadeHash(uint(c.x) * 0x8da6b343u ^ shadeHash(uint(c.y) * 0xd8163841u ^ salt)));
}

// Value noise (smooth, 0..1) over cells of size 1 in x, wrapping every mask + 1 cells.
static inline float shadeWxValue(float2 x, int mask, uint salt) {
	float2 i = floor(x), u = x - i;
	u = u * u * (3.0 - 2.0 * u);
	int2 c = int2(i);
	float a = shadeWxHash(c & mask, salt), b = shadeWxHash((c + int2(1, 0)) & mask, salt);
	float d = shadeWxHash((c + int2(0, 1)) & mask, salt), e = shadeWxHash((c + int2(1, 1)) & mask, salt);
	return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
}

// The puddle field: puddles 2-6 blocks across (8-block cells), lobes (4) and ragged rims (2), on a 32-block swell that makes
// some stretches of ground wetter than others. About 0.5 on average (std 0.14): threshold 0.6 covers ~30 % of open ground.
// Every lattice wraps every SHADE_WX_NOISE_TILE (256) blocks, so the field can be baked into one tile (shade_wx_noise_fs).
#define SHADE_WX_NOISE_TILE 256.0
#define SHADE_WX_NOISE_SIZE 1024
static inline float shadeWxPuddleField(float2 xa) {
	// (the swell's seed was picked so the bench's rain pose has puddles in view: 37 % of the ground there, 31 % on average)
	float big = shadeWxValue(xa * (1.0 / 32.0), 7, 0xfbb04194u);
	return 0.5 * shadeWxValue(xa * 0.125, 31, 0x51ed270bu) + 0.3 * shadeWxValue(xa * 0.25, 63, 0x2c1b3c6du)
		+ 0.2 * shadeWxValue(xa * 0.5, 127, 0x297a2d39u) + 0.25 * (big - 0.5);
}

// Snow drifts: patchy, with the puddle field's hollows filling first.
static inline float shadeWxSnowDrift(float2 xa) {
	return shadeWxValue(xa * 0.5, 127, 0x1f83d9abu) * 0.6 + shadeWxPuddleField(xa + 37.0) * 0.4;
}

// The bake (ShadeWeather.bakeNoise, once): r = puddle field, g = snow drift over one 256-block tile, 4 texels per block
// (RG16F 1024^2, 4 MB). The terrain samples it bilinearly (repeat) instead of evaluating 6 value noises (24 hashes) per pixel.
// Only in the bake's own library (SHADE_WX_NOISE_BAKE): the terrain libraries don't carry the extra entry point.
#ifdef SHADE_WX_NOISE_BAKE
fragment half4 shade_wx_noise_fs(float4 pos [[position]]) {
	float2 xa = pos.xy * (SHADE_WX_NOISE_TILE / float(SHADE_WX_NOISE_SIZE));
	return half4(half(shadeWxPuddleField(xa)), half(shadeWxSnowDrift(xa)), 0.0h, 1.0h);
}
#endif

constexpr sampler shadeWxRepeat(filter::linear, address::repeat, coord::normalized);

// Sky light limits the wet film and snow to exposed faces.
static float2 shadeWetSurface(thread half3 &albedo, float3 p, half3 normal, half sky, bool foliage,
                              constant ShadeFrame &f, constant ShadeLook &L, texture2d<half> noise) {
	float open = smoothstep(0.86, 1.0, float(sky));
	if (open <= 0.0 || normal.y < -0.5h) return 0.0;
	float up = smoothstep(0.5, 0.95, float(normal.y));
	float wet = saturate(L.wet.x * open * mix(0.55, 1.0, up));
	float2 field = float2(noise.sample(shadeWxRepeat, shadeWxXZ(p.xz, f) / SHADE_WX_NOISE_TILE, level(0.0)).rg);
	float puddle = up * open * (foliage ? 0.0 : L.wet.y) * smoothstep(0.57, 0.65, field.x);
	float snow = up * open * smoothstep(0.35, 0.77, field.y + 0.5 * L.wet.z) * L.wet.z;
	albedo = mix(albedo * half(1.0 - 0.26 * wet - 0.18 * puddle), half3(0.72h, 0.80h, 0.9h), half(snow));
	return float2(wet * (1.0 - snow), puddle * (1.0 - snow));
}

static float3 shadeWetLight(float3 radiance, float2 wet, float3 p, half3 n, half shadow,
                             constant ShadeFrame &f, texture2d<half> lut, sampler lutSampler) {
	float3 normal = float3(n);
	float3 v = normalize(p - shadeEye(f.invViewProj));
	float3 ray = reflect(v, normal);
	ray.y = abs(ray.y);
	float fresnel = 0.02 + 0.98 * powr(saturate(1.0 + dot(v, normal)), 5.0);
	float sunGlint = powr(saturate(dot(ray, f.lightDirWorld.xyz)), mix(32.0, 160.0, wet.y));
	float film = max(wet.x * 0.25, wet.y);
	return mix(radiance, shadeSkyLookup(ray, lut, lutSampler, f), fresnel * film)
	     + f.sunColor.rgb * (sunGlint * fresnel * film * float(shadow));
}

#ifdef SHADE_RIPPLES
// ---- raindrop ripples -----------------------------------------------------------------------------------------------------
// Two staggered grids of 0.7-block cells; each cell gets a drop every 0.55-1.05 s (fewer in light rain), at a random point
// of its central half, which spreads a ring at 0.42 blocks/s that fades in about half a second and never leaves the cell.
// Ring profile: a damped sine packet around the radius rho, h = a sin(2 pi e / lambda) exp(-(e / w)^2), e = r - rho; the
// slope comes from its analytic derivative. Returns the height gradient (dh/dx, dh/dz) in blocks per block.
#define SHADE_RIPPLE_CELL 0.7
#ifndef SHADE_RIPPLE_LAYERS
#define SHADE_RIPPLE_LAYERS 2
#endif
static float2 shadeWxRipples(float2 xa, float t, float rate, float footprint) {
	float2 g = float2(0.0);
	// farther away the rings widen with the pixel footprint (a band-limited ring instead of an aliasing one), weaker by the
	// same factor so the slope energy stays comparable
	float widen = max(1.0, footprint * (1.0 / 0.011));
	const float C = SHADE_RIPPLE_CELL;
	float lambda = 0.075 * widen, wid = 0.055 * widen, k = 6.2831853 / lambda;
	for (int layer = 0; layer < SHADE_RIPPLE_LAYERS; layer++) {
		float2 q = xa * (1.0 / C) + (layer == 0 ? float2(0.0) : float2(0.5, 0.37));
		float2 ci = floor(q);
		float2 lp = (q - ci) * C;
		uint h = shadeHash3(int3(int2(ci) & 8191, layer), 0x6a09e667u);
#if SHADE_RIPPLE_LAYERS < 2
		float period = 0.33 + 0.28 * shadeHash01(h); // one grid (performance, balanced): drops come faster, about as many rings
#else
		float period = 0.45 + 0.4 * shadeHash01(h);
#endif
		float ph = t / period + shadeHash01(h ^ 0xbb67ae85u);
		float n = floor(ph);
		float age = (ph - n) * period;
		uint hk = shadeHash(h ^ (uint(int(n)) * 0x9e3779b9u));
		if (shadeHash01(hk) > rate) continue;
		float2 c0 = (0.3 + 0.4 * float2(shadeHash01(hk ^ 0x3c6ef372u), shadeHash01(hk ^ 0xa54ff53au))) * C;
		float2 d = lp - c0;
		float r = length(d);
		float e = r - age * 0.42;
		// (2.0.1 opt) Gaussian envelope is < 0.002 beyond 2.5*wid: skip exp + sincos completely!
		if (abs(e) > 2.5 * wid) continue;
		float invW2 = 1.0 / (wid * wid);
		float env = exp2((-age * 5.0 - e * e * invW2) * 1.44269504) * (1.0 - smoothstep(0.2 * C, 0.29 * C, r));
		float s;
		float c = sincos(k * e, s);
		float dh = env * (k * c - 2.0 * e * invW2 * s);
		g += dh * d / max(r, 1e-4);
	}
	return g * (0.0055 / widen);
}
#endif
