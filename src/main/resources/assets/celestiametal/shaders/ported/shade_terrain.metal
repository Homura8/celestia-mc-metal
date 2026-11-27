// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/terrain_own.metal & shade_m2.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Renderer-agnostic P1 terrain shading entry point shared by vanilla terrain and Sodium 0.9.x terrain.
// Computes flat face normals from camera-relative position derivatives, classifies thin/foliage cutouts,
// applies shadeLit2 (shadow = 1 in P1) + shadeFogAir2 + shadeFinish2.
#ifndef CELESTIA_SHADE_TERRAIN
#define CELESTIA_SHADE_TERRAIN

static float4 shadeTerrainShade(float4 vanillaColor, float4 texel, float4 rawColor, float3 p, float2 light,
                                float chunkVis, bool isCutout, float4 fogRanges,
                                texture2d<half> skyLut, sampler skyLutSmplr,
                                depth2d_array<float> shadowMap, sampler shadowCmp,
                                constant ShadeFrame &f, constant ShadeLook &L, constant ShadeGpu &g,
                                constant ShadeResources &sr CEL_DL_PARAMS CEL_CL_PARAMS) {
	// Always compute derivatives across the full 2x2 quad before any non-uniform early return.
	float3 dpx = dfdx(p), dpy = dfdy(p);
	if (f.flags.x != SHADE_DIM_OVERWORLD || shadeDev(f, SHADE_DEV_FLAT_LIGHT)) {
		return float4(shadeVanillaOut(vanillaColor.rgb, L), vanillaColor.a);
	}
	float3 nf = cross(dpx, dpy);
	float3 n = nf * rsqrt(max(dot(nf, nf), 1e-30));
	// Orient flat face normal toward the camera (gl_Position/view-ray convention).
	if (dot(n, p) > 0.0) n = -n;
	half3 hn = half3(n);

	half3 albedo = shadeToLinear(half3(saturate(texel.rgb * rawColor.rgb)));
	int debug = f.flags.w;
	if (debug == 3) albedo = half3(0.45h);

	half block = half(saturate(light.x));
#ifdef SHADE_COLORLIGHT
	block = half(shadeSmoothBlock(cl, clLevels, f, p, n, float(block)));
#endif
	half sky = half(saturate(light.y));
	half3 an = abs(hn);
	bool axisAligned = max(max(an.x, an.y), an.z) > half(0.92);
	bool thin = isCutout && !axisAligned;
	bool foliage = isCutout && axisAligned;

	half shadow = shadeShadow(shadowMap, shadowCmp, f, p, hn, thin);
	float ex = shadeExposure(f, g);
	float nearW = shadeLook2Near(p, L);
	float2 wet = 0.0;
	if (L.wet.x + L.wet.z > 0.005) wet = shadeWetSurface(albedo, p, hn, sky, foliage, f, L, sr.weatherNoise);
	float3 radiance = shadeLit2(albedo, hn, sky, block, shadow, thin, foliage, f, L, nearW);
	if (wet.x + wet.y > 0.005) radiance = shadeWetLight(radiance, wet, p, hn, shadow, f, skyLut, skyLutSmplr);
	if (L.flash.w > 0.0) {
		radiance += float3(albedo) * L.flash.w * saturate(dot(n, L.flash.xyz)) * float(shadeSkyCurve(sky));
	}
#ifdef SHADE_DYNLIGHT
	// Dynamic lights (P6a): the irradiance volume, two trilinear fetches half a block in front of the face.
	radiance += float3(albedo) * f.ambientBlock.xyz * shadeDynamicLightsVol(dl, dlIrr, dlDir, p, n, thin, block);
#endif
#ifdef SHADE_COLORLIGHT
	float3 clAdd = shadeColorLightFrag(cl, clFine, clCoarse, f, p, n, float(block));
	radiance += float3(albedo) * f.ambientBlock.xyz * clAdd;
#endif
	float vanillaFog = shadeVanillaFog(p, fogRanges.xy, fogRanges.zw);
	float chunkFade = saturate(1.0 - chunkVis);
	radiance = shadeFogAir2(radiance, p, vanillaFog, chunkFade, skyLut, skyLutSmplr, f, L, &sr);
	float3 rgb = shadeFinish2(radiance, vanillaFog, f, L, ex);
	if (debug == 2) rgb = shadeVanillaOut(n * 0.5 + 0.5, L);
	if (debug == 1) rgb = shadeVanillaOut(float3(0.25 + 0.75 * float(shadow)), L);
	// 11: lit as usual, solid-block pixels whose derivative normal is not axis-aligned in pure red (edge-on derivative check)
	if (debug == 11 && !isCutout && max(max(abs(n.x), abs(n.y)), abs(n.z)) < 0.97) rgb = float3(1.0, 0.0, 0.0);
	if (debug == 9) rgb = shadeVanillaOut(float3(float(block)), L);                                  // vertex block light
	if (debug == 10) rgb = shadeVanillaOut(float3(dot(rawColor.rgb, float3(0.299, 0.587, 0.114))), L); // vertex colour (AO)
	if (debug == 13 || debug == 14) rgb = float3(0.0); // (the water views' black backdrop)
#ifdef SHADE_COLORLIGHT
	if (debug == 7 || debug == 8) {
		// 7: the coloured volume's raw light at this surface (1 = level 15); 8: the colour shift it adds (0.5 = none)
		float3 w = f.cameraFract.xyz + p + n * 0.5, wf = floor(w);
		int3 qi = int3(f.cameraBlock.xyz) + int3(wf);
		float3 raw = cl.fineMin.w != 0 ? shadeClSample(cl, clFine, qi, w - wf, false) : float3(0.0);
		// (7: red = the bound header is off / the fallback; green = vanilla block light; blue = the volume's light level / 15)
		float rawMax = max(raw.x, max(raw.y, raw.z));
		float rawLevel = rawMax > 0.0 ? saturate((15.0 + log2(rawMax)) / 15.0) : 0.0;
		rgb = debug == 7 ? shadeVanillaOut(float3(cl.fineMin.w == 0 ? 1.0 : 0.0, float(block), rawLevel), L)
		                 : shadeVanillaOut(saturate(clAdd * 2.0 + 0.5), L);
	}
#endif
	return float4(rgb, vanillaColor.a);
}

#endif
