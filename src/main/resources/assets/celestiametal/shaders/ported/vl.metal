// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/vl.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Air scattering follows upstream's adaptation of Photon Shaders (Benjamin Stott, MIT, see LICENSES/MIT-Photon.txt).

constant float SHADE_VL_RANGE = 128.0;

constant float SHADE_WATER_VL_RANGE = 32.0;

static inline float vlWaterDistance(float distance, float3 dir, float surfaceAboveEye) {
	float limit = min(distance, SHADE_WATER_VL_RANGE);
	return dir.y * limit > surfaceAboveEye ? surfaceAboveEye / dir.y : limit;
}

static float vlDistance(float2 uv, float depth, float3 eye, constant ShadeFrame &f, float surfaceAbove) {
	float2 ndc = uv * 2.0 - 1.0;
	if (depth <= 0.0) {
		if (surfaceAbove <= 0.0) return SHADE_VL_RANGE;
		return vlWaterDistance(SHADE_WATER_VL_RANGE, normalize(shadeViewRay(ndc, f.invViewProj)),
		    max(surfaceAbove - eye.y, 0.0));
	}
	float4 p = f.invViewProj * float4(ndc, depth, 1.0);
	float3 offset = p.xyz / p.w - eye;
	float distance = length(offset);
	if (surfaceAbove <= 0.0) return min(distance, SHADE_VL_RANGE);
	return vlWaterDistance(distance, offset / max(distance, 1e-4), max(surfaceAbove - eye.y, 0.0));
}

static float vlShadowAt(float3 p, constant ShadeFrame &f, depth2d_array<float> shadow, sampler cmp) {
	for (uint layer = 0; layer < 2; layer++) {
		float4 c = f.shadowViewProj[layer] * float4(p, 1.0);
		float edge = max(abs(c.x), abs(c.y));
		if (edge < 0.97 && c.z > 0.0 && c.z < 1.0) {
			float lit = shadow.sample_compare(cmp, shadeShadowUV(c.xyz), layer, min(c.z + 0.0015, 1.0));
			return layer == 1 ? mix(lit, 1.0, smoothstep(0.85, 0.97, edge)) : lit;
		}
	}
	return 1.0;
}

#ifdef CELESTIA_VL_MARCH
struct VlFsIn { float4 position [[position]]; float2 uv; };

// Underwater sunlight (alpha.26), adapted from Photon Shaders include/fog/water_fog_vl.glsl at commit 26c2906e, Copyright (c) 2025
// Benjamin Stott ("sixthsurge"), MIT License (LICENSES/MIT-Photon.txt). The march carries ALL of the sun's in-scattering under
// water: shadowed by the shadow map (pillars and walls cut dark shafts through the water) and banded by a smooth noise projected
// along the refracted sun ray, so every point on one sun ray reads the same band: shafts that run from the surface to the floor,
// brightest near the surface. The material shaders' underwater fog (shade_m2.metal shadeUnderwaterFog) drops its own sun term
// while this pass runs (L.vl.z > 0) and keeps the skylight. Differences from upstream: the sun's path to the surface comes from the
// water depth (L.vl.z) instead of the shadow map's depth difference, skylight stays in the material fog, the noise is our copy of
// Photon's noise.png (texture 1), and the step count follows the Volumetric Light Steps option.
static float3 vlWaterShafts(float3 eye, float3 dir, float distance, float jitter, constant ShadeFrame &f, constant ShadeLook &L,
                           depth2d_array<float> shadow, sampler cmp, texture2d<half> noise) {
	constexpr sampler wrap(filter::linear, address::repeat);
	int steps = min(clamp(int(L.vl.x), 8, 16) + int(0.15 * distance), 20); // (Ultra: 16-20)
	float dt = distance / float(steps);
	float2 sunXZ = f.lightDirWorld.xz / SHADE_WATER_IOR;
	float3 sun = float3(sunXZ.x, sqrt(max(1.0 - dot(sunXZ, sunXZ), 1e-4)), sunXZ.y);
	// the band pattern's plane, perpendicular to the refracted sun (upstream: shadow view space)
	float3 e1 = normalize(cross(sun, abs(sun.x) < 0.9 ? float3(1.0, 0.0, 0.0) : float3(0.0, 0.0, 1.0)));
	float3 e2 = cross(sun, e1);
	float3 world0 = f.cameraFract.xyz + fmod(f.cameraBlock.xyz, 512.0);
	const float2 d0 = float2(cos(0.5), sin(0.5)), d1 = float2(cos(3.0), sin(3.0));
	float t = f.time.y * 0.25;
	float LoV = dot(dir, sun);
	// the four multiple-scattering octaves' phase x amount, constant along the ray (hoisted out of the march)
	float4 ph;
	for (int k = 0; k < 4; k++) ph[k] = (0.7 * shadeHG(LoV, 0.5 / float(1 << k)) + 0.3 * (0.25 / M_PI_F)) / float(1 << k);
	float3 stepT = exp(-SHADE_WATER_EXTINCTION * dt);
	float3 transmission = float3(1.0);
	float3 scattering = float3(0.0);
	for (int i = 0; i < steps; i++) {
		float3 p = eye + dir * ((float(i) + jitter) * dt);
		float lit = f.flags.z == 0 ? 1.0 : vlShadowAt(p, f, shadow, cmp);
		if (lit > 0.001) {
			float lightPath = max(L.vl.z - p.y, 0.0) / sun.y;
			float3 lightT = exp(-SHADE_WATER_EXTINCTION * lightPath) * lit;
			float3 w = world0 + p;
			float2 c = float2(dot(w, e1), dot(w, e2));
			float caustics = 0.67 * float(noise.sample(wrap, (c + d0 * t) * 0.02).g) + 0.33 * float(noise.sample(wrap, (c + d1 * t) * 0.04).g);
			caustics = saturate((caustics - 0.4) * 10.0) + 0.15;
			float3 sum = float3(0.0);
			for (int k = 0; k < 4; k++) { // (Photon's multiple-scattering octaves: the light's transmittance square-rooted each)
				sum += ph[k] * lightT;
				lightT = sqrt(lightT);
			}
			scattering += caustics * sum * transmission;
		}
		transmission *= stepT;
	}
	float sky = smoothstep(0.2, 0.8, L.eye.w) * (1.0 - 0.85 * f.weather.x);
	float strength = L.vl.y * sky * smoothstep(0.015, 0.15, f.lightDirWorld.y) * (1.0 - smoothstep(14.0, 24.0, L.vl.z));
	return f.sunColor.rgb * M_PI_F * scattering * (1.0 - stepT) * (SHADE_WATER_SCATTERING / SHADE_WATER_EXTINCTION) * strength;
}

fragment half4 shade_vl_march(VlFsIn in [[stage_in]],
                              constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                              constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                              depth2d<float> depth [[texture(0)]],
                              texture2d<half> noise [[texture(1)]],
                              depth2d_array<float> shadow [[texture(CM_SHADE_TEX_SHADOW)]],
                              sampler cmp [[sampler(CM_SHADE_SAMP_SHADOW)]]) {
	uint2 size = uint2(depth.get_width(), depth.get_height());
	float z = depth.read(min(uint2(in.uv * float2(size)), size - 1u));
	float3 eye = shadeEye(f.invViewProj);
	float distance = vlDistance(in.uv, z, eye, f, L.vl.z);
	float3 dir = normalize(shadeViewRay(in.uv * 2.0 - 1.0, f.invViewProj));
	float jitter = 0.2 + 0.6 * shadeNoise(in.position.xy, 0);
	if (L.vl.z > 0.0) return half4(half3(vlWaterShafts(eye, dir, distance, jitter, f, L, shadow, cmp, noise)), half(distance));
	float mu = dot(dir, f.lightDirWorld.xyz);
	float phase = 0.75 * shadeHG(mu, 0.76) + 0.25 * shadeHG(mu, -0.15);
	int steps = L.vl.x > 0.0 ? clamp(int(L.vl.x), 4, 24) : 12;
	float strength = L.vl.x > 0.0 ? L.vl.y : 1.0;
	float dt = distance / float(steps);
	float sun = 0.0;
	float transmission = 1.0;
	for (int i = 0; i < steps; i++) {
		float t = (float(i) + jitter) * dt;
		float3 p = eye + dir * t;
		float h = p.y + f.cameraBlock.y + f.cameraFract.y;
		float density = max(L.fogM.x, 0.0005) * exp(-max(h - L.fogM.z, 0.0) / max(L.fogM.y, 24.0));
		float stepT = exp(-density * dt);
		float lit = f.flags.z == 0 ? 1.0 : vlShadowAt(p, f, shadow, cmp);
		sun += transmission * (1.0 - stepT) * lit;
		transmission *= stepT;
	}
	float3 light = f.sunColor.rgb * (strength * sun * min(phase * 0.4, 0.28) * (1.0 - 0.65 * f.weather.x));
	return half4(half3(light), half(distance));
}
#endif

static float3 vlUpsample(texture2d<half> volume, float2 uv, float distance) {
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	float4 sample = float4(volume.sample(linear, uv, level(0.0)));
	float tolerance = max(1.0, 0.1 * distance);
	if (abs(sample.a - distance) <= tolerance) {
		// (alpha.26) a 4-tap tent over the quarter-resolution texels at the same depth: smooths the march's per-pixel jitter
		// (visible as a dither grid in sparse underwater shafts) without blurring across depth edges
		float2 o = 0.75 / float2(volume.get_width(), volume.get_height());
		float3 sum = sample.rgb;
		float n = 1.0;
		for (int i = 0; i < 4; i++) {
			float4 t = float4(volume.sample(linear, uv + o * float2((i & 1) ? 1.0 : -1.0, (i & 2) ? 1.0 : -1.0), level(0.0)));
			if (abs(t.a - distance) <= tolerance) {
				sum += t.rgb;
				n += 1.0;
			}
		}
		return sum / n;
	}

	float2 size = float2(volume.get_width(), volume.get_height());
	int2 first = int2(floor(uv * size - 0.5));
	float3 sum = 0.0;
	float total = 0.0;
	for (int i = 0; i < 4; i++) {
		uint2 px = uint2(clamp(first + int2(i & 1, i >> 1), int2(0), int2(size) - 1));
		float4 tap = float4(volume.read(px));
		float w = saturate(1.0 - abs(tap.a - distance) / (2.0 * tolerance));
		sum += tap.rgb * w;
		total += w;
	}
	return sum / max(total, 1e-4);
}
