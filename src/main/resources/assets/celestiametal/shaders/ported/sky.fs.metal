// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/sky.fs.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.

struct SkyOut {
	float4 position [[position]];
	float3 dir [[user(locn0)]];
	float3 vanilla [[user(locn1)]];
};

static float3 shadeSkyPixel(float3 dir, texture2d<half> skyLut, sampler skyLutSmplr, constant ShadeFrame &sf,
                            constant ShadeLook &sl, float ex, constant ShadeResources &sr) {
	float3 sky = shadeSkyBackground(dir, skyLut, skyLutSmplr, sf, sl, sr);
	float vanillaSky = dir.y <= 0.0 ? 1.0 : saturate(min(16.0 / max(dir.y, 1e-3), 512.0) / max(sf.fogSky.x, 1.0));
	return shadeFinish2(sky, vanillaSky, sf, sl, ex);
}

fragment float4 main0(SkyOut in [[stage_in]],
                      constant ShadeFrame& sf [[buffer(CM_SHADE_BUF_FRAME)]],
                      constant ShadeLook& sl [[buffer(CM_SHADE_BUF_LOOK)]],
                      constant ShadeGpu& sg [[buffer(CM_SHADE_BUF_GPU)]],
                      constant ShadeResources& sr [[buffer(CM_SHADE_BUF_RESOURCES)]],
                      texture2d<half> skyLut [[texture(CM_SHADE_TEX_SKY_LUT)]],
                      sampler skyLutSmplr [[sampler(CM_SHADE_SAMP_LINEAR)]],
                      constant Fog& fog [[buffer(CELESTIA_BUF_Fog)]],
                      constant DynamicTransforms& dt [[buffer(CELESTIA_BUF_DynamicTransforms)]])
{
	float ex = shadeExposure(sf, sg);
	if (sf.flags.x != SHADE_DIM_OVERWORLD) {
		float a = saturate(in.vanilla.y / max(fog.FogSkyEnd, 1e-3));
		float b = in.vanilla.z >= fog.FogSkyEnd ? 1.0 : 0.0;
		float fogValue = max(a, b);
		return float4(mix(shadeVanillaOut(dt.ColorModulator.rgb, sl), shadeVanillaOut(fog.FogColor.rgb, sl), fogValue * fog.FogColor.a),
			dt.ColorModulator.a);
	}
	float3 sky = shadeSkyPixel(normalize(in.dir), skyLut, skyLutSmplr, sf, sl, ex, sr);
	if (in.vanilla.x > 0.5) {
		float a = saturate(in.vanilla.y / max(fog.FogSkyEnd, 1e-3));
		float b = in.vanilla.z >= fog.FogSkyEnd ? 1.0 : 0.0;
		float fogValue = max(a, b);
		return float4(mix(shadeVanillaOut(dt.ColorModulator.rgb, sl), sky, fogValue), dt.ColorModulator.a);
	}
	return float4(sky, 1.0);
}
