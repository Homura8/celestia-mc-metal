// Celestia aurora borealis pass: reduced-resolution volumetric curtain raymarch.
//
// Copyright 2026 Celestia Metal contributors. Licensed under the Apache License, Version 2.0 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// Volumetric curtain shell and altitude/distance fading adapted from Photon Shaders (https://github.com/sixthsurge/photon)
// include/sky/aurora.glsl at commit 26c2906e, Copyright (c) 2025 Benjamin Stott ("sixthsurge"), MIT License
// (LICENSES/MIT-Photon.txt). Reduced-resolution offscreen pass architecture adapted from Metal Shaders (GaelQuinta,
// Apache-2.0): metal/src/main/resources/mcopt/shade/aurora.metal.

struct AuroraPush {
	float4 colorBottom; // rgb = linear bottom curtain colour, w = effective strength
	float4 colorTop;    // rgb = linear top curtain colour, w = XZ noise frequency scale
	float4 params;      // x = step count (16..48), y = ray striation strength, z = crown tint blend, w = frame index
};

fragment half4 shade_aurora_pass(ShadeFsOut in [[stage_in]],
                                 constant ShadeFrame &f [[buffer(CM_SHADE_BUF_FRAME)]],
                                 constant ShadeLook &L [[buffer(CM_SHADE_BUF_LOOK)]],
                                 constant ShadeResources &sr [[buffer(CM_SHADE_BUF_RESOURCES)]],
                                 constant AuroraPush &ap [[buffer(0)]],
                                 texture2d<half> n2d [[texture(0)]]) {
	float3 dir = normalize(shadeViewRay(in.uv * 2.0 - 1.0, f.invViewProj));
	float strength = ap.colorBottom.w;
	if (strength <= 0.002 || dir.y <= 0.015) return half4(0.0h, 0.0h, 0.0h, 1.0h);

	const float volumeBottom = 1000.0;
	const float volumeTop = 3200.0;
	const float volumeRadius = 18000.0;

	float invY = 1.0 / dir.y;
	float tStart = volumeBottom * invY;
	float tEnd = min(volumeRadius / max(length(dir.xz), 1e-4), volumeTop * invY);
	if (tStart >= tEnd) return half4(0.0h, 0.0h, 0.0h, 1.0h);

	int steps = clamp(int(ap.params.x), 16, 48);
	// Static spatial dither prevents frame-to-frame shimmer when TAA is disabled.
	float dither = shadeNoise(in.position.xy, 0);
	float stepLen = (tEnd - tStart) / float(steps);
	float3 pos = dir * (tStart + stepLen * dither);
	float3 stepVec = dir * stepLen;

	float t = L.clock2.x;
	const float2 wind0 = float2(0.00065, 0.00012);
	const float2 wind1 = float2(-0.00014, -0.00082);
	const float invHeight = 1.0 / (volumeTop - volumeBottom);
	const float invRadius = 1.0 / volumeRadius;
	float freq = ap.colorTop.w;
	constexpr sampler auroraWrap(filter::linear, address::repeat);

	float3 emission = float3(0.0);
	for (int i = 0; i < steps; i++, pos += stepVec) {
		float h = saturate((pos.y - volumeBottom) * invHeight);
		float oneMinusH = 1.0 - h;
		float heightFade = oneMinusH * oneMinusH * oneMinusH * saturate(h * (1.0 / 0.03));

		float2 uv = pos.xz * freq;
		half4 s0 = n2d.sample(auroraWrap, uv + wind0 * t, level(0.0));
		float2 warp = float2(float(s0.x) - 0.5, float(s0.a) - 0.5) * 0.12;
		half4 s1 = n2d.sample(auroraWrap, uv * 1.08 + warp + wind1 * t + float2(0.37, 0.19), level(0.0));

		float shape = saturate(float(s0.y) + float(s1.y) - 1.0) * heightFade;
		float edgeBoost = 1.0 + 0.35 * exp(-h * 14.0);
		float d = length(pos.xz);
		float u = d * invRadius;
		float distFade = (1.0 - u * u * u) * (1.0 - exp2(-0.001 * d));

		float hDamp = h * (2.0 - h);
		float3 col = mix(ap.colorBottom.rgb, ap.colorTop.rgb, hDamp);
		emission += col * (shape * distFade * edgeBoost * stepLen);
	}

	if (max(emission.x, max(emission.y, emission.z)) > 1e-6) {
		float2 midXZ = dir.xz * (0.5 * (tStart + tEnd));
		float rayN = shadeDimsNoise(sr.milkyWay, midXZ * (freq * 14.0) + float2(t * 0.004, -t * 0.003));
		float rays = mix(1.0, 0.55 + 0.90 * rayN, saturate(ap.params.y));
		float horizon = smoothstep(0.025, 0.16, dir.y);
		emission *= 0.00088 * strength * horizon * rays;
	}

	emission = select(emission, float3(0.0), (as_type<uint3>(emission) & uint3(0x7f800000u)) == uint3(0x7f800000u));
	return half4(half3(min(max(emission, 0.0), 60000.0)), 1.0h);
}
