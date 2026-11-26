// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/resources/mcopt/shade/shadow.metal
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Depth-only replay of vanilla Minecraft 26.3 section geometry (DefaultVertexFormat.BLOCK, 28-byte stride)
// from the light into one slice of a 2D depth array.
#include <metal_stdlib>
using namespace metal;

struct ShadowCascade { float4x4 viewProj; float depthBias; float pad0; float pad1; float pad2; };
struct ShadowSectionOrigin { float4 origin; };

struct ShadowOut { float4 pos [[position]]; };
struct ShadowCutoutOut { float4 pos [[position]]; float2 uv; half alpha; };

vertex ShadowOut shadow_vanilla_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device uchar *verts [[buffer(0)]],
                                   constant ShadowCascade &cascade [[buffer(3)]],
                                   const device ShadowSectionOrigin *origins [[buffer(4)]])
{
    const device uchar *v = verts + vid * 28u;
    float3 p = float3(*(const device packed_float3 *)v) + origins[iid].origin.xyz;
    ShadowOut out;
    out.pos = cascade.viewProj * float4(p, 1.0);
    out.pos.z -= cascade.depthBias * out.pos.w;
    return out;
}

vertex ShadowCutoutOut shadow_vanilla_cutout_vs(uint vid [[vertex_id]], uint iid [[instance_id]],
                                                const device uchar *verts [[buffer(0)]],
                                                constant ShadowCascade &cascade [[buffer(3)]],
                                                const device ShadowSectionOrigin *origins [[buffer(4)]])
{
    const device uchar *v = verts + vid * 28u;
    float3 p = float3(*(const device packed_float3 *)v) + origins[iid].origin.xyz;
    ShadowCutoutOut out;
    out.pos = cascade.viewProj * float4(p, 1.0);
    out.pos.z -= cascade.depthBias * out.pos.w;
    out.uv = float2(*(const device packed_float2 *)(v + 16u));
    out.alpha = half(float(v[15]) * (1.0 / 255.0));
    return out;
}

fragment void shadow_vanilla_cutout_fs(ShadowCutoutOut in [[stage_in]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler s [[sampler(0)]])
{
    float a = atlas.sample(s, in.uv, level(0.0)).w * float(in.alpha);
    if (a < 0.5) discard_fragment();
}
