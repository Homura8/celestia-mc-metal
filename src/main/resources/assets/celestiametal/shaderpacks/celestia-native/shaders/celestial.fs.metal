// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/celestial.fs.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.

struct CelestialOut { float4 gl_Position [[position]]; float2 texCoord0 [[user(locn0)]]; float sunK [[user(locn1)]]; float3 dir [[user(locn2)]]; };

fragment float4 main0(CelestialOut in [[stage_in]],
                      constant ShadeFrame& sf [[buffer(CM_SHADE_BUF_FRAME)]],
                      constant ShadeLook& sl [[buffer(CM_SHADE_BUF_LOOK)]],
                      constant ShadeGpu& sg [[buffer(CM_SHADE_BUF_GPU)]],
                      constant ShadeResources& sr [[buffer(CM_SHADE_BUF_RESOURCES)]],
                      constant DynamicTransforms& dt [[buffer(CELESTIA_BUF_DynamicTransforms)]],
                      texture2d<float> Sampler0 [[texture(CELESTIA_TEX_Sampler0)]],
                      sampler Sampler0Smplr [[sampler(CELESTIA_SAMP_Sampler0)]])
{
	float4 color = Sampler0.sample(Sampler0Smplr, in.texCoord0);
	if (color.a == 0.0) discard_fragment();
	if (in.sunK < 0.5 || sl.user4.y < 0.5) {
		float transmission = shadeCloudsScreen(normalize(in.dir), sl, sr.cloudScreen).a;
		return float4(shadeVanillaOut((color * dt.ColorModulator).rgb, sl), color.a * dt.ColorModulator.a * transmission);
	}
#ifdef MCOPT_HDR
	float3 dir = normalize(in.dir);
	float3 sunLight = sf.lightDirWorld.w > 0.5 ? sf.sunColor.rgb : float3(0.0);
	float above = smoothstep(-0.03, 0.01, dir.y);
	float3 tex = pow(max(color.rgb * dt.ColorModulator.rgb, 0.0), float3(2.2));
	float3 rad = sunLight * (sl.user4.y * (1.0 - 0.9 * sf.weather.x)) * tex * above;
	float4 clouds = shadeCloudDev(sl, SHADE_CLOUD_DEV_NO_SKY) ? float4(0.0, 0.0, 0.0, 1.0) : shadeCloudsScreen(dir, sl, sr.cloudScreen);
	return float4(shadeOut(rad * clouds.a, sf, shadeExposure(sf, sg)), color.a * dt.ColorModulator.a);
#else
	return color * dt.ColorModulator;
#endif
}
