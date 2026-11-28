// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shade_look.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// M2: the art layer and GPU-written state every shaded pipeline (and every pipeline drawn into the HDR world target)
// can read, plus the display transform ("Shade Filmic") and its inverse. Self-contained (only metal_stdlib):
//   buffer(25)  constant ShadeLook&   CPU-written per frame (1136 B)
//   buffer(26)  ShadeGpu              GPU-written (auto-exposure); read by the next frame
#ifndef MCOPT_SHADE_LOOK
#define MCOPT_SHADE_LOOK
#include <metal_stdlib>
using namespace metal;



static inline float shadeAirSky(constant ShadeLook &L) { return L.clock2.z > 0.5 ? L.clock2.y : 1.0; }
static inline bool shadeAirSmooth(constant ShadeLook &L) { return L.clock2.z > 0.5; }
static inline float shadeAirSun(constant ShadeLook &L) { return L.clock2.w; }

static inline float3 shadeRows(const constant float4 *m, float3 c) {
	return float3(dot(m[0].xyz, c), dot(m[1].xyz, c), dot(m[2].xyz, c));
}

static inline float3 shadeLottes(float3 x, float4 t) {
	float3 lx = log2(max(x, 1e-7)) * t.x;
	float3 xa = exp2(lx);
	float3 xad = exp2(lx * t.y);
	return xa / (xad * t.z + t.w);
}

static inline float3 shadeHdrPow(float3 x, float3 y) {
#ifdef CELESTIA_WEATHER_FAST_HDR
	// Inverted filmic and sRGB curves use nonnegative inputs and positive exponents.
	// Classic precipitation may execute this many times at the same screen pixel.
	return fast::powr(x, y);
#else
	return pow(x, y);
#endif
}

static inline float3 shadeLottesInverse(float3 y, float4 t) {
	float a = t.x, d = t.y, b = t.z, beta = t.w;
	y = clamp(y, 0.0, 0.95 / (b * d));
	float3 u = (y * b * (1.0 - d) + y * beta) / (1.0 - y * b * d);
	for (int i = 0; i < 3; i++) {
		float3 ud = shadeHdrPow(max(u, 1e-9), float3(d));
		float3 g = u - y * (b * ud + beta);
		float3 dg = 1.0 - y * b * d * ud / max(u, 1e-9);
		u = max(u - g / max(dg, 0.05), 0.0);
	}
	return shadeHdrPow(u, float3(1.0 / a));
}

static inline float3 shadeDisplay(float3 x, constant ShadeLook &L) {
	float3 c = max(shadeRows(L.gradeIn, max(x, 0.0)), 0.0);
	c = min(shadeLottes(c, L.tonemap), L.output.x);
	float3 y = max(shadeRows(L.gradeOut, c), 0.0);
	return max(y * L.grade3.rgb + L.grade2.rgb, 0.0);
}

static inline float3 shadeSrgbToLinearExact(float3 c) {
	return select(shadeHdrPow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}
static inline float3 shadeLinearToSrgbExact(float3 c) {
	return select(1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float3 shadeLdrToHdr(float3 srgb, constant ShadeLook &L) {
	float3 y = shadeSrgbToLinearExact(saturate(srgb));
	y = (y - L.grade2.rgb) / max(L.grade3.rgb, 1e-3);
	y = clamp(shadeRows(L.gradeOutInv, max(y, 0.0)), 0.0, L.output.w);
	float3 c = shadeLottesInverse(y, L.tonemap);
	return max(shadeRows(L.gradeInInv, c), 0.0);
}
static inline half4 shadeLdrToHdr(half4 c, constant ShadeLook &L) { return half4(half3(min(shadeLdrToHdr(float3(c.rgb), L), 60000.0)), c.a); }
static inline float4 shadeLdrToHdr(float4 c, constant ShadeLook &L) { return float4(shadeLdrToHdr(c.rgb, L), c.a); }

#endif
