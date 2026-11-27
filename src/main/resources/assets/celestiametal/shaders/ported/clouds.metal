// Celestia volumetric clouds (alpha.25): Photon-style cumulus, rewritten for Apple GPUs.
//
// Copyright 2026 Celestia Metal contributors. Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// The cumulus layer's density model, light and sky optical depth marches, multiple-scattering octaves, powder term and phase
// lobes are adapted from Photon Shaders (https://github.com/sixthsurge/photon) include/sky/clouds/{common,cumulus}.glsl at
// commit 26c2906e, Copyright (c) 2025 Benjamin Stott ("sixthsurge"), MIT License (LICENSES/MIT-Photon.txt), as are the noise
// textures it reads (assets/celestiametal/textures/clouds). Photon's later releases are under a different licence and are not
// used here.
//
// Apple GPU notes (what differs from upstream):
// - The 3D noises live in tiled 2D atlases (ShadeCloudNoise): two bilinear taps per lookup, no 3D texture state.
// - Rays are traced at a quarter of the screen's pixels, one cell of a 2x2 checkerboard per frame (shade_cloud_trace), and
//   shade_cloud_resolve rebuilds a half-resolution image from them and the reprojected history: about Photon's
//   CLOUDS_TEMPORAL_UPSCALING 2 work per frame, with history accumulation hiding the dithered march's noise.
// - The light and sky optical depth marches skip the fine Worley octave (its weight there is Photon's PREPARE value, 0.5) and
//   the curl warp, and run on every other in-cloud sample (reused for the next: the path to the sun changes slowly along a
//   view ray); the scattering sum runs 6 octaves instead of 8.
// - The march works in camera-relative metres above the surface (precision), with one fmod'ed world offset per frame.

#define CLOUD_SCALE 10.0         // Photon's CLOUDS_SCALE: cloud space metres per block
#define CLOUD_PLANET_R 6371e3
#define CLOUD_SEA_LEVEL 63.0
#define CLOUD_MIN_T 0.075
#define CLOUD_MAX_RAY 2e4
#define CLOUD_ISO (0.25 / M_PI_F)

constexpr sampler cloudWrap(filter::linear, address::repeat);
constexpr sampler cloudClamp(filter::linear, address::clamp_to_edge);

struct CloudLayer {
	float radius, top, thickness; // the shell's inner and outer radius and its thickness (m)
	float2 coverage;              // daily weather's cumulus coverage (min, max)
	float stratus;
	float2 detail;                // Worley detail weights
	float2 sharpen;               // edge sharpening exponents (bottom, top)
	float dynThick;
	float extinction, scattering;
	float2 offset;                // the world's xz in cloud space (camera + wind, m)
	float3 wind3;                 // wind displacement (m), for the detail noises' own drift
};

static CloudLayer cloudLayer(constant ShadeFrame &f, constant ShadeLook &L) {
	CloudLayer c;
	float base = max(L.clouds0.x - CLOUD_SEA_LEVEL, 40.0) * CLOUD_SCALE; // vanilla's cloud height as the cumulus base
	c.thickness = base;                                                // (CLOUDS_CUMULUS_THICKNESS 1.0)
	c.radius = CLOUD_PLANET_R + base;
	c.top = c.radius + c.thickness;
	float rain = saturate(f.weather.x);
	c.coverage = mix(float2(0.40, 0.55), float2(0.60, 0.80), rain) * L.clouds0.y; // fair weather, toward overcast in rain
	c.stratus = saturate(0.7 * rain);
	c.detail = mix(float2(0.33, 0.40), float2(0.25, 0.20), c.stratus * c.stratus);
	c.sharpen = mix(float2(3.0, 8.0), float2(1.0, 2.0), c.stratus);
	c.dynThick = mix(0.5, 1.0, smoothstep(0.4, 0.6, c.coverage.y));
	c.extinction = mix(0.05, 0.1, smoothstep(0.0, 0.3, abs(f.sunDirWorld.y))) * (1.0 - 0.33 * rain) * L.clouds1.z;
	c.scattering = c.extinction * mix(1.0, 0.66, rain);
	const float windAngle = 30.0 * M_PI_F / 180.0;
	float2 wind = 40.0 * float2(cos(windAngle), sin(windAngle)) * L.clouds1.w;
	c.wind3 = float3(wind.x, 0.0, wind.y);
	c.offset = fmod(f.cameraBlock.xz + f.cameraFract.xz, 50000.0) * CLOUD_SCALE + wind;
	return c;
}

// Photon's 3D noises from their atlases (ShadeCloudNoise): p in periods (1 = one tile), wraps.
static inline float cloudWorley(texture2d<half> tex, float3 p) {
	float3 q = fract(p) * 64.0;
	float z = q.z - 0.5, zi = floor(z);
	int z0 = int(zi) & 63, z1 = (z0 + 1) & 63;
	float2 xy = q.xy + 1.0;
	const float inv = 1.0 / 528.0;
	float a = tex.sample(cloudClamp, (float2(z0 & 7, z0 >> 3) * 66.0 + xy) * inv).r;
	float b = tex.sample(cloudClamp, (float2(z1 & 7, z1 >> 3) * 66.0 + xy) * inv).r;
	return mix(a, b, z - zi);
}

static inline float3 cloudCurl(texture2d<half> tex, float3 p) {
	float3 q = fract(p) * 32.0;
	float z = q.z - 0.5, zi = floor(z);
	int z0 = int(zi) & 31, z1 = (z0 + 1) & 31;
	float2 xy = q.xy + 1.0;
	const float2 inv = 1.0 / float2(272.0, 136.0);
	float3 a = float3(tex.sample(cloudClamp, (float2(z0 & 7, z0 >> 3) * 34.0 + xy) * inv).rgb);
	float3 b = float3(tex.sample(cloudClamp, (float2(z1 & 7, z1 >> 3) * 34.0 + xy) * inv).rgb);
	return mix(a, b, z - zi);
}

static inline float cloudLinearStep(float a, float b, float x) { return saturate((x - a) / (b - a)); }
static inline float cloudDampen(float x) { x = saturate(x); return x * (2.0 - x); }
static inline float cloudLift(float x, float k) { return (x + x * k) / (1.0 + x * k); }

static inline float cloudHG(float nu, float g) {
	float gg = g * g;
	float d = 1.0 + gg - 2.0 * g * nu;
	return CLOUD_ISO * (1.0 - gg) / (d * sqrt(d));
}
static inline float cloudKleinNishina(float nu, float e) {
	return e / (2.0 * M_PI_F * (e - e * nu + 1.0) * log(2.0 * e + 1.0));
}
static inline float cloudPhaseSingle(float nu) {
	return 0.8 * max(cloudKleinNishina(nu, 2600.0), cloudHG(nu, 0.8)) + 0.2 * cloudHG(nu, -0.2);
}
static inline float cloudPhaseMulti(float nu, float3 g) {
	return 0.65 * cloudHG(nu, g.x) + 0.10 * cloudHG(nu, g.y) + 0.25 * cloudHG(nu, -g.z);
}

// pos: from the planet's centre (m, camera-relative xz). detail: the fine Worley octave (the primary march only).
static float cloudDensity(float3 pos, thread const CloudLayer &c, texture2d<half> n2d, texture2d<half> worley,
                          texture2d<half> curl, bool detail) {
	float r = length(pos);
	if (r < c.radius || r > c.top) return 0.0;
	float alt = 0.8 * (r - c.radius) / (c.thickness * c.dynThick);
	float2 xz = pos.xz + c.offset;
	float cover = float(n2d.sample(cloudWrap, 0.000002 * xz).r);
	float shape = float(n2d.sample(cloudWrap, 0.000027 * xz).a);
	float cu = mix(c.coverage.x, c.coverage.y, cover);
	cu = cloudLinearStep(1.0 - cu, 1.0, shape);
	float st = cloudLinearStep(0.30, 0.70, cover) * cloudLinearStep(0.10, 0.90, shape);
	float d = mix(cu, st, c.stratus);
	d -= smoothstep(0.2, 1.0, alt) * 0.6; // the egg shape
	d *= smoothstep(0.0, 0.2, alt);
	if (d < 1e-4) return 0.0;

	float3 p = float3(xz.x, r - CLOUD_PLANET_R, xz.y);
	// (the light marches skip the curl warp: it moves fine edges, not how much light gets through)
	float3 cl = detail ? 0.181 * cloudCurl(curl, 0.002 * p) * smoothstep(0.4, 1.0, 1.0 - alt) : float3(0.0);
	float w0 = cloudWorley(worley, (p + 0.2 * c.wind3) * 0.001 + cl);
	float w1 = detail ? cloudWorley(worley, (p + 0.4 * c.wind3) * 0.005 + cl * 3.0) : 0.5;
	float fade = 0.20 * smoothstep(0.85, 1.0, 1.0 - alt) - 0.35 * smoothstep(0.05, 0.5, alt) + 0.6;
	d -= c.detail.x * w0 * w0 * cloudDampen(1.0 - d);
	d -= c.detail.y * w1 * w1 * cloudDampen(1.0 - d) * fade;
	d = max(d, 0.0);
	d = 1.0 - pow(1.0 - d, mix(c.sharpen.x, c.sharpen.y, alt)); // wispy bottoms, hard tops
	return d * (0.1 + 0.9 * smoothstep(0.2, 0.7, alt));
}

static float cloudOpticalDepth(float3 o, float3 dir, thread const CloudLayer &c, texture2d<half> n2d, texture2d<half> worley,
                               texture2d<half> curl, float dither, int steps) {
	float4 st = float4(dir, 1.0) * (0.1 * c.thickness / float(steps));
	float3 pos = o;
	float od = 0.0;
	for (int i = 0; i < steps; i++) {
		st *= 2.0;
		od += cloudDensity(pos + st.xyz * dither, c, n2d, worley, curl, false) * st.w;
		pos += st.xyz;
	}
	return od;
}

// x: direct light, y: skylight (Photon's clouds_cumulus_scattering without the altocumulus terms)
static float2 cloudScattering(float density, float lightOd, float skyOd, float groundOd, thread const CloudLayer &c,
                              float stepT, float nu, float bounced) {
	float2 s = 0.0;
	float scatter = c.scattering, extinct = c.extinction;
	float integral = (1.0 - stepT) / c.extinction;
	float powder = M_PI_F * density / (density + 0.15);
	powder = mix(powder, 1.0, 0.8 * (nu * 0.5 + 0.5) * (nu * 0.5 + 0.5));
	float phase = cloudPhaseSingle(nu);
	float3 g = pow(float3(0.6, 0.9, 0.3), float3(1.0 + lightOd));
	float spread = 0.55 * mix(cloudLift(saturate(c.scattering / 0.1), 0.33), 1.0, nu * 0.5 + 0.5);
	for (int i = 0; i < 6; i++) {
		s.x += scatter * exp(-extinct * lightOd) * phase;
		s.x += scatter * exp(-extinct * groundOd) * CLOUD_ISO * bounced;
		s.y += scatter * exp(-extinct * skyOd) * CLOUD_ISO;
		scatter *= spread * powder;
		extinct *= 0.4;
		g *= 0.8;
		powder = mix(powder, sqrt(powder), 0.5);
		phase = cloudPhaseMulti(nu, g);
	}
	return s * integral;
}

static inline float2 cloudShell(float3 o, float3 d, float rIn, float rOut) {
	float b = dot(o, d), oo = dot(o, o);
	float dOut = b * b - oo + rOut * rOut;
	if (dOut < 0.0) return float2(-1.0);
	dOut = sqrt(dOut);
	float2 outer = -b + float2(-dOut, dOut);
	if (outer.y < 0.0) return float2(-1.0);
	float dIn = b * b - oo + rIn * rIn;
	float2 inner = dIn >= 0.0 ? -b + float2(-sqrt(dIn), sqrt(dIn)) : float2(-1.0);
	bool hitIn = inner.y >= 0.0;
	return float2(hitIn && inner.x < 0.0 ? inner.y : max(outer.x, 0.0), hitIn && inner.x > 0.0 ? inner.x : outer.y);
}

// The cumulus layer along dir: rgb in-scattered radiance (with aerial perspective toward clear), a transmittance.
static half4 cloudMarch(float3 dir, float dither, int steps, int lightSteps, constant ShadeFrame &f, constant ShadeLook &L,
                        texture2d<half> n2d, texture2d<half> worley, texture2d<half> curl, float3 clear, float3 zenith) {
	CloudLayer c = cloudLayer(f, L);
	float3 eye = shadeEye(f.invViewProj);
	float altitude = f.cameraBlock.y + f.cameraFract.y + eye.y;
	float3 o = float3(0.0, CLOUD_PLANET_R + (altitude - CLOUD_SEA_LEVEL) * CLOUD_SCALE, 0.0);
	float r = o.y;
	float2 dists = cloudShell(o, dir, c.radius, c.top);
	if (dists.y < 0.0) return half4(0.0h, 0.0h, 0.0h, 1.0h);
	// the planet hides the layer (below it, looking down)
	float bp = dot(o, dir), dp = bp * bp - r * r + (r - 10.0) * (r - 10.0);
	if (r < c.radius && dp >= 0.0 && -bp + sqrt(dp) >= 0.0) return half4(0.0h, 0.0h, 0.0h, 1.0h);

	int primary = int(mix(float(steps) * 2.0, float(steps), abs(dir.y)));
	float len = clamp(dists.y - dists.x, 0.0, CLOUD_MAX_RAY);
	float stepLen = len / float(primary);
	float3 rayStep = dir * stepLen;
	float3 start = o + dir * (dists.x + stepLen * dither);

	float3 light = f.lightDirWorld.xyz;
	float nu = dot(dir, light);
	float bounced = 0.4 * max(light.y, 0.0) / M_PI_F; // planet albedo 0.4
	float2 scat = 0.0;
	float T = 1.0, dSum = 0.0, wSum = 0.0;
	float lightOd = 0.0, skyOd = 0.0;
	int lit = 0; // in-cloud samples so far: the light and sky marches run on every other one and are reused for the next
	for (int i = 0; i < primary && T > CLOUD_MIN_T; i++) {
		float3 p = start + rayStep * float(i);
		float density = cloudDensity(p, c, n2d, worley, curl, true);
		if (density < 1e-4) continue;
		float dist = stepLen * float(i);
		density *= 1.0 - smoothstep(0.95, 1.0, dist / CLOUD_MAX_RAY);
		float stepT = exp(-density * c.extinction * stepLen);
		float altFrac = (length(p) - c.radius) / c.thickness;
		if ((lit++ & 1) == 0) {
			float2 h = fract(float2(dither * 7.13 + float(i) * 0.618, dither * 3.71 + float(i) * 0.382));
			lightOd = cloudOpticalDepth(p, light, c, n2d, worley, curl, h.x, lightSteps);
			skyOd = cloudOpticalDepth(p, float3(0.0, 1.0, 0.0), c, n2d, worley, curl, h.y, lightSteps > 4 ? 2 : 1);
		}
		float groundOd = mix(density, 1.0, saturate(altFrac * 2.0 - 1.0)) * altFrac * c.thickness;
		scat += cloudScattering(density, lightOd, skyOd, groundOd, c, stepT, nu, bounced) * T;
		T *= stepT;
		dSum += dist * density;
		wSum += density;
	}
	if (T >= 0.999) return half4(0.0h, 0.0h, 0.0h, 1.0h);

	float rain = saturate(f.weather.x);
	// the sun as the layer sees it: ShadeSky's light is irradiance / pi at the ground; from 1-2.5 km up it has crossed less air
	// (Photon samples its transmittance at the cloud). Each channel's extinction relative to the least extinguished one, -log(c),
	// scaled by 0.6: a low sun turns golden there rather than red, and a high one is unchanged
	float3 lightColor = f.sunColor.rgb * M_PI_F;
	float lmax = max(max(lightColor.r, lightColor.g), max(lightColor.b, 1e-8));
	lightColor = lmax * pow(max(lightColor / lmax, 1e-4), 0.6);
	// skylight: the zenith's radiance over the upper hemisphere (Photon's sky_color = 2 pi * 1.13 * zenith)
	float3 skyColor = zenith * (2.0 * M_PI_F * 1.13) * (1.0 - 0.3 * rain);
	float Tc = cloudLinearStep(CLOUD_MIN_T, 1.0, T);
	float3 color = scat.x * lightColor + scat.y * skyColor;
	// aerial perspective: the air between the eye and the cloud (Rayleigh-like extinction, boosted like Photon's AP boost)
	float apparent = (wSum > 0.0 ? dSum / wSum : 0.0) + dists.x;
	float3 air = exp(-apparent * float3(5.8e-6, 13.5e-6, 33.1e-6) * 2.0 * (1.0 + 2.0 * rain));
	color = mix((1.0 - Tc) * clear, color, air);
	return half4(half3(min(color, 60000.0)), half(Tc));
}

static inline int cloudLightSteps(int steps) { return steps >= 20 ? 6 : steps >= 12 ? 5 : 4; }

struct CloudPush { uint frame; uint historyValid; float2 pad; };

// One cell of the 2x2 checkerboard per frame over the half-resolution grid (Photon's checkerboard order).
static inline uint2 cloudCell(uint frame) {
	const uint2 order[4] = {uint2(0, 0), uint2(1, 1), uint2(1, 0), uint2(0, 1)};
	return order[frame & 3u];
}

static inline float3 cloudDir(float2 uv, constant ShadeFrame &f) {
	return normalize(shadeViewRay(uv * 2.0 - 1.0, f.invViewProj));
}

fragment half4 shade_cloud_trace(ShadeFsOut in [[stage_in]],
                                 constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                 constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                 constant CloudPush &push [[buffer(0)]],
                                 texture2d<half> n2d [[texture(0)]],
                                 texture2d<half> worley [[texture(1)]],
                                 texture2d<half> curl [[texture(2)]],
                                 texture2d<half> history [[texture(3)]],
                                 texture2d<half> lut [[texture(CM_SHADE_TEX_SKY_LUT)]],
                                 sampler lutSampler [[sampler(CM_SHADE_SAMP_LINEAR)]]) {
	uint2 t = uint2(in.position.xy);
	uint2 h = t * 2u + cloudCell(push.frame);
	float2 halfSize = float2(history.get_width(), history.get_height());
	float2 uv = (float2(h) + 0.5) / halfSize;
	float3 dir = cloudDir(uv, f);
	// per pixel and frame (interleaved gradient noise, rotated by the golden ratio each full checkerboard cycle)
	float dither = fract(52.9829189 * fract(dot(float2(h), float2(0.06711056, 0.00583715))) + float(push.frame >> 2u) * 0.6180340);
	int steps = clamp(int(L.clouds1.y), 4, 32);
	float3 clear = shadeSkyLookup(dir, lut, lutSampler, f);
	float3 zenith = shadeSkyLookup(float3(0.0, 1.0, 0.0), lut, lutSampler, f);
	return cloudMarch(dir, dither, steps, cloudLightSteps(steps), f, L, n2d, worley, curl, clear, zenith);
}

// The half-resolution image: this frame's traced cell where it was traced, elsewhere the history reprojected by direction (the
// layer is hundreds of blocks away: rotation dominates), or the trace upsampled where the history has nothing.
fragment half4 shade_cloud_resolve(ShadeFsOut in [[stage_in]],
                                   constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                   constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                   constant CloudPush &push [[buffer(0)]],
                                   texture2d<half> trace [[texture(0)]],
                                   texture2d<half> history [[texture(1)]]) {
	uint2 h = uint2(in.position.xy);
	float2 halfSize = float2(history.get_width(), history.get_height());
	float2 uv = (float2(h) + 0.5) / halfSize;
	uint2 cell = cloudCell(push.frame);
	bool fresh = all((h & 1u) == cell);
	uint2 tsz = uint2(trace.get_width(), trace.get_height());
	half4 cur = fresh ? trace.read(min(h >> 1u, tsz - 1u)) : trace.sample(shadeLinearClamp, uv);
	if (push.historyValid == 0u) return cur;
	float3 dir = cloudDir(uv, f);
	float4 pc = L.prevViewProjNoJitter * float4(dir, 0.0);
	if (pc.w <= 1e-4) return cur;
	float2 puv = pc.xy / pc.w * 0.5 + 0.5;
	if (any(puv < 0.0) || any(puv > 1.0)) return cur;
	half4 hist = history.sample(shadeLinearClamp, puv);
	// keep the history inside what the traces around here allow (its 2x2 cells' range, widened): no smearing where a cloud's
	// edge moved, while the dithered steps' noise still averages out
	float2 tuv = uv;
	float2 tp = 1.0 / float2(tsz);
	half4 a = trace.sample(shadeLinearClamp, tuv + float2(-tp.x, -tp.y)), b = trace.sample(shadeLinearClamp, tuv + float2(tp.x, -tp.y));
	half4 c = trace.sample(shadeLinearClamp, tuv + float2(-tp.x, tp.y)), d = trace.sample(shadeLinearClamp, tuv + float2(tp.x, tp.y));
	half4 lo = min(min(a, b), min(c, d)), hi = max(max(a, b), max(c, d));
	half4 pad = (hi - lo) * 0.25h + half4(half3(0.02h * max(hi.rgb, half3(0.05h))), 0.02h);
	hist = clamp(hist, lo - pad, hi + pad);
	return fresh ? mix(hist, cur, 0.4h) : hist;
}

// The dome: the layer over the whole sky (reflections, off-screen directions), few samples, refreshed every 4th frame.
fragment half4 shade_cloud_dome(ShadeFsOut in [[stage_in]],
                                constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                texture2d<half> n2d [[texture(0)]],
                                texture2d<half> worley [[texture(1)]],
                                texture2d<half> curl [[texture(2)]],
                                texture2d<half> lut [[texture(CM_SHADE_TEX_SKY_LUT)]],
                                sampler lutSampler [[sampler(CM_SHADE_SAMP_LINEAR)]]) {
	float angle = (in.uv.x - 0.5) * 6.2831853;
	float y = in.uv.y * in.uv.y;
	float r = sqrt(1.0 - y * y);
	float3 dir = float3(cos(angle) * r, max(y, 0.004), sin(angle) * r);
	float3 clear = shadeSkyLookup(dir, lut, lutSampler, f);
	float3 zenith = shadeSkyLookup(float3(0.0, 1.0, 0.0), lut, lutSampler, f);
	return cloudMarch(normalize(dir), 0.5, 8, 3, f, L, n2d, worley, curl, clear, zenith);
}
