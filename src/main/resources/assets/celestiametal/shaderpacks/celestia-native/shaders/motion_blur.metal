// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/motion_blur.metal
//
// Copyright 2026 mcopt-shade & Celestia Metal contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Camera motion only; output is pre-exposed HDR. Input depth is reversed-Z world depth, before the hand.

constexpr sampler shadeMotionLinear(filter::linear, address::clamp_to_edge);
constexpr sampler shadeMotionPoint(filter::nearest, address::clamp_to_edge);

struct ShadeMotionParams {
	float4 config; // x = strength (1.0 = 1/120 s shutter), yz = uvScale, w = jitter flag (> 0.5)
	float4 size;   // xy = render target size (px), zw = unused
};

fragment half4 shade_motion_fs(ShadeFsOut in [[stage_in]],
                               texture2d<half> scene [[texture(0)]],
                               depth2d<float> depth [[texture(1)]],
                               constant ShadeMotionParams &p [[buffer(0)]],
                               constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                               constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]]) {
	float2 uvScale = p.config.yz;
	float2 uv = in.uv / uvScale;
	if (any(uv > 1.0)) return half4(0.0h);

	half4 center = scene.sample(shadeMotionLinear, in.uv);
	if (p.config.x <= 0.0 || L.dt.x <= 0.0 || L.dt.x > 0.1 || L.exposureRef.w > 0.5) return center;

	float2 jitter = f.jitter.xy * 0.5;
	float2 jOff = p.config.w > 0.5 ? jitter : float2(0.0);
	float2 depthUv = uv + jOff;
	float2 depthScale = p.size.xy / float2(depth.get_width(), depth.get_height());
	float z = depth.sample(shadeMotionPoint, clamp(depthUv, 0.0, 1.0) * depthScale);
	bool zSky = z <= 1e-7;

	float4 old;
	if (!zSky) {
		// f.invViewProj includes current jitter. Matrix reprojection uses unjittered screen coordinates.
		float4 world = f.invViewProj * float4(depthUv * 2.0 - 1.0, z, 1.0);
		float viewDepth = 1.0 / max(abs(world.w), 1e-8);
		if (viewDepth < 0.5) return center;
		old = L.prevViewProjNoJitter * world;
	} else {
		float3 dir = shadeViewRay(depthUv * 2.0 - 1.0, f.invViewProj);
		old = L.prevViewProjNoJitter * float4(dir, 0.0);
	}
	if (old.w <= 1e-6) return center;

	float2 oldUv = old.xy / old.w * 0.5 + 0.5;
	float2 delta = (depthUv - jitter) - oldUv;
	// Camera cuts/teleports: skip rather than smear a new view.
	if (dot(delta, delta) > 0.0625) return center;

	// Fixed 1/120 s shutter at strength 1.0; velocity / dt keeps blur independent of frame rate.
	float2 velocity = delta * (p.config.x / (120.0 * max(L.dt.x, 0.001)));
	float len = length(velocity);
	float scW = float(scene.get_width());
	if (len * scW < 0.5) return center;

	// Cap trail to 4% of viewport and adaptively step every ~4 px (up to 12 taps).
	velocity *= min(1.0, 0.04 / max(len, 1e-8));
	int n = clamp(int(min(len, 0.04) * scW * 0.25), 4, 12);
	float invN = 1.0 / float(n);
	float jit = shadeNoise(in.position.xy, f.flags2.x);

	half3 sum = center.rgb;
	half weight = 1.0h;
	for (int i = 0; i < n; i++) {
		float t = (float(i) + jit) * invN - 0.5;
		float2 at = uv + velocity * t;
		if (any(at < 0.0) || any(at > 1.0)) continue;
		float dz = depth.sample(shadeMotionPoint, clamp(at + jOff, 0.0, 1.0) * depthScale);
		// Reject samples across strong silhouettes; do not smear the sky or background over a near surface.
		float ratio = !zSky && dz > 1e-7 ? min(z, dz) / max(z, dz) : (zSky && dz <= 1e-7 ? 1.0 : 0.0);
		half w = half(smoothstep(0.5, 0.9, ratio));
		sum += scene.sample(shadeMotionLinear, at * uvScale).rgb * w;
		weight += w;
	}
	return half4(sum / weight, center.a);
}
