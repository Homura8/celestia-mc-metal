// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/clouds.metal
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Cumulus height shaping and phase lobes follow upstream's adaptation of Photon Shaders
// (Benjamin Stott, MIT, commit 26c2906e, see LICENSES/MIT-Photon.txt).

// 64 slices of periodic 32x32 volume noise, with a one-texel gutter around each slice.
constant uint CLOUD_TILE = 34;
constant uint CLOUD_ATLAS = 8 * CLOUD_TILE;

static inline float3 cloudGrad3(int3 c, int period, uint salt) {
	c = ((c % period) + period) % period;
	uint h = shadeHash3(c, salt);
	float3 g = float3(shadeHash01(h), shadeHash01(h ^ 0x68e31da4u), shadeHash01(h ^ 0xb5297a4du)) * 2.0 - 1.0;
	return g * rsqrt(max(dot(g, g), 1e-6));
}

static float cloudPerlin3(float3 p, int period, uint salt) {
	int3 i = int3(floor(p));
	float3 f = p - floor(p);
	float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n000 = dot(cloudGrad3(i + int3(0, 0, 0), period, salt), f - float3(0, 0, 0));
	float n100 = dot(cloudGrad3(i + int3(1, 0, 0), period, salt), f - float3(1, 0, 0));
	float n010 = dot(cloudGrad3(i + int3(0, 1, 0), period, salt), f - float3(0, 1, 0));
	float n110 = dot(cloudGrad3(i + int3(1, 1, 0), period, salt), f - float3(1, 1, 0));
	float n001 = dot(cloudGrad3(i + int3(0, 0, 1), period, salt), f - float3(0, 0, 1));
	float n101 = dot(cloudGrad3(i + int3(1, 0, 1), period, salt), f - float3(1, 0, 1));
	float n011 = dot(cloudGrad3(i + int3(0, 1, 1), period, salt), f - float3(0, 1, 1));
	float n111 = dot(cloudGrad3(i + int3(1, 1, 1), period, salt), f - float3(1, 1, 1));
	float x0 = mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y);
	float x1 = mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y);
	return mix(x0, x1, u.z) * 1.15; // ~[-1, 1]
}

// Distance to the nearest of one jittered point per cell (cells per tile = period), 0 .. ~1 (in cells).
static float cloudWorley3(float3 p, int period, uint salt) {
	int3 i = int3(floor(p));
	float3 f = p - floor(p);
	float md = 9.0;
	for (int z = -1; z <= 1; z++)
		for (int y = -1; y <= 1; y++)
			for (int x = -1; x <= 1; x++) {
				int3 c = i + int3(x, y, z);
				int3 w = ((c % period) + period) % period;
				uint h = shadeHash3(w, salt);
				float3 o = float3(shadeHash01(h), shadeHash01(h ^ 0x1b56c4e9u), shadeHash01(h ^ 0x7f4a7c15u));
				float3 r = float3(x, y, z) + o - f;
				md = min(md, dot(r, r));
			}
	return sqrt(md);
}

static inline float cloudRemap(float v, float lo, float hi, float a, float b) {
	return a + (b - a) * saturate((v - lo) / max(hi - lo, 1e-5));
}

fragment half4 shade_cloud_noise(ShadeFsOut in [[stage_in]]) {
	uint2 texel = uint2(in.position.xy);
	uint2 tile = texel / CLOUD_TILE;
	float3 p = float3((float2(texel % CLOUD_TILE) - 0.5) / 32.0, (float(tile.y * 8 + tile.x) + 0.5) / 64.0);
	float perlin = 0.5 + 0.6 * (0.65 * cloudPerlin3(p * 4.0, 4, 11u) + 0.35 * cloudPerlin3(p * 8.0, 8, 12u));
	float billow = saturate(cloudWorley3(p * 4.0, 4, 21u));
	float erosion = saturate(cloudWorley3(p * 12.0, 12, 23u));
	return half4(half(cloudRemap(perlin, -billow, 1.0, 0.0, 1.0)), half(erosion), 0.0h, 1.0h);
}

static inline half2 cloudSlice(texture2d<half> noise, uint z, float2 xy) {
	float2 tile = float2(z % 8, z / 8) * CLOUD_TILE;
	return noise.sample(shadeLinearClamp, (tile + xy) / float(CLOUD_ATLAS), level(0.0)).rg;
}

static float cloudDensity(texture2d<half> noise, float3 p, float height, float rain) {
	if (height <= 0.0 || height >= 1.0) return 0.0;
	float3 q = fract(p * float3(1.0 / 768.0, 1.0 / 112.0, 1.0 / 768.0));
	float2 xy = q.xy * 32.0 + 1.0;
	float z = q.z * 64.0 - 0.5;
	uint slice = uint(int(floor(z)) & 63);
	float2 n = float2(mix(cloudSlice(noise, slice, xy), cloudSlice(noise, (slice + 1) & 63u, xy), half(fract(z))));
	float shape = smoothstep(0.0, 0.13, height) * (1.0 - smoothstep(0.35, 1.0, height));
	float coverage = mix(0.67, 0.53, rain);
	return saturate((n.x - n.y * 0.07 - coverage + 0.13 * shape) * 6.0) * shape;
}

static half4 cloudMarch(float3 dir, int steps, constant ShadeFrame &f, constant ShadeLook &L,
                        texture2d<half> noise, texture2d<half> lut, sampler lutSampler) {
	float3 eye = shadeEye(f.invViewProj);
	float altitude = f.cameraBlock.y + f.cameraFract.y + eye.y;
	float band = max(L.clouds0.y - L.clouds0.x, 1.0);
	if (abs(dir.y) < 1e-5) return half4(0.0h, 0.0h, 0.0h, 1.0h);
	float bottom = (L.clouds0.x - altitude) / dir.y;
	float top = (L.clouds0.y - altitude) / dir.y;
	float start = max(0.0, min(bottom, top));
	float end = min(max(bottom, top), 960.0);
	if (end <= start) return half4(0.0h, 0.0h, 0.0h, 1.0h);

	float3 camera = eye + f.cameraFract.xyz + fmod(f.cameraBlock.xyz, 5376.0);
	camera.xz += float2(-1.4, 0.5) * L.clouds1.w;
	float interval = (end - start) / float(steps);
	float rain = f.weather.x;
	float densityScale = L.clouds1.z;
	float3 light = f.lightDirWorld.xyz;
	float mu = dot(dir, light);
	float phase = 0.7 * shadeHG(mu, 0.72) + 0.3 * shadeHG(mu, -0.22);
	float3 sun = f.sunColor.rgb * min(phase * 2.1, 1.8) * (1.0 - 0.65 * rain);
	float3 ambient = mix(f.ambientGround.rgb, f.ambientSky.rgb, 0.7) * (1.1 - 0.42 * rain);
	float3 color = 0.0;
	float transmission = 1.0;
	for (int i = 0; i < steps && transmission > 0.02; i++) {
		float t = start + (float(i) + 0.5) * interval;
		float3 p = camera + dir * t;
		float h = (altitude + dir.y * t - L.clouds0.x) / band;
		float density = cloudDensity(noise, p, h, rain) * densityScale;
		if (density <= 0.001) continue;
		float ahead = cloudDensity(noise, p + light * 17.0, h + light.y * 17.0 / band, rain) * densityScale;
		float direct = exp2(-4.0 * ahead - 1.4 * density);
		float stepT = exp2(-density * interval * 0.32);
		color += transmission * (1.0 - stepT) * (ambient * mix(0.58, 1.3, h) + sun * (0.25 + 0.75 * direct));
		transmission *= stepT;
	}
	if (transmission >= 0.999) return half4(0.0h, 0.0h, 0.0h, 1.0h);
	float3 sky = shadeSkyLookup(dir, lut, lutSampler, f);
	float aerial = smoothstep(180.0, 960.0, start);
	float visibility = 1.0 - aerial * aerial * 0.85;
	return half4(half3(mix(color, sky * (1.0 - transmission), aerial) * visibility),
	             half(1.0 - (1.0 - transmission) * visibility));
}

fragment half4 shade_cloud_screen(ShadeFsOut in [[stage_in]],
                                  constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                  constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                  texture2d<half> noise [[texture(0)]],
                                  texture2d<half> lut [[texture(CM_SHADE_TEX_SKY_LUT)]],
                                  sampler lutSampler [[sampler(CM_SHADE_SAMP_LINEAR)]]) {
	float3 dir = normalize(shadeViewRay(in.uv * 2.0 - 1.0 + f.jitter.xy, f.invViewProj));
	return cloudMarch(dir, clamp(int(L.clouds1.y), 4, 24), f, L, noise, lut, lutSampler);
}

fragment half4 shade_cloud_dome(ShadeFsOut in [[stage_in]],
                                constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                texture2d<half> noise [[texture(0)]],
                                texture2d<half> lut [[texture(CM_SHADE_TEX_SKY_LUT)]],
                                sampler lutSampler [[sampler(CM_SHADE_SAMP_LINEAR)]]) {
	float angle = (in.uv.x - 0.5) * 6.2831853;
	float y = in.uv.y * in.uv.y;
	float r = sqrt(1.0 - y * y);
	return cloudMarch(float3(cos(angle) * r, y, sin(angle) * r), clamp(int(L.clouds1.y), 4, 8), f, L, noise, lut, lutSampler);
}
