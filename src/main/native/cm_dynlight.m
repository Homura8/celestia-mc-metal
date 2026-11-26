// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/native/mcdynlight.m (dynamic-light half)
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Dynamic lights for the ported shader suite (Java side dev.celestia.metal.shade.light.DynLights, shader side
// shaders/ported/dynlight.metal and dynlight_vis.metal):
//   - a ring of shared buffers holding each frame's ShadeDynLights (lights + light grid, written by the CPU in place),
//   - the block occupancy around the camera (128^3 bits) copied into the next slot of a ring on frames that need it,
//   - the visibility volumes: a 3D R8 texture, 32 x 32 x (32 x slabs), one slab per occluded light (shade_dl_vis / flood),
//   - the irradiance volume (rgb light RG11B10F, mean direction RGBA8Snorm), computed before the world passes (shade_dl_irr).
// Bound on every render encoder native shading binds (cm_shade_bind_render_encoder -> cm_dynlight_bind_render_encoder):
//   buffer(29) ShadeDynLights   texture(23) visibility   texture(24) irradiance   texture(25) light direction
// Celestia changes vs upstream: ARC; Celestia slot map (upstream buffer 24 = our ShadeFrame); Metal 4 compute through the
// shared argument table with producer barriers and kernel parameters in a ring buffer (MTL4 compute encoders have no
// setBytes); every allocation registered for Metal 4 residency; cm_flush_encoders before encoding compute.
#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

#define DL_RING_MAX 8
#define DL_FLOOD_WORDS 6728 // dynlight_vis.metal DL_FWORDS: 32 x 29 x 29 bytes
#define DL_PARAM_SLOT_BYTES 8192 // >= sizeof(DlVisParams) and the irradiance box, per ring slot (256-aligned)

@interface CMDynLightState : NSObject {
@public
    id<MTLBuffer> ring[DL_RING_MAX];
    id<MTLBuffer> occupancy[DL_RING_MAX];
    int32_t ringSize, slot, occSlot, occBytes, slabs, paramSlot;
}
@property (nonatomic, strong) id<MTLTexture> vis;
@property (nonatomic, strong) id<MTLTexture> irr;
@property (nonatomic, strong) id<MTLTexture> dir;
@property (nonatomic, strong) id<MTLBuffer> ways;
@property (nonatomic, strong) id<MTLBuffer> params;  // ring of kernel parameter blocks (stand-in for setBytes)
@property (nonatomic, strong) id<MTLComputePipelineState> visPso, irrPso, floodPso, floodOutPso;
@end

@implementation CMDynLightState
@end

static id<MTLBuffer> dl_buffer(CMContext *ctx, NSUInteger bytes, NSString *label) {
    id<MTLBuffer> b = [ctx.device newBufferWithLength:MAX(bytes, (NSUInteger)16)
                                              options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    if (!b) return nil;
    memset(b.contents, 0, b.length);
    if (ctx.debugLabels) b.label = label;
    cm_track_allocation(ctx, b);
    return b;
}

static id<MTLTexture> dl_texture3d(CMContext *ctx, MTLPixelFormat fmt, NSUInteger w, NSUInteger h, NSUInteger d,
                                   MTLTextureUsage usage, NSString *label) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = fmt;
    td.width = w;
    td.height = h;
    td.depth = d;
    td.storageMode = MTLStorageModePrivate;
    td.usage = usage;
    id<MTLTexture> t = [ctx.device newTextureWithDescriptor:td];
    if (!t) return nil;
    if (ctx.debugLabels) t.label = label;
    cm_track_allocation(ctx, t);
    return t;
}

static id<MTLComputePipelineState> dl_pso(CMContext *ctx, id<MTLLibrary> lib, NSString *name, NSError **err) {
    id<MTLFunction> fn = [lib newFunctionWithName:name];
    return fn ? [ctx.device newComputePipelineStateWithFunction:fn error:err] : nil;
}

int64_t cm_dl_new(int64_t ctxPtr, const char *source, int32_t bytes, int32_t ring, int32_t slabs, int32_t occBytes,
                  int32_t irrW, int32_t irrH, int32_t irrD, char *err, int32_t errCap) {
    if (!ctxPtr || !source || bytes <= 0 || occBytes <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLCompileOptions *o = [MTLCompileOptions new];
        o.languageVersion = MTLLanguageVersion3_2;
        if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeRelaxed;
        NSError *e = nil;
        id<MTLLibrary> lib = [ctx.device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e];
        if (!lib) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "%s", e.localizedDescription.UTF8String ?: "compile failed");
            return 0;
        }
        CMDynLightState *s = [CMDynLightState new];
        s.visPso = dl_pso(ctx, lib, @"shade_dl_vis", &e);
        s.irrPso = s.visPso ? dl_pso(ctx, lib, @"shade_dl_irr", &e) : nil;
        if (!s.visPso || !s.irrPso) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "%s", e ? e.localizedDescription.UTF8String : "missing kernel");
            return 0;
        }
        // The flood fill (27 KB threadgroup memory per volume) is optional: without it volumes stay rays.
        e = nil;
        s.floodPso = dl_pso(ctx, lib, @"shade_dl_flood", &e);
        s.floodOutPso = s.floodPso ? dl_pso(ctx, lib, @"shade_dl_flood_out", &e) : nil;
        if (!s.floodOutPso) s.floodPso = nil;

        s->ringSize = ring < 2 ? 2 : ring > DL_RING_MAX ? DL_RING_MAX : ring;
        s->occBytes = occBytes;
        s->slabs = slabs < 1 ? 1 : slabs > 64 ? 64 : slabs;
        for (int i = 0; i < s->ringSize; i++) {
            s->ring[i] = dl_buffer(ctx, (NSUInteger)bytes, @"CelestiaShade.DynLights");
            s->occupancy[i] = dl_buffer(ctx, (NSUInteger)occBytes, @"CelestiaShade.DynLightOccupancy");
            if (!s->ring[i] || !s->occupancy[i]) return 0;
        }
        s.params = dl_buffer(ctx, (NSUInteger)DL_PARAM_SLOT_BYTES * 2 * (NSUInteger)s->ringSize, @"CelestiaShade.DynLightParams");
        if (s.floodPso) {
            id<MTLBuffer> ways = [ctx.device newBufferWithLength:(NSUInteger)s->slabs * DL_FLOOD_WORDS * 4
                                                         options:MTLResourceStorageModePrivate];
            if (ways) {
                if (ctx.debugLabels) ways.label = @"CelestiaShade.DynLightFlood";
                cm_track_allocation(ctx, ways);
                s.ways = ways;
            } else {
                s.floodPso = nil;
                s.floodOutPso = nil;
            }
        }
        MTLTextureUsage rw = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        s.vis = dl_texture3d(ctx, MTLPixelFormatR8Unorm, 32, 32, 32 * (NSUInteger)s->slabs, rw, @"CelestiaShade.DynLightVisibility");
        // Half-bandwidth volumes (upstream 2.0.1): irradiance is non-negative RGB, direction is [-1,1]^3 + [0,1].
        s.irr = dl_texture3d(ctx, MTLPixelFormatRG11B10Float, (NSUInteger)irrW, (NSUInteger)irrH, (NSUInteger)irrD, rw,
                             @"CelestiaShade.DynLightIrradiance");
        s.dir = dl_texture3d(ctx, MTLPixelFormatRGBA8Snorm, (NSUInteger)irrW, (NSUInteger)irrH, (NSUInteger)irrD, rw,
                             @"CelestiaShade.DynLightDirection");
        if (!s.params || !s.vis || !s.irr || !s.dir) return 0;
        cm_commit_residency_if_dirty(ctx);
        ctx.dynLightState = s;
        return (int64_t)(__bridge_retained void *)s;
    }
}

void cm_dl_free(int64_t ctxPtr, int64_t statePtr) {
    if (!statePtr) return;
    @autoreleasepool {
        CMDynLightState *s = (__bridge_transfer CMDynLightState *)(void *)statePtr;
        if (!ctxPtr) return;
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.dynLightState == s) ctx.dynLightState = nil;
        // Encoders already recorded may still reference these: release them only once in-flight work completes.
        uint64_t serial = atomic_load(&ctx->_nextSubmitSerial) + 1;
        for (int i = 0; i < s->ringSize; i++) {
            if (s->ring[i]) { cm_untrack_allocation(ctx, s->ring[i]); cm_retire_object(ctx, s->ring[i], serial); }
            if (s->occupancy[i]) { cm_untrack_allocation(ctx, s->occupancy[i]); cm_retire_object(ctx, s->occupancy[i], serial); }
        }
        id objs[5] = { s.params, s.ways, s.vis, s.irr, s.dir };
        for (int i = 0; i < 5; i++) {
            if (objs[i]) { cm_untrack_allocation(ctx, objs[i]); cm_retire_object(ctx, objs[i], serial); }
        }
    }
}

int64_t cm_dl_contents(int64_t statePtr, int32_t slot) {
    if (!statePtr) return 0;
    CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
    return slot >= 0 && slot < s->ringSize ? (int64_t)(uintptr_t)s->ring[slot].contents : 0;
}

// The CPU's block occupancy (occBytes at src) into the next occupancy slot, which cm_dl_vis reads from now on. The ring
// (more slots than frames in flight) keeps the slot a frame still on the GPU reads untouched.
void cm_dl_occupancy(int64_t statePtr, const void *src) {
    if (!statePtr || !src) return;
    CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
    s->occSlot = (s->occSlot + 1) % s->ringSize;
    memcpy(s->occupancy[s->occSlot].contents, src, (size_t)s->occBytes);
}

// Zeroed ShadeDynLights and 1-voxel volumes bound when the module is off or failed, so shaders that declare the slots
// never read stale argument-table entries. Returns 1 when available.
int32_t cm_dl_fallback(int64_t ctxPtr, int32_t bytes) {
    if (!ctxPtr || bytes <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.dynLightFallback) return 1;
        CMDynLightState *s = [CMDynLightState new];
        s->ringSize = 1;
        s->ring[0] = dl_buffer(ctx, (NSUInteger)bytes, @"CelestiaShade.DynLightsOff");
        s.vis = dl_texture3d(ctx, MTLPixelFormatR8Unorm, 1, 1, 1, MTLTextureUsageShaderRead, @"CelestiaShade.DynLightVisOff");
        s.irr = dl_texture3d(ctx, MTLPixelFormatRG11B10Float, 1, 1, 1, MTLTextureUsageShaderRead, @"CelestiaShade.DynLightIrrOff");
        s.dir = dl_texture3d(ctx, MTLPixelFormatRGBA8Snorm, 1, 1, 1, MTLTextureUsageShaderRead, @"CelestiaShade.DynLightDirOff");
        if (!s->ring[0] || !s.vis || !s.irr || !s.dir) return 0;
        cm_commit_residency_if_dirty(ctx);
        ctx.dynLightFallback = s;
        return 1;
    }
}

void cm_dl_slot(int64_t statePtr, int32_t slot) {
    if (!statePtr) return;
    CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
    if (slot >= 0 && slot < s->ringSize) {
        s->slot = slot;
        s->paramSlot = slot;
    }
}

int32_t cm_dl_has_flood(int64_t statePtr) {
    if (!statePtr) return 0;
    CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
    return s.floodPso && s.floodOutPso && s.ways ? 1 : 0;
}

void cm_dynlight_bind_render_encoder(CMContext *ctx) {
    if (!ctx || !ctx.activeRenderEnc) return;
    CMDynLightState *s = (CMDynLightState *)(ctx.dynLightState ?: ctx.dynLightFallback);
    if (!s) return;
    id<MTLBuffer> b = s->ring[s->slot];
    if (ctx.metal4Active) {
        id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
        [at setAddress:b.gpuAddress atIndex:CM_SHADE_BUF_DYNLIGHTS];
        [at setTexture:s.vis.gpuResourceID atIndex:CM_SHADE_TEX_DL_VIS];
        [at setTexture:s.irr.gpuResourceID atIndex:CM_SHADE_TEX_DL_IRR];
        [at setTexture:s.dir.gpuResourceID atIndex:CM_SHADE_TEX_DL_DIR];
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        [enc setVertexBuffer:b offset:0 atIndex:CM_SHADE_BUF_DYNLIGHTS];
        [enc setFragmentBuffer:b offset:0 atIndex:CM_SHADE_BUF_DYNLIGHTS];
        [enc setVertexTexture:s.vis atIndex:CM_SHADE_TEX_DL_VIS];
        [enc setFragmentTexture:s.vis atIndex:CM_SHADE_TEX_DL_VIS];
        [enc setFragmentTexture:s.irr atIndex:CM_SHADE_TEX_DL_IRR];
        [enc setFragmentTexture:s.dir atIndex:CM_SHADE_TEX_DL_DIR];
    }
    // These slots are outside the game's texture range; keep the per-encoder dedup cache truthful anyway.
    ctx->_boundTextures[CM_SHADE_TEX_DL_VIS] = (uintptr_t)(__bridge void *)s.vis;
    ctx->_boundTextures[CM_SHADE_TEX_DL_IRR] = (uintptr_t)(__bridge void *)s.irr;
    ctx->_boundTextures[CM_SHADE_TEX_DL_DIR] = (uintptr_t)(__bridge void *)s.dir;
}

// One compute dispatch on the frame's command buffer. Buffers are (buffer, offset) pairs bound at indices 0..n-1, textures at
// 0..m-1. Metal 4: through the shared argument table, ending with a producer barrier (MTL4 has no automatic hazard tracking).
static void dl_dispatch(CMContext *ctx, id<MTLComputePipelineState> pso,
                        id<MTLBuffer> __unsafe_unretained *bufs, const NSUInteger *offs, int nb,
                        id<MTLTexture> __unsafe_unretained *texs, int nt,
                        MTLSize groups, MTLSize threads, NSString *label) {
    if (ctx.metal4Active) {
        id<MTL4ComputeCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
        if (!enc) return;
        if (ctx.debugLabels) enc.label = label;
        [enc setComputePipelineState:pso];
        id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4FragmentArgTable;
        for (int i = 0; i < nb; i++) if (bufs[i]) [at setAddress:bufs[i].gpuAddress + offs[i] atIndex:(NSUInteger)i];
        for (int i = 0; i < nt; i++) if (texs[i]) [at setTexture:texs[i].gpuResourceID atIndex:(NSUInteger)i];
        [enc setArgumentTable:at];
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
        [enc barrierAfterStages:MTLStageDispatch
              beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
              visibilityOptions:MTL4VisibilityOptionDevice];
        [enc endEncoding];
    } else {
        id<MTLComputeCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf computeCommandEncoder];
        if (!enc) return;
        if (ctx.debugLabels) enc.label = label;
        [enc setComputePipelineState:pso];
        for (int i = 0; i < nb; i++) if (bufs[i]) [enc setBuffer:bufs[i] offset:offs[i] atIndex:(NSUInteger)i];
        for (int i = 0; i < nt; i++) if (texs[i]) [enc setTexture:texs[i] atIndex:(NSUInteger)i];
        [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
        [enc endEncoding];
    }
}

static NSUInteger dl_param_offset(CMDynLightState *s, int which) {
    return ((NSUInteger)s->paramSlot * 2 + (NSUInteger)which) * DL_PARAM_SLOT_BYTES;
}

// This frame's visibility volumes (params: DlVisParams, volumes of them), before the world passes. info.y = 1 floods light
// through air (shade_dl_flood: a threadgroup per volume, then shade_dl_flood_out per voxel), else traces rays (shade_dl_vis).
void cm_dl_vis(int64_t ctxPtr, int64_t statePtr, const void *params, int32_t length, int32_t volumes) {
    if (!ctxPtr || !statePtr || !params || length <= 0 || volumes <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
        if (volumes > s->slabs) volumes = s->slabs;
        if (length > DL_PARAM_SLOT_BYTES) length = DL_PARAM_SLOT_BYTES;
        BOOL flood = length >= 8 && ((const uint32_t *)params)[1] == 1u && cm_dl_has_flood(statePtr);
        NSUInteger off = dl_param_offset(s, 0);
        memcpy((uint8_t *)s.params.contents + off, params, (size_t)length);
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        id<MTLBuffer> __unsafe_unretained bufs[3] = { s.params, s->occupancy[s->occSlot], s.ways };
        NSUInteger offs[3] = { off, 0, 0 };
        id<MTLTexture> __unsafe_unretained texs[1] = { s.vis };
        MTLSize visGrid = MTLSizeMake(32 / 8, 32 / 8, (NSUInteger)(32 * volumes) / 4);
        if (flood) {
            NSUInteger n = s.floodPso.maxTotalThreadsPerThreadgroup;
            n = n >= 1024 ? 1024 : n / 32 * 32;
            if (n < 32) n = 32;
            dl_dispatch(ctx, s.floodPso, bufs, offs, 3, texs, 0, MTLSizeMake((NSUInteger)volumes, 1, 1),
                        MTLSizeMake(n, 1, 1), @"CelestiaShade.DynLightFlood");
            dl_dispatch(ctx, s.floodOutPso, bufs, offs, 3, texs, 1, visGrid, MTLSizeMake(8, 8, 4),
                        @"CelestiaShade.DynLightFloodOut");
        } else {
            dl_dispatch(ctx, s.visPso, bufs, offs, 2, texs, 1, visGrid, MTLSizeMake(8, 8, 4),
                        @"CelestiaShade.DynLightVisibility");
        }
    }
}

// The irradiance volume from this frame's lights and visibility slabs, after cm_dl_vis: only the voxel box
// (x0, y0, z0) + (w, h, d) is rewritten (the lights' reach united with last frame's box by the caller).
void cm_dl_irr(int64_t ctxPtr, int64_t statePtr, int32_t x0, int32_t y0, int32_t z0, int32_t w, int32_t h, int32_t d) {
    if (!ctxPtr || !statePtr || w <= 0 || h <= 0 || d <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMDynLightState *s = (__bridge CMDynLightState *)(void *)statePtr;
        NSUInteger off = dl_param_offset(s, 1);
        uint32_t box[4] = { (uint32_t)x0, (uint32_t)y0, (uint32_t)z0, 0 };
        memcpy((uint8_t *)s.params.contents + off, box, sizeof(box));
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        id<MTLBuffer> __unsafe_unretained bufs[2] = { s->ring[s->slot], s.params };
        NSUInteger offs[2] = { 0, off };
        id<MTLTexture> __unsafe_unretained texs[3] = { s.vis, s.irr, s.dir };
        MTLSize groups = MTLSizeMake(((NSUInteger)w + 7) / 8, ((NSUInteger)h + 7) / 8, ((NSUInteger)d + 3) / 4);
        dl_dispatch(ctx, s.irrPso, bufs, offs, 2, texs, 3, groups, MTLSizeMake(8, 8, 4), @"CelestiaShade.DynLightIrradiance");
    }
}
