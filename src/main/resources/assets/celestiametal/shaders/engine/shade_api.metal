// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shade_look.metal and shade_common.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Celestia Metal world-pack ABI: the buffers the engine (Java) writes and every world shader pack reads. Engine-owned: a
// world pack cannot override this file (SHADER_PACK_SPEC.md, "World packs"). Layout changes here must match ShadeFrame.java,
// ShadeLook.java, CelestiaShade (ShadeGpu / ShadeResources) and ShadeWater.packParams, and bump the world API version.
//   buffer(24)  constant ShadeFrame&        CPU-written per frame (1024 B)
//   buffer(25)  constant ShadeLook&         CPU-written per frame (1136 B)
//   buffer(26)  ShadeGpu                    GPU-written (auto-exposure); read by the next frame
//   buffer(27)  constant ShadeResources&    argument buffer of engine textures (128 B)
//   buffer(28)  constant ShadeWaterParams&  CPU-written per frame (176 B)
#ifndef CELESTIA_SHADE_API
#define CELESTIA_SHADE_API
#include <metal_stdlib>
using namespace metal;

#define CELESTIA_WORLD_API 1

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
	float4 vl;         // 480  volumetric light: x samples, y strength, z water surface above camera (0 in air), w reserved
	float4 wet;        // 496  x wetness, y puddles, z snow cover, w rain intensity
	float4 weatherA;   // 512  daily cloud weather (ShadeWeather): x, y cumulus coverage min / max, z, w altocumulus min / max
	float4 clouds0;    // 528  x cumulus base y, y coverage scale (now folded into weatherA/B), z unused, w volumetric clouds on
	float4 clouds1;    // 544  x reflection dome enabled, y samples, z density scale, w drift phase
	float4 waterShadow;// 560  water soft shadow / DH direct / contact / torch caustics
	float4 water;      // 576  wet-all look / film roughness / veg roughness / gate
	float4 dimTint;    // 592  x fog extinction (1/block), y lava sea y, z border fog radius (0 off), w kind + 4*bits
	float4 tintRect;   // 608  coloured-shadow casters rect
	float4 eye;        // 624  x cave air glow, y cave water sky, z cave water ripples, w smoothed eye sky light
	float4 skyGoldH;   // 640  rgb golden-hour gain toward horizon, w M3 sunset art toggle
	float4 skyGoldZ;   // 656  rgb golden-hour gain toward zenith, w M3 evening rose hue weight
	float4 night;      // 672  x star brightness, y Milky Way, z aurora, w moon phase angle (rad)
	float4 ssr;        // 688  x prevScene valid, y prevDepth valid, z weatherNoise baked, w shadowTint mode
	float4 clock2;     // 704  x slow sky clock (s), y air sky light, z caveAir on, w air sun light
	float4 renderScale;// 720  x render scale, y texture mip bias, zw live render size (px)
	float4 exposureCfg;// 736  x EV below ref, y EV above ref, z adapt-up tau (s), w adapt-down tau (s)
	float4 weatherB;   // 752  x cirrus coverage, y cirrocumulus coverage, z cumulus congestus amount, w stratus amount
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
#define SHADE_FEATURE_DIMS (1 << 20)
#define SHADE_FEATURE_MEDIA (1 << 21)
#define SHADE_FEATURE_SHIMMER (1 << 22)
#define SHADE_FLAG_DIMS_LIT (1 << 23)

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

struct ShadeFrame {
	float4x4 view;              //   0
	float4x4 proj;              //  64
	float4x4 viewProj;          // 128
	float4x4 invViewProj;       // 192
	float4x4 prevViewProj;      // 256
	float4x4 shadowViewProj[2]; // 320
	float4 cameraBlock;         // 448
	float4 cameraFract;         // 464
	float4 sunDirWorld;         // 480
	float4 sunDirView;          // 496
	float4 moonDirWorld;        // 512
	float4 lightDirWorld;       // 528
	float4 sunColor;            // 544
	float4 ambientSky;          // 560
	float4 ambientGround;       // 576
	float4 ambientBlock;        // 592
	float4 fogColor;            // 608
	float4 fogRange;            // 624
	float4 fogSky;              // 640
	float4 fogColorHdr;         // 656 fogColor.rgb as shadeLdrToHdr gives it (per frame, CelestiaShade), w 1 - rain
	float4 zenithColor;         // 672
	float4 horizon[8];          // 688
	float4 cascadeSplits;       // 816
	float4 shadowParams;        // 832: inverse resolution, resolution, depth bias, filter spread scale
	float4 screen;              // 848
	float4 time;                // 864
	float4 weather;             // 880
	float4 jitter;              // 896
	float4 atmosphere;          // 912
	float4 ambientToward;       // 928
	float4 ambientAway;         // 944
	int4 flags;                 // 960
	int4 flags2;                // 976
	float4 sunPath;             // 992
	float4 wxLine;              // 1008
};

static_assert(sizeof(ShadeFrame) == 1024, "ShadeFrame size must be 1024 bytes");

#define SHADE_DEV_NO_FOG_LUT 1
#define SHADE_DEV_NO_SHADOW 2
#define SHADE_DEV_FLAT_SKY 4
#define SHADE_DEV_NO_WATER 8
#define SHADE_DEV_FLAT_LIGHT 16
#define SHADE_DEV_LEGACY_CHUNK_EDGE 32
#define SHADE_DEV_LEGACY_SNELL 64

static inline bool shadeDev(constant ShadeFrame &f, int bit) { return (int(f.sunPath.z) & bit) != 0; }

// 176 bytes, written by ShadeWater.packParams.
struct ShadeWaterParams {
	float4 still;  // atlas uv rectangle (u0, v0, u1, v1) of minecraft:block/water_still (all 0: unknown)
	float4 flow;   // the same for minecraft:block/water_flow
	float4 state;  // x 1 when the copies hold this frame's opaque scene, y water surface height above the eye (under water),
	               // z wetness 0..1, w 1 when texture(20) holds this frame's baked waves
	float4 tune;   // x wave strength (mcopt.shade.waterWaves), y SSR max distance (blocks; (1.1) 0 = screen reflections off), z reflection strength, w caustics 0/1
	// (2026-11-02, water round 1; all read every frame, defaults = the look before it; SHADE_WATER_SWELL / SHADE_WATER_GLITTER code)
	float4 swell;  // x the swell's strength (mcopt.shade.water.swell, 0 = none), y its masking k (.swellMask, 0.45), z the light through
	               // its crests at golden hour (.swellGlow, 0), w its share in the Fresnel (.swellFresnel, 1 = physical, 0 = as without it)
	float4 swell2; // x the open-water map's mean in its outer ring, for the water beyond it (< 0: no map, the swell everywhere at its
	               // strength), y (candidate 7) the mirrored images' calm (.mirrorCalm; 0 = 0.55), z the long waves' calm (mcopt.shade.water.calm,
	               // 0.55), w the ripples' (.ripple, 2.0)
	float4 swell3; // x the swell's share in the mirrored images' direction (.swellRefl, 0.45 = the ripples' share, 1 = all of it),
	               // y the glint's glitter (.glitter, 0 = none), z the glint's base roughness factor (.glintSharp, 1 = candidate 4's), w (candidate
	               // 7) the mirrored image's temporal reprojection's weight (.reflTemporal, 0 = none; SHADE_WATER_RTR)
	float4 rhist;  // (2026-11-06, SHADE_WATER_RHIST) the reflection's own history: x its weight (mcopt.shade.water.reflHistK, 0 = off:
	               // no read, no write), y 1 when texture(29) holds last frame's (mcwater.m), z this frame's tag (+1 / -1, alternating;
	               // the texels last frame wrote carry -z), w the clamp box's scale (.reflHistBox; 0 = the code isn't compiled in)
	float4 mirror; // (2026-11-06, SHADE_WATER_MIRROR_AA) x the ripple-aware mirror normal's strength (mcopt.shade.water.mirrorAAStrength,
	               // 0 = none), y (candidate 8, SHADE_SSR_HIER) the mirrored image's footprint filter (mcopt.shade.water.reflFilter, 1; 0 = one
	               // tap per pixel), z (candidate 8, SHADE_WATER_PANO) the panorama's share off screen (mcopt.shade.water.reflPano, 1; 0 = none),
	               // w (1.2.8) the gain of the caustics' bright lines seen from above (mcopt.shade.water.causticGain; 1 = 1.2.7's)
	float4 far;    // (1.2.9, water phase 2) x the far water's distance D (blocks, mcopt.shade.water.far; 0 = off), y its fade band (blocks)
	int4 quality;  // x hierarchical SSR interval budget, y physical Snell's window from below (0: Photon's default), zw reserved
};
static_assert(sizeof(ShadeWaterParams) == 176, "ShadeWaterParams layout");

#endif
