// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/native/mcdynlight.m (coloured block light half)
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Coloured block light (Java side dev.celestia.metal.shade.light.ColorLights, shader side shaders/ported/colorlight.metal):
//   - two toroidal RGBA8 3D textures (fine: a cell per block, coarse: a cell per 4^3 blocks), spread by shade_cl_flood,
//   - one shared buffer of the cells' block ids the CPU writes in place (a section's 4096 bytes at a time),
//   - a ring of shared buffers with each frame's slot lists, and a ring of 256-byte headers (ShadeColorLights, 80 bytes).
// Bound on every render encoder native shading binds (cm_shade_bind_render_encoder -> cm_colorlight_bind_render_encoder):
//   buffer(30) ShadeColorLights   texture(26) fine volume   texture(27) coarse volume   texture(28) smooth block light (RG8)
// Celestia changes vs upstream: ARC; the header is a ring buffer slot instead of setBytes / setVertexBytes (Metal 4 has no
// setBytes, and in-flight frames keep their own header); Metal 4 compute through the shared argument table with an
// intra-encoder barrier between dependent dispatches and a producer barrier before the world passes; every allocation
// registered for Metal 4 residency; cm_flush_encoders before encoding compute; fragment-stage bindings.
#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

#define CL_RING_MAX 8
#define CL_HEADER 80
#define CL_HEADER_SLOT 256 // per ring slot (aligned for buffer offsets)

@interface CMColorLightState : NSObject {
@public
    id<MTLBuffer> lists[CL_RING_MAX];
    int32_t ringSize, headerSlot, listCap;
}
@property (nonatomic, strong) id<MTLTexture> fine, coarse, levelTex;
@property (nonatomic, strong) id<MTLBuffer> ids, headers, levels;
@property (nonatomic, strong) id<MTLComputePipelineState> floodPso, clearPso, uploadPso;
@end

@implementation CMColorLightState
@end

static id<MTLBuffer> cl_buffer(CMContext *ctx, NSUInteger bytes, NSString *label) {
    id<MTLBuffer> b = [ctx.device newBufferWithLength:MAX(bytes, (NSUInteger)16) options:MTLResourceStorageModeShared];
    if (!b) return nil;
    memset(b.contents, 0, b.length);
    if (ctx.debugLabels) b.label = label;
    cm_track_allocation(ctx, b);
    return b;
}

static id<MTLTexture> cl_texture_fmt(CMContext *ctx, MTLPixelFormat fmt, NSUInteger w, NSUInteger h, NSUInteger d, BOOL write,
                                     NSString *label) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType3D;
    td.pixelFormat = fmt;
    td.width = w;
    td.height = h;
    td.depth = d;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | (write ? MTLTextureUsageShaderWrite : 0);
    id<MTLTexture> t = [ctx.device newTextureWithDescriptor:td];
    if (!t) return nil;
    if (ctx.debugLabels) t.label = label;
    cm_track_allocation(ctx, t);
    return t;
}

static id<MTLTexture> cl_texture(CMContext *ctx, NSUInteger w, NSUInteger h, NSUInteger d, BOOL write, NSString *label) {
    return cl_texture_fmt(ctx, MTLPixelFormatRGBA8Unorm, w, h, d, write, label);
}

// fw x fh x fd / cw x ch x cd: the two textures (cells); cells: every slot's cells (the ids buffer's bytes); listCap: entries per
// frame list. 0 with the reason in err. The textures start undefined: the caller's first frame empties every slot.
int64_t cm_cl_new(int64_t ctxPtr, const char *source, int32_t fw, int32_t fh, int32_t fd, int32_t cw, int32_t ch, int32_t cd,
                  int64_t cells, int32_t listCap, int32_t ring, char *err, int32_t errCap) {
    if (!ctxPtr || !source || cells <= 0 || listCap <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.device.readWriteTextureSupport < MTLReadWriteTextureTier2) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "the GPU has no tier 2 read-write textures");
            return 0;
        }
        MTLCompileOptions *o = [MTLCompileOptions new];
        o.languageVersion = MTLLanguageVersion3_2;
        if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeRelaxed;
        NSError *e = nil;
        id<MTLLibrary> lib = [ctx.device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e];
        if (!lib) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "%s", e.localizedDescription.UTF8String ?: "compile failed");
            return 0;
        }
        id<MTLFunction> ff = [lib newFunctionWithName:@"shade_cl_flood"];
        id<MTLFunction> fc = [lib newFunctionWithName:@"shade_cl_clear"];
        id<MTLComputePipelineState> fp = ff ? [ctx.device newComputePipelineStateWithFunction:ff error:&e] : nil;
        id<MTLComputePipelineState> cp = fp && fc ? [ctx.device newComputePipelineStateWithFunction:fc error:&e] : nil;
        id<MTLFunction> fu = [lib newFunctionWithName:@"shade_bl_upload"];
        id<MTLComputePipelineState> up = cp && fu ? [ctx.device newComputePipelineStateWithFunction:fu error:&e] : nil;
        if (!fp || !cp || !up || fp.maxTotalThreadsPerThreadgroup < 512 || cp.maxTotalThreadsPerThreadgroup < 512
            || up.maxTotalThreadsPerThreadgroup < 512) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "colour volume kernels: %s",
                                            e ? e.localizedDescription.UTF8String : "missing or under 512 threads");
            return 0;
        }
        CMColorLightState *s = [CMColorLightState new];
        s.floodPso = fp;
        s.clearPso = cp;
        s.uploadPso = up;
        s->ringSize = ring < 2 ? 2 : ring > CL_RING_MAX ? CL_RING_MAX : ring;
        s->listCap = listCap;
        s.fine = cl_texture(ctx, (NSUInteger)fw, (NSUInteger)fh, (NSUInteger)fd, YES, @"CelestiaShade.ColorLightFine");
        s.coarse = cl_texture(ctx, (NSUInteger)cw, (NSUInteger)ch, (NSUInteger)cd, YES, @"CelestiaShade.ColorLightCoarse");
        s.ids = cl_buffer(ctx, (NSUInteger)cells, @"CelestiaShade.ColorLightBlocks");
        // Smooth block light: 2 bytes a fine cell (the fine window's slots come first in `cells`, 4096 cells each).
        NSUInteger fineCells = (NSUInteger)fw * (NSUInteger)fh * (NSUInteger)fd;
        s.levels = cl_buffer(ctx, fineCells * 2, @"CelestiaShade.BlockLightLevels");
        s.levelTex = cl_texture_fmt(ctx, MTLPixelFormatRG8Unorm, (NSUInteger)fw, (NSUInteger)fh, (NSUInteger)fd, YES,
                                    @"CelestiaShade.BlockLightVolume");
        s.headers = cl_buffer(ctx, (NSUInteger)CL_HEADER_SLOT * (NSUInteger)s->ringSize, @"CelestiaShade.ColorLightHeader");
        for (int i = 0; i < s->ringSize; i++) {
            s->lists[i] = cl_buffer(ctx, (NSUInteger)listCap * 4, @"CelestiaShade.ColorLightList");
            if (!s->lists[i]) break;
        }
        if (!s.fine || !s.coarse || !s.ids || !s.headers || !s.levels || !s.levelTex || !s->lists[s->ringSize - 1]) {
            if (err && errCap > 0) snprintf(err, (size_t)errCap, "colour volume textures / buffers (%lld cells) could not be allocated",
                                            (long long)cells);
            // (anything allocated is released by ARC; untrack what was tracked)
            id objs[6] = { s.fine, s.coarse, s.ids, s.headers, s.levels, s.levelTex };
            for (int i = 0; i < 6; i++) if (objs[i]) cm_untrack_allocation(ctx, objs[i]);
            for (int i = 0; i < s->ringSize; i++) if (s->lists[i]) cm_untrack_allocation(ctx, s->lists[i]);
            return 0;
        }
        cm_commit_residency_if_dirty(ctx);
        ctx.colorLightState = s;
        return (int64_t)(__bridge_retained void *)s;
    }
}

void cm_cl_free(int64_t ctxPtr, int64_t statePtr) {
    if (!statePtr) return;
    @autoreleasepool {
        CMColorLightState *s = (__bridge_transfer CMColorLightState *)(void *)statePtr;
        if (!ctxPtr) return;
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.colorLightState == s) ctx.colorLightState = nil;
        // Encoders already recorded may still reference these: release them only once in-flight work completes.
        uint64_t serial = atomic_load(&ctx->_nextSubmitSerial) + 1;
        for (int i = 0; i < s->ringSize; i++) {
            if (s->lists[i]) { cm_untrack_allocation(ctx, s->lists[i]); cm_retire_object(ctx, s->lists[i], serial); }
        }
        id objs[6] = { s.fine, s.coarse, s.ids, s.headers, s.levels, s.levelTex };
        for (int i = 0; i < 6; i++) {
            if (objs[i]) { cm_untrack_allocation(ctx, objs[i]); cm_retire_object(ctx, objs[i], serial); }
        }
    }
}

// The off stand-in (module off or failed): 1-texel textures and a zeroed header (fineMin.w = 0: the shaders leave at once).
int32_t cm_cl_fallback(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.colorLightFallback) return 1;
        CMColorLightState *s = [CMColorLightState new];
        s->ringSize = 1;
        s.fine = cl_texture(ctx, 1, 1, 1, NO, @"CelestiaShade.ColorLightFineOff");
        s.coarse = cl_texture(ctx, 1, 1, 1, NO, @"CelestiaShade.ColorLightCoarseOff");
        s.levelTex = cl_texture_fmt(ctx, MTLPixelFormatRG8Unorm, 1, 1, 1, NO, @"CelestiaShade.BlockLightVolumeOff");
        s.headers = cl_buffer(ctx, CL_HEADER_SLOT, @"CelestiaShade.ColorLightHeaderOff");
        if (!s.fine || !s.coarse || !s.levelTex || !s.headers) return 0;
        cm_commit_residency_if_dirty(ctx);
        ctx.colorLightFallback = s;
        return 1;
    }
}

int64_t cm_cl_ids(int64_t statePtr) {
    if (!statePtr) return 0;
    CMColorLightState *s = (__bridge CMColorLightState *)(void *)statePtr;
    return (int64_t)(uintptr_t)s.ids.contents;
}

int64_t cm_cl_levels(int64_t statePtr) {
    if (!statePtr) return 0;
    CMColorLightState *s = (__bridge CMColorLightState *)(void *)statePtr;
    return (int64_t)(uintptr_t)s.levels.contents;
}

int64_t cm_cl_list(int64_t statePtr, int32_t slot) {
    if (!statePtr) return 0;
    CMColorLightState *s = (__bridge CMColorLightState *)(void *)statePtr;
    return (int64_t)(uintptr_t)s->lists[(slot < 0 ? 0 : slot) % s->ringSize].contents;
}

// This frame's header into ring slot `slot` (bound from now on: render encoders opened after this call and cm_cl_frame get it;
// frames still in flight keep the slot they were bound with).
void cm_cl_header(int64_t statePtr, int32_t slot, const void *bytes) {
    if (!statePtr || !bytes) return;
    CMColorLightState *s = (__bridge CMColorLightState *)(void *)statePtr;
    s->headerSlot = (slot < 0 ? 0 : slot) % s->ringSize;
    memcpy((uint8_t *)s.headers.contents + (NSUInteger)s->headerSlot * CL_HEADER_SLOT, bytes, CL_HEADER);
}

void cm_colorlight_bind_render_encoder(CMContext *ctx) {
    if (!ctx || !ctx.activeRenderEnc) return;
    CMColorLightState *s = (CMColorLightState *)(ctx.colorLightState ?: ctx.colorLightFallback);
    if (!s) return;
    NSUInteger off = (NSUInteger)s->headerSlot * CL_HEADER_SLOT;
    if (ctx.metal4Active) {
        id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
        [at setAddress:s.headers.gpuAddress + off atIndex:CM_SHADE_BUF_COLORLIGHT];
        [at setTexture:s.fine.gpuResourceID atIndex:CM_SHADE_TEX_CL_FINE];
        [at setTexture:s.coarse.gpuResourceID atIndex:CM_SHADE_TEX_CL_COARSE];
        [at setTexture:s.levelTex.gpuResourceID atIndex:CM_SHADE_TEX_CL_LEVELS];
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        [enc setFragmentBuffer:s.headers offset:off atIndex:CM_SHADE_BUF_COLORLIGHT];
        [enc setFragmentTexture:s.fine atIndex:CM_SHADE_TEX_CL_FINE];
        [enc setFragmentTexture:s.coarse atIndex:CM_SHADE_TEX_CL_COARSE];
        [enc setFragmentTexture:s.levelTex atIndex:CM_SHADE_TEX_CL_LEVELS];
    }
    // These slots are outside the game's texture range; keep the per-encoder dedup cache truthful anyway.
    ctx->_boundTextures[CM_SHADE_TEX_CL_FINE] = (uintptr_t)(__bridge void *)s.fine;
    ctx->_boundTextures[CM_SHADE_TEX_CL_COARSE] = (uintptr_t)(__bridge void *)s.coarse;
    ctx->_boundTextures[CM_SHADE_TEX_CL_LEVELS] = (uintptr_t)(__bridge void *)s.levelTex;
}

// The frame's work, on the frame command buffer before the world passes: list slot `slot` holds `clears` slots to empty, then
// `fine` fine slots and `coarse` coarse ones to spread (fine first); the fine ones get `fineSteps` steps, the coarse ones one.
// Each dispatch reads the previous one's writes (Metal 3: a serial compute encoder; Metal 4: an intra-encoder barrier).
// Then `uploads` fine slots listed from entry `uploadOffset` get their smooth block light copied into the RG8 volume.
void cm_cl_frame(int64_t ctxPtr, int64_t statePtr, int32_t slot, int32_t clears, int32_t fine, int32_t coarse, int32_t fineSteps,
                 int32_t uploadOffset, int32_t uploads) {
    if (!ctxPtr || !statePtr || (clears <= 0 && fine + coarse <= 0 && uploads <= 0)) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMColorLightState *s = (__bridge CMColorLightState *)(void *)statePtr;
        id<MTLBuffer> list = s->lists[(slot < 0 ? 0 : slot) % s->ringSize];
        NSUInteger hoff = (NSUInteger)s->headerSlot * CL_HEADER_SLOT;
        MTLSize tg = MTLSizeMake(8, 8, 8);
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        if (ctx.metal4Active) {
            id<MTL4ComputeCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
            if (!enc) return;
            if (ctx.debugLabels) enc.label = @"CelestiaShade.ColorLight";
            id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4FragmentArgTable;
            [at setAddress:s.headers.gpuAddress + hoff atIndex:0];
            [at setAddress:s.ids.gpuAddress atIndex:2];
            [at setTexture:s.fine.gpuResourceID atIndex:0];
            [at setTexture:s.coarse.gpuResourceID atIndex:1];
            [at setTexture:s.levelTex.gpuResourceID atIndex:2];
            [at setAddress:s.levels.gpuAddress atIndex:4];
            BOOL first = YES;
            if (clears > 0) {
                [at setAddress:list.gpuAddress atIndex:3];
                [enc setArgumentTable:at];
                [enc setComputePipelineState:s.clearPso];
                [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)clears * 8, 1, 1) threadsPerThreadgroup:tg];
                first = NO;
            }
            if (fine + coarse > 0) {
                [at setAddress:list.gpuAddress + (MTLGPUAddress)clears * 4 atIndex:3];
                [enc setArgumentTable:at];
                [enc setComputePipelineState:s.floodPso];
                int steps = fine > 0 && fineSteps > 1 ? fineSteps : 1;
                for (int i = 0; i < steps; i++) {
                    if (!first) {
                        [enc barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch
                                     visibilityOptions:MTL4VisibilityOptionDevice];
                    }
                    first = NO;
                    NSUInteger n = (NSUInteger)(i == 0 ? fine + coarse : fine) * 8;
                    [enc dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:tg];
                }
            }
            if (uploads > 0) { // (writes only the levels volume: no barrier against the flood)
                [at setAddress:list.gpuAddress + (MTLGPUAddress)uploadOffset * 4 atIndex:3];
                [enc setArgumentTable:at];
                [enc setComputePipelineState:s.uploadPso];
                [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)uploads * 8, 1, 1) threadsPerThreadgroup:tg];
            }
            [enc barrierAfterStages:MTLStageDispatch
                  beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                  visibilityOptions:MTL4VisibilityOptionDevice];
            [enc endEncoding];
        } else {
            id<MTLComputeCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf computeCommandEncoder];
            if (!enc) return;
            if (ctx.debugLabels) enc.label = @"CelestiaShade.ColorLight";
            [enc setBuffer:s.headers offset:hoff atIndex:0];
            [enc setBuffer:s.ids offset:0 atIndex:2];
            [enc setTexture:s.fine atIndex:0];
            [enc setTexture:s.coarse atIndex:1];
            [enc setTexture:s.levelTex atIndex:2];
            [enc setBuffer:s.levels offset:0 atIndex:4];
            if (clears > 0) {
                [enc setComputePipelineState:s.clearPso];
                [enc setBuffer:list offset:0 atIndex:3];
                [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)clears * 8, 1, 1) threadsPerThreadgroup:tg];
            }
            if (fine + coarse > 0) {
                [enc setComputePipelineState:s.floodPso];
                [enc setBuffer:list offset:(NSUInteger)clears * 4 atIndex:3];
                [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)(fine + coarse) * 8, 1, 1) threadsPerThreadgroup:tg];
                for (int i = 1; i < fineSteps && fine > 0; i++)
                    [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)fine * 8, 1, 1) threadsPerThreadgroup:tg];
            }
            if (uploads > 0) {
                [enc setComputePipelineState:s.uploadPso];
                [enc setBuffer:list offset:(NSUInteger)uploadOffset * 4 atIndex:3];
                [enc dispatchThreadgroups:MTLSizeMake((NSUInteger)uploads * 8, 1, 1) threadsPerThreadgroup:tg];
            }
            [enc endEncoding];
        }
    }
}
