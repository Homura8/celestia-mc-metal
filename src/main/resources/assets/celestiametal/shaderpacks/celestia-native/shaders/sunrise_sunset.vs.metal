// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/sunrise_sunset.vs.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.

struct SunriseIn { float3 Position [[attribute(0)]]; float4 Color [[attribute(1)]]; };
struct SunriseOut { float4 gl_Position [[position]]; float4 vertexColor [[user(locn0)]]; };

vertex SunriseOut main0(SunriseIn in [[stage_in]],
                        constant ShadeFrame& sf [[buffer(CM_SHADE_BUF_FRAME)]],
                        constant DynamicTransforms& dt [[buffer(CELESTIA_BUF_DynamicTransforms)]],
                        constant Projection& pr [[buffer(CELESTIA_BUF_Projection)]])
{
	SunriseOut out;
	out.vertexColor = in.Color;
	if (sf.flags.x == SHADE_DIM_OVERWORLD) {
		out.gl_Position = SHADE_DROPPED;
		return out;
	}
	out.gl_Position = pr.ProjMat * dt.ModelViewMat * float4(in.Position, 1.0);
	out.gl_Position.y = -out.gl_Position.y;
	return out;
}
