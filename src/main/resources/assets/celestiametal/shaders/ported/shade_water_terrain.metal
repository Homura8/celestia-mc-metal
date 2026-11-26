// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/terrain_own.metal & water.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Renderer-agnostic P3a translucent terrain shading entry point shared by vanilla MC 26.3 and Sodium 0.9.x.
// Water quads (detected by atlas UV rect via shadeWaterSprite) run full wave/detail/swell/Fresnel/SSR/refraction/
// absorption/foam/caustics; other translucents (stained glass, ice, slime, honey) use shadeLit2 + shadeGlossy.
#ifndef CELESTIA_SHADE_WATER_TERRAIN
#define CELESTIA_SHADE_WATER_TERRAIN

// Keep the lighting and glossy SSR for glass and ice out of the hot water fragment.
static SHADE_COLD float4 shadeWaterTerrainOther(float alpha, float4 texel, float4 rawColor, float3 p, half3 n,
                                               float2 pixel, half sky, half block, half shadow, bool thin, float exposure,
                                               constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g,
                                               constant ShadeResources &sr, constant ShadeWaterParams &wp,
                                               texture2d<half> lut, sampler lutS,
                                               texture2d<half> scene, depth2d<float> depth, texture2d<float> hz) {
	half3 albedo = f.flags.w == 3 ? half3(0.45h) : shadeToLinear(half3(saturate(texel.rgb * rawColor.rgb)));
	float3 lit = shadeLit2(albedo, n, sky, block, shadow, thin, false, f, L, shadeLook2Near(p, L));
#ifdef SHADE_GLOSSY
	bool glossy = !thin && alpha > 0.02 && alpha < 0.99;
#ifdef SHADE_SSR_QUAD
	// The glossy trace shuffles between lanes. Keep the call uniform at atlas alpha edges.
	glossy = shadeQuadMin(float(glossy)) > 0.0;
#endif
	if (glossy && wp.state.x > 0.5 && !shadeDev(f, SHADE_DEV_NO_WATER)) {
		float prevExposure = L.ssr.x > 0.5 ? g.exposure.z : 0.0;
		return shadeGlossy(lit, alpha, p, float3(n), pixel, sky, shadow, exposure, prevExposure,
		                   f, &L, &sr, wp, lut, lutS, scene, depth, sr.prevScene, hz);
	}
#endif
	return float4(lit, alpha);
}

static float4 shadeWaterTerrainShade(float4 vanillaColor, float4 texel, float4 rawColor, float3 p, float2 light,
                                     float2 uv, float4 fragCoord, float chunkVis, float4 fogRanges,
                                     texture2d<half> skyLut, sampler skyLutSmplr,
                                     depth2d_array<float> shadowMap, sampler shadowCmp,
                                     constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g,
                                     constant ShadeResources &sr,
                                     texture2d<half> sceneCopy, depth2d<float> depthCopy,
                                     constant ShadeWaterParams &wp,
                                     texture2d<half> waterWaves, texture2d<float> waterCoarse,
                                     texture2d<half> waterDetail CEL_DL_PARAMS CEL_CL_PARAMS) {
	// Always compute screen-space derivatives across the full 2x2 quad before any non-uniform early return.
	float3 dpx = dfdx(p), dpy = dfdy(p);
	float2 du = dfdx(uv), dv = dfdy(uv);
	float waterFootprint = max(length(dpx), length(dpy));

	if (f.flags.x != SHADE_DIM_OVERWORLD || shadeDev(f, SHADE_DEV_FLAT_LIGHT)) {
		return float4(shadeVanillaOut(vanillaColor.rgb, L), vanillaColor.a);
	}

	float3 nf = cross(dpx, dpy);
	nf *= rsqrt(max(dot(nf, nf), 1e-30));
	if (dot(nf, p) > 0.0) nf = -nf;
	half3 n = half3(nf);
	half3 an = abs(n);
	half amax = max(max(an.x, an.y), an.z);
	bool thin = amax < 0.9h;
	if (!thin) {
		n = half3(an.x == amax ? sign(n.x) : 0.0h,
		          an.x != amax && an.y == amax ? sign(n.y) : 0.0h,
		          an.x != amax && an.y != amax ? sign(n.z) : 0.0h);
	}

	int waterSprite = int(shadeQuadMax(float(shadeWaterSprite(uv, wp))));
	bool waterFull = waterSprite > 0 && wp.state.x > 0.5 && !shadeDev(f, SHADE_DEV_NO_WATER);

	half block = half(saturate(light.x));
	half sky = half(saturate(light.y));
	half shadow = sky <= 0.3h ? half(1.0) : shadeShadow(shadowMap, shadowCmp, f, p, n, false);
	float ex = shadeExposure(f, g);
	float alpha = vanillaColor.a;
	float3 radiance;

	if (waterFull) {
		half3 up = half3(0.0h, 1.0h, 0.0h);
		ShadeWaterIn wi;
		wi.p = p;
		wi.nFace = float3(n);
		wi.footprint = waterFootprint;
		wi.flowDir = waterSprite == 2 && n.y > 0.5h ? shadeWaterFlowDir(dpx, dpy, du, dv) : float2(0.0);
		wi.pixel = fragCoord.xy;
		wi.depth = fragCoord.z;
		wi.tint = half3(rawColor.rgb);
		wi.sky = sky;
		wi.shadow = shadow;
		{
			float b = float(block), s = saturate(float(sky) * 2.0), c = 1.0 - s * s;
			wi.cave = half4(half(smoothstep(0.3, 0.8, b) * L.waterShadow.w),
			                half(c * L.eye.z),
			                half(saturate(c * L.eye.y)),
			                half(L.bloom.w));
		}
		wi.dxz = float4(dpx.xz, dpy.xz);
		wi.detail = float4(0.0);
#ifdef SHADE_WATER_DETAIL
		if (!SHADE_WDEV_IS(f, SHADE_WDEV_NO_DETAIL)
			&& (n.y > 0.5h || (n.y < -0.5h && SHADE_CAMERA_UNDERWATER(f)))
			&& wp.state.w > 0.5) {
			wi.detail = shadeWaterDetailIn(wi, f, waterDetail);
		}
#endif
#ifdef SHADE_WATER_SWELL
		wi.swell = float4(0.0);
		// The distant surface retains its long tiled waves and reflections.
		const float swellEnd = 176.0;
		float distanceSq = dot(p, p);
		if (n.y > 0.5h && waterSprite == 1 && distanceSq < swellEnd * swellEnd
		    && wp.swell.x > 0.0 && !SHADE_CAMERA_UNDERWATER(f)) {
			float fade = 1.0 - smoothstep(112.0, swellEnd, sqrt(distanceSq));
			float amp = fade * wp.swell.x * (1.0 + 0.8 * wp.state.z) * (1.0 + 0.6 * f.weather.y);
#ifdef SHADE_WATER_SWELL_BAKED
			if (wp.far.w > 0.5) {
				wi.swell = shadeWaterSwellSample(shadeWaterXZ(p.xz, f), wi.dxz, amp, sr.waterSwell);
				wi.swell.z *= fade;
			}
#else
			wi.swell = shadeWaterSwell(shadeWaterXZ(p.xz, f), shadeWaterTime(f), wi.dxz, amp);
#endif
		}
#endif
		bool underBelow = SHADE_CAMERA_UNDERWATER(f) && n.y < -0.5h;
		wi.lit = underBelow ? float3(0.0) : shadeLit2(half3(1.0h), up, sky, block, shadow, false, false, f, L, shadeLook2Near(p, L));
#ifdef SHADE_DYNLIGHT
		if (!underBelow) wi.lit += f.ambientBlock.xyz * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, float3(n), false, block);
#endif
#ifdef SHADE_COLORLIGHT
		if (!underBelow) wi.lit += f.ambientBlock.xyz * shadeColorLightFrag(cl, clFine, clCoarse, f, p, float(block));
#endif
		wi.exposure = ex;
#ifdef SHADE_SSR_PREV
		wi.prevExposure = L.ssr.x > 0.5 ? g.exposure.z : 0.0;
#else
		wi.prevExposure = 0.0;
#endif
		wi.look = &L;
		wi.res = &sr;
		wi.fog = SHADE_CAMERA_UNDERWATER(f) ? shadeLdrToHdr(f.fogColor.rgb, L) / max(ex, 1e-6) : float3(0.0);

		radiance = shadeWaterSurface(wi, f, wp, skyLut, skyLutSmplr, sceneCopy, depthCopy, sr.prevScene, waterWaves, waterCoarse);
		alpha = 1.0;
	} else {
		float4 other = shadeWaterTerrainOther(alpha, texel, rawColor, p, n, fragCoord.xy,
		                                      sky, block, shadow, thin, ex, f, L, g, sr, wp,
		                                      skyLut, skyLutSmplr, sceneCopy, depthCopy, waterCoarse);
		radiance = other.rgb;
		alpha = other.a;
	}

	float vanillaFog = shadeVanillaFog(p, fogRanges.xy, fogRanges.zw);
	float chunkFade = saturate(1.0 - chunkVis);
	if (!(waterFull && SHADE_WDEV_IS(f, SHADE_WDEV_NO_FOG))) {
		radiance = shadeFogAir2(radiance, p, vanillaFog, chunkFade, skyLut, skyLutSmplr, f, L, &sr);
	}
	float3 rgb = shadeFinish2(radiance, vanillaFog, f, L, ex);
	if (f.flags.w == 2) rgb = shadeVanillaOut(float3(n) * 0.5 + 0.5, L);
	if (f.flags.w == 1) rgb = shadeVanillaOut(float3(0.25 + 0.75 * float(shadow)), L);
	return float4(rgb, alpha);
}

#endif
