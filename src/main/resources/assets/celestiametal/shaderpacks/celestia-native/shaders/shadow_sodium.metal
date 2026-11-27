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
// Depth-only replay of Sodium 0.9.x solid and cutout terrain from the light into one slice of a 2D depth array.
#include <metal_stdlib>
using namespace metal;

// firstVertex: chunk's first vertex in its arena; packed: (quads - 1) in bits 0-5, region index in bits 6-31.
struct ShadowChunk { uint firstVertex; uint packed; };
// Camera-relative region origin, 16 bytes.
struct ShadowRegion { packed_float3 origin; float pad; };
// Per cascade: camera-relative world -> light clip, and a constant depth bias (depth units, pushes casters away from the light).
struct ShadowCascade { float4x4 viewProj; float depthBias; float pad0; float pad1; float pad2; };

struct ShadowOut { float4 pos [[position]]; };
struct ShadowCutoutOut { float4 pos [[position]]; float2 uv; half alpha; };

static float3 shadowVertexPosition(const device uint *v, ShadowRegion region)
{
    uint3 hi = (uint3(v[0]) >> uint3(0u, 10u, 20u)) & 0x3FFu;
    uint3 lo = (uint3(v[1]) >> uint3(0u, 10u, 20u)) & 0x3FFu;
    float3 model = float3((hi << 10u) | lo) * (32.0 / 1048576.0) - 8.0;
    uint section = v[4] >> 24;
    float3 sectionOffset = float3(uint3(section >> 5, section, section >> 2) & uint3(7u, 3u, 7u)) * 16.0;
    return model + sectionOffset + float3(region.origin);
}

// Returns pointer to the vertex inside Sodium's 20-byte packed vertex buffer, or nullptr for padding quads.
static const device uint *shadowVertex(uint vid, uint iid, const device uint *arena, const device ShadowChunk *chunks,
                                       thread uint &region)
{
    ShadowChunk c = chunks[iid];
    uint quad = vid >> 2;
    if (quad > (c.packed & 63u)) return nullptr;
    region = c.packed >> 6;
    return arena + (c.firstVertex + vid) * 5u;
}

vertex ShadowOut shadow_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device uint *arena [[buffer(0)]],
                           const device ShadowChunk *chunks [[buffer(1)]], const device ShadowRegion *regions [[buffer(2)]],
                           constant ShadowCascade &cascade [[buffer(3)]])
{
    ShadowOut out;
    uint region = 0;
    const device uint *v = shadowVertex(vid, iid, arena, chunks, region);
    if (v == nullptr) {
        out.pos = float4(0.0);
        return out;
    }
    float3 p = shadowVertexPosition(v, regions[region]);
    out.pos = cascade.viewProj * float4(p, 1.0);
    out.pos.z -= cascade.depthBias * out.pos.w;
    return out;
}

vertex ShadowCutoutOut shadow_cutout_vs(uint vid [[vertex_id]], uint iid [[instance_id]], const device uint *arena [[buffer(0)]],
                                        const device ShadowChunk *chunks [[buffer(1)]], const device ShadowRegion *regions [[buffer(2)]],
                                        constant ShadowCascade &cascade [[buffer(3)]])
{
    ShadowCutoutOut out;
    uint region = 0;
    const device uint *v = shadowVertex(vid, iid, arena, chunks, region);
    if (v == nullptr) {
        out.pos = float4(0.0);
        out.uv = float2(0.0);
        out.alpha = 0.0h;
        return out;
    }
    float3 p = shadowVertexPosition(v, regions[region]);
    out.pos = cascade.viewProj * float4(p, 1.0);
    out.pos.z -= cascade.depthBias * out.pos.w;
    uint tex = v[3];
    out.uv = float2(uint2(tex, tex >> 16) & 0x7FFFu) * (1.0 / 32768.0);
    out.alpha = half(float(v[2] >> 24) * (1.0 / 255.0));
    return out;
}

fragment void shadow_cutout_fs(ShadowCutoutOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler s [[sampler(0)]])
{
    float a = atlas.sample(s, in.uv, level(0.0)).w * float(in.alpha);
    if (a < 0.5) discard_fragment();
}
