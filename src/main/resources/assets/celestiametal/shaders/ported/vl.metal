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

static float vlDistance(float2 uv, float depth, float3 eye, constant ShadeFrame &f) {
	if (depth <= 0.0) return SHADE_VL_RANGE;
	float4 p = f.invViewProj * float4(uv * 2.0 - 1.0, depth, 1.0);
	return min(length(p.xyz / p.w - eye), SHADE_VL_RANGE);
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

fragment half4 shade_vl_march(VlFsIn in [[stage_in]],
                              constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                              constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                              depth2d<float> depth [[texture(0)]],
                              depth2d_array<float> shadow [[texture(CM_SHADE_TEX_SHADOW)]],
                              sampler cmp [[sampler(CM_SHADE_SAMP_SHADOW)]]) {
	uint2 size = uint2(depth.get_width(), depth.get_height());
	float z = depth.read(min(uint2(in.uv * float2(size)), size - 1u));
	float3 eye = shadeEye(f.invViewProj);
	float distance = vlDistance(in.uv, z, eye, f);
	float3 dir = normalize(shadeViewRay(in.uv * 2.0 - 1.0, f.invViewProj));
	float mu = dot(dir, f.lightDirWorld.xyz);
	float phase = 0.75 * shadeHG(mu, 0.76) + 0.25 * shadeHG(mu, -0.15);
	const int steps = 12;
	float dt = distance / float(steps);
	// Stable spatial jitter removes bands without temporal history.
	float jitter = 0.2 + 0.6 * shadeNoise(in.position.xy, 0);
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
	float3 light = f.sunColor.rgb * (sun * min(phase * 0.4, 0.28) * (1.0 - 0.65 * f.weather.x));
	return half4(half3(light), half(distance));
}
#endif

static float3 vlUpsample(texture2d<half> volume, float2 uv, float distance) {
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	float4 sample = float4(volume.sample(linear, uv, level(0.0)));
	float tolerance = max(1.0, 0.1 * distance);
	if (abs(sample.a - distance) <= tolerance) return sample.rgb;

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
