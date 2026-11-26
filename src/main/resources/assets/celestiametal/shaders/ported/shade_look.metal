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

struct ShadeLook {
	float4x4 viewProjNoJitter;     //   0
	float4x4 prevViewProjNoJitter; //  64
	float4x4 celestial;            // 128
	float4x4 cloudShadowVP;        // 192
	float4 sunGeom;    // 256  x sun path tilt (rad), y sun disc angular radius (rad), z moon disc radius (rad), w sun elevation (rad)
	float4 sunArt;     // 272  rgb art-graded direct light, w sun/moon crossfade 0..1
	float4 ambientArt; // 288  rgb ambient tint applied to the sky light, w ground-bounce strength
	float4 bounce;     // 304  rgb ground albedo for bounce light, w cave minimum light
	float4 grade0;     // 320  x EV bias, y saturation, z vibrance, w water clarity
	float4 grade1;     // 336  rgb white-balance gain, w Purkinje strength
	float4 grade2;     // 352  rgb lift (display), w black floor phi
	float4 grade3;     // 368  rgb gain (display), w inset s_in
	float4 tonemap;    // 384  Lottes curve f(x) = x^a / (x^(a d) b + beta): x a, y d, z b, w beta
	float4 output;     // 400  x peak P (1 = SDR), y paper white, z dither amplitude (LSB), w largest display value the inverse maps
	float4 bloom;      // 416  x mix m, y octave spectrum exponent, z fog-glow k, w moving water look
	float4 fogR;       // 432  rgb haze extinction sigma (1/block, at base height), w scale height (blocks)
	float4 fogM;       // 448  x mist sigma (1/block), y mist scale height, z mist base y (absolute), w mist albedo
	float4 fogMisc;    // 464  x haze base y (absolute), y border fog start fraction, z border fog radius (blocks, 0 = off), w evening glow
	float4 vl;         // 480  player water colour rgb + weight
	float4 wet;        // 496  x wetness, y puddles, z snow cover, w rain intensity
	float4 wind;       // 512  xy wind direction, z rain slant, w snowfall at camera
	float4 clouds0;    // 528  x cumulus base y, y top y, z cloud shadow strength, w volumetric clouds on
	float4 clouds1;    // 544  x reflection dome enabled, y fancy clouds, zw reserved
	float4 waterShadow;// 560  water soft shadow / DH direct / contact / torch caustics
	float4 water;      // 576  wet-all look / film roughness / veg roughness / gate
	float4 waterAbs;   // 592  wet film look parameters
	float4 tintRect;   // 608  coloured-shadow casters rect
	float4 eye;        // 624  x cave air glow, y cave water sky, z cave water ripples, w smoothed eye sky light
	float4 skyGoldH;   // 640  rgb golden-hour gain toward horizon, w M3 sunset art toggle
	float4 skyGoldZ;   // 656  rgb golden-hour gain toward zenith, w M3 evening rose hue weight
	float4 night;      // 672  x star brightness, y Milky Way, z aurora, w moon phase angle (rad)
	float4 ssr;        // 688  x prevScene valid, y prevDepth valid, z weatherNoise baked, w shadowTint mode
	float4 clock2;     // 704  x slow sky clock (s), y air sky light, z caveAir on, w air sun light
	float4 renderScale;// 720  x render scale, y texture mip bias, zw live render size (px)
	float4 exposureCfg;// 736  x EV below ref, y EV above ref, z adapt-up tau (s), w adapt-down tau (s)
	float4 dimTint;    // 752  reserved
	float4 flash;      // 768  xyz lightning direction, w lightning radiance
	float4 dt;         // 784  x frame dt (s), y time (s), z day index, w +1 morning / -1 evening
	int4 tier;         // 800  x tier (0 P .. 3 U), y feature bits (SHADE_FEATURE_*), z look preset (0 epic, 1 storybook, 2 natural), w debug view
	float4 gradeIn[3];    // 816  rows of the scene grade + inset matrix
	float4 gradeOut[3];   // 864  rows of the outset matrix
	float4 gradeInInv[3]; // 912  inverse of gradeIn
	float4 gradeOutInv[3];// 960  inverse of gradeOut
	float4 exposureRef;   // 1008 x reference exposure E_ref, y metering share lambda, z metering key, w 1 = jump
	float4 user0;         // 1024 x soft shadow sun radius, y vignette strength, z leaf light, w emissives
	float4 user1;         // 1040 x DH water reflect, y DH SSR, z foam, w refraction
	float4 user2;         // 1056 x glint, y beacon radiance, z DH swell, w DH swell refl
	float4 user3;         // 1072 x natural lighting strength, y normal strength, z specular, w emission
	float4 user4;         // 1088 x sky haze mode, y kept sun gain, z cloud fog blend, w mist sun gain
	float4 look2a;        // 1104 x foliage sheen, y side darkening, z sheen hue share, w nearEnd (blocks)
	float4 look2b;        // 1120 rgb sky gain, w min shadow penumbra radius (blocks)
};

static_assert(sizeof(ShadeLook) == 1136, "ShadeLook size must be 1136 bytes");

#define SHADE_FEATURE_HDR 1
#define SHADE_FEATURE_BLOOM 2
#define SHADE_FEATURE_AUTO_EXPOSURE 4
#define SHADE_FEATURE_PCSS 8
#define SHADE_FEATURE_STARS 16
#define SHADE_FEATURE_HAZE 32
#define SHADE_FEATURE_LIGHT_V2 64
#define SHADE_FEATURE_CLOUDS 4096

struct ShadeGpu {
	float4 sh[9];          //   0
	float4 sunAtCamera;    // 144
	float4 moonAtCamera;   // 160
	float4 exposure;       // 176  x applied this frame, y target, z previous frame's, w log2(x)
	float4 scene;          // 192  x mean log2 luminance, y canopy factor, z sun vis, w frames
	uint histogram[64];    // 208  log-luminance histogram
	uint xdrHot;           // 464
};

static_assert(sizeof(ShadeGpu) == 480, "ShadeGpu size must be 480 bytes");

struct ShadeResources {
	texture2d<half> milkyWay;    // 0
	texture2d<half> prevScene;   // 1
	texture2d<half> scene;       // 2
	texture2d<half> bloom;       // 3
	texture2d<half> weatherNoise;// 4
	texture2d<half> prevDepth;   // 5
	texture2d<half> shadowTint;  // 6
	texture2d<float> pbrNormal;  // 7
	texture2d<float> pbrSpecular;// 8
	texture2d<half> waterOpen;   // 9
	texture2d<half> reflPano;    // 10
	texture2d<half> aurora;      // 11
	texture2d<half> cloudShadow; // 12
	texture2d<half> cloudDome;   // 13
	texture2d<half> cloudScreen; // 14
	texture2d<half> waterSwell;  // 15
};

static_assert(sizeof(ShadeResources) == 128, "ShadeResources size must be 128 bytes");

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

static inline float3 shadeLottesInverse(float3 y, float4 t) {
	float a = t.x, d = t.y, b = t.z, beta = t.w;
	y = clamp(y, 0.0, 0.95 / (b * d));
	float3 u = (y * b * (1.0 - d) + y * beta) / (1.0 - y * b * d);
	for (int i = 0; i < 3; i++) {
		float3 ud = pow(max(u, 1e-9), float3(d));
		float3 g = u - y * (b * ud + beta);
		float3 dg = 1.0 - y * b * d * ud / max(u, 1e-9);
		u = max(u - g / max(dg, 0.05), 0.0);
	}
	return pow(u, float3(1.0 / a));
}

static inline float3 shadeDisplay(float3 x, constant ShadeLook &L) {
	float3 c = max(shadeRows(L.gradeIn, max(x, 0.0)), 0.0);
	c = min(shadeLottes(c, L.tonemap), L.output.x);
	float3 y = max(shadeRows(L.gradeOut, c), 0.0);
	return max(y * L.grade3.rgb + L.grade2.rgb, 0.0);
}

static inline float3 shadeSrgbToLinearExact(float3 c) {
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
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
