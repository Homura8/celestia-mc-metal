// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/sky.vs.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.

struct SkyIn { float3 Position [[attribute(0)]]; };
struct SkyOut {
	float4 position [[position]];
	float3 dir [[user(locn0)]];
	float3 vanilla [[user(locn1)]];
};

vertex SkyOut main0(SkyIn in [[stage_in]], uint vid [[vertex_id]],
                    constant ShadeFrame& sf [[buffer(CM_SHADE_BUF_FRAME)]],
                    constant DynamicTransforms& dt [[buffer(CELESTIA_BUF_DynamicTransforms)]],
                    constant Projection& pr [[buffer(CELESTIA_BUF_Projection)]])
{
	SkyOut out;
	if (in.Position.y < 0.0 || sf.flags.x != SHADE_DIM_OVERWORLD) {
		out.position = pr.ProjMat * dt.ModelViewMat * float4(in.Position, 1.0);
		out.position.y = -out.position.y;
		out.dir = in.Position + float3(0.0, 12.0, 0.0);
		out.vanilla = float3(1.0, length(in.Position), max(length(in.Position.xz), abs(in.Position.y)));
		return out;
	}
	uint corner = min(vid, 2u);
	float2 ndc = float2(corner == 1u ? 3.0 : -1.0, corner == 2u ? 3.0 : -1.0);
	out.dir = shadeViewRay(ndc, sf.invViewProj);
	out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
	out.vanilla = float3(0.0);
	return out;
}
