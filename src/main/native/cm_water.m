// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/native/mcwater.m
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
//
// Native water support for P3a+: scene color+depth copy on switch to translucent terrain,
// 3-pass RG16Float depth pyramid for exact hierarchical SSR, wave/detail mipmap generation,
// and ShadeWaterParams + water texture bindings for Metal 4 & Metal 3 render encoders.

#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

@interface CMPipelineBox : NSObject
@property (nonatomic, strong) id<MTLRenderPipelineState> state;
@property (nonatomic, strong) id<MTLDepthStencilState> depthState;
@property (nonatomic) MTLCullMode cullMode;
@property (nonatomic) MTLTriangleFillMode fillMode;
@property (nonatomic) float depthBiasSlope;
@property (nonatomic) float depthBiasConst;
@property (nonatomic) uint32_t depthKey;
@end

static BOOL water_tex_matches_attachments(id<MTLTexture> tex, const int64_t *colorViewPtrs, int32_t colorCount) {
    if (!tex || !colorViewPtrs || colorCount <= 0) return NO;
    id<MTLTexture> parent = tex.parentTexture;
    for (int32_t i = 0; i < colorCount; i++) {
        if (!colorViewPtrs[i]) continue;
        id<MTLTexture> cv = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
        if (cv == tex || cv.parentTexture == tex || (parent && (cv == parent || cv.parentTexture == parent))) {
            return YES;
        }
    }
    return NO;
}

static void ensure_water_dummies(CMContext *ctx) {
    if (!ctx.waterDummyHalf) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:1 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [ctx.device newTextureWithDescriptor:td];
        if (t) {
            if (ctx.debugLabels) t.label = @"CelestiaWater.DummyHalf";
            cm_track_allocation(ctx, t);
            ctx.waterDummyHalf = t;
        }
    }
    if (!ctx.waterDummyDepth) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                      width:1 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [ctx.device newTextureWithDescriptor:td];
        if (t) {
            if (ctx.debugLabels) t.label = @"CelestiaWater.DummyDepth";
            cm_track_allocation(ctx, t);
            ctx.waterDummyDepth = t;
        }
    }
    if (!ctx.waterDummyFloat) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                      width:1 height:1 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [ctx.device newTextureWithDescriptor:td];
        if (t) {
            uint32_t zero = 0;
            [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&zero bytesPerRow:4];
            if (ctx.debugLabels) t.label = @"CelestiaWater.DummyPyr";
            cm_track_allocation(ctx, t);
            ctx.waterDummyFloat = t;
        }
    }
    if (!ctx.waterDummyParamsBuf) {
        id<MTLBuffer> b = [ctx.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        if (b) {
            memset(b.contents, 0, 256);
            if (ctx.debugLabels) b.label = @"CelestiaWater.DummyParams";
            cm_track_allocation(ctx, b);
            ctx.waterDummyParamsBuf = b;
        }
    }
    cm_commit_residency_if_dirty(ctx);
}

static id<MTLTexture> ensure_copy_tex(CMContext *ctx, id<MTLTexture> cur, MTLPixelFormat fmt,
                                      NSUInteger w, NSUInteger h, NSString *label) {
    if (cur && cur.width == w && cur.height == h && cur.pixelFormat == fmt) {
        return cur;
    }
    if (cur) {
        cm_retire_object(ctx, cur, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [ctx.device newTextureWithDescriptor:td];
    if (tex) {
        if (ctx.debugLabels) tex.label = label;
        cm_track_allocation(ctx, tex);
    }
    return tex;
}

static id<MTLTexture> ensure_pyr_tex(CMContext *ctx, id<MTLTexture> cur, NSUInteger w, NSUInteger h, NSString *label) {
    if (cur && cur.width == w && cur.height == h && cur.pixelFormat == MTLPixelFormatRG16Float) {
        return cur;
    }
    if (cur) {
        cm_retire_object(ctx, cur, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> tex = [ctx.device newTextureWithDescriptor:td];
    if (tex) {
        if (ctx.debugLabels) tex.label = label;
        cm_track_allocation(ctx, tex);
    }
    return tex;
}

void cm_water_bind_render_encoder(CMContext *ctx, const int64_t *colorViewPtrs, int32_t colorCount) {
    if (!ctx || !ctx.activeRenderEnc) return;
    ensure_water_dummies(ctx);

    BOOL enabled = ctx.waterEnabled;
    BOOL copyValid = enabled && ctx.waterCopyValid && ctx.waterSceneCopy && ctx.waterDepthCopy;

    id<MTLBuffer> pBuf = (enabled && ctx.waterParamsBuf) ? (id<MTLBuffer>)ctx.waterParamsBuf : ctx.waterDummyParamsBuf;
    uint64_t pOff = (enabled && ctx.waterParamsBuf) ? ctx.waterParamsOffset : 0ULL;

    id<MTLTexture> sceneTex = (copyValid && !water_tex_matches_attachments(ctx.waterSceneCopy, colorViewPtrs, colorCount))
        ? ctx.waterSceneCopy : ctx.waterDummyHalf;
    id<MTLTexture> depthTex = (copyValid && !water_tex_matches_attachments(ctx.waterDepthCopy, colorViewPtrs, colorCount))
        ? ctx.waterDepthCopy : ctx.waterDummyDepth;
    id<MTLTexture> wavesTex = (enabled && ctx.waterWavesTex && !water_tex_matches_attachments(ctx.waterWavesTex, colorViewPtrs, colorCount))
        ? ctx.waterWavesTex : ctx.waterDummyHalf;
    id<MTLTexture> pyrTex = (copyValid && ctx.waterPyrTex && !water_tex_matches_attachments(ctx.waterPyrTex, colorViewPtrs, colorCount))
        ? ctx.waterPyrTex : ctx.waterDummyFloat;
    id<MTLTexture> detailTex = (enabled && ctx.waterDetailTex && !water_tex_matches_attachments(ctx.waterDetailTex, colorViewPtrs, colorCount))
        ? ctx.waterDetailTex : wavesTex;

    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
            if (pBuf) [at setAddress:pBuf.gpuAddress + (MTLGPUAddress)pOff atIndex:CM_SHADE_BUF_WATER];
            if (sceneTex) {
                [at setTexture:sceneTex.gpuResourceID atIndex:CM_SHADE_TEX_WATER_SCENE];
                ctx->_boundTextures[CM_SHADE_TEX_WATER_SCENE] = (uintptr_t)(__bridge void *)sceneTex;
            }
            if (depthTex) {
                [at setTexture:depthTex.gpuResourceID atIndex:CM_SHADE_TEX_WATER_DEPTH];
                ctx->_boundTextures[CM_SHADE_TEX_WATER_DEPTH] = (uintptr_t)(__bridge void *)depthTex;
            }
            if (wavesTex) {
                [at setTexture:wavesTex.gpuResourceID atIndex:CM_SHADE_TEX_WATER_WAVES];
                ctx->_boundTextures[CM_SHADE_TEX_WATER_WAVES] = (uintptr_t)(__bridge void *)wavesTex;
            }
            if (pyrTex) {
                [at setTexture:pyrTex.gpuResourceID atIndex:CM_SHADE_TEX_WATER_PYR];
                ctx->_boundTextures[CM_SHADE_TEX_WATER_PYR] = (uintptr_t)(__bridge void *)pyrTex;
            }
            if (detailTex) {
                [at setTexture:detailTex.gpuResourceID atIndex:CM_SHADE_TEX_WATER_DETAIL];
                ctx->_boundTextures[CM_SHADE_TEX_WATER_DETAIL] = (uintptr_t)(__bridge void *)detailTex;
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        if (pBuf) [enc setFragmentBuffer:pBuf offset:(NSUInteger)pOff atIndex:CM_SHADE_BUF_WATER];
        if (sceneTex) {
            [enc setFragmentTexture:sceneTex atIndex:CM_SHADE_TEX_WATER_SCENE];
            ctx->_boundTextures[CM_SHADE_TEX_WATER_SCENE] = (uintptr_t)(__bridge void *)sceneTex;
        }
        if (depthTex) {
            [enc setFragmentTexture:depthTex atIndex:CM_SHADE_TEX_WATER_DEPTH];
            ctx->_boundTextures[CM_SHADE_TEX_WATER_DEPTH] = (uintptr_t)(__bridge void *)depthTex;
        }
        if (wavesTex) {
            [enc setFragmentTexture:wavesTex atIndex:CM_SHADE_TEX_WATER_WAVES];
            ctx->_boundTextures[CM_SHADE_TEX_WATER_WAVES] = (uintptr_t)(__bridge void *)wavesTex;
        }
        if (pyrTex) {
            [enc setFragmentTexture:pyrTex atIndex:CM_SHADE_TEX_WATER_PYR];
            ctx->_boundTextures[CM_SHADE_TEX_WATER_PYR] = (uintptr_t)(__bridge void *)pyrTex;
        }
        if (detailTex) {
            [enc setFragmentTexture:detailTex atIndex:CM_SHADE_TEX_WATER_DETAIL];
            ctx->_boundTextures[CM_SHADE_TEX_WATER_DETAIL] = (uintptr_t)(__bridge void *)detailTex;
        }
    }
}

void cm_water_set_params(int64_t ctxPtr, int64_t paramsBufPtr, int64_t paramsOffset,
                         int64_t wavesTexPtr, int64_t detailTexPtr, int32_t enabled) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ctx.waterParamsBuf = paramsBufPtr ? (__bridge id<MTLBuffer>)(void *)paramsBufPtr : nil;
        ctx.waterParamsOffset = (uint64_t)MAX(0LL, paramsOffset);
        ctx.waterWavesTex = wavesTexPtr ? (__bridge id<MTLTexture>)(void *)wavesTexPtr : nil;
        ctx.waterDetailTex = detailTexPtr ? (__bridge id<MTLTexture>)(void *)detailTexPtr : nil;
        ctx.waterEnabled = (enabled != 0);
        ctx.waterCopyValid = NO;

        if (ctx.activeRenderEnc && ctx.shadeGlobalsEnabled) {
            int64_t colorPtrs[CM_MAX_COLOR_ATTACHMENTS];
            int32_t cc = MAX(0, MIN(ctx.passColorCount, CM_MAX_COLOR_ATTACHMENTS));
            for (int32_t i = 0; i < cc; i++) colorPtrs[i] = (int64_t)ctx->_passColorViews[i];
            cm_water_bind_render_encoder(ctx, colorPtrs, cc);
        }
    }
}

void cm_water_generate_mipmaps(int64_t ctxPtr, int64_t wavesPtr, int64_t detailPtr, int64_t swellPtr) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        const int64_t handles[] = { wavesPtr, detailPtr, swellPtr };
        id<MTLTexture> textures[3];
        NSUInteger count = 0;
        for (NSUInteger i = 0; i < 3; i++) {
            // Each independent chain is generated once, so no intra-encoder barriers are needed.
            id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)handles[i];
            if (tex.mipmapLevelCount <= 1 || (i > 0 && handles[i] == wavesPtr)
                || (i > 1 && handles[i] == detailPtr)) continue;
            textures[count++] = tex;
        }
        if (count == 0) return;
        cm_ensure_cmd_begun(ctx);
        cm_flush_encoders(ctx);
        cm_commit_residency_if_dirty(ctx);

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                if (!ce) return;
                if (ctx.debugLabels) ce.label = @"CelestiaWater.Mipmaps";
                for (NSUInteger i = 0; i < count; i++) [ce generateMipmapsForTexture:textures[i]];
                [ce barrierAfterStages:MTLStageBlit
                     beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
                [ce endEncoding];
            }
        } else {
            id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
            if (!be) return;
            if (ctx.debugLabels) be.label = @"CelestiaWater.Mipmaps";
            for (NSUInteger i = 0; i < count; i++) [be generateMipmapsForTexture:textures[i]];
            [be endEncoding];
        }
        ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
    }
}

void cm_blit_copy_texture_full(int64_t ctxPtr, int64_t srcTexPtr, int64_t dstTexPtr) {
    if (!ctxPtr || !srcTexPtr || !dstTexPtr || srcTexPtr == dstTexPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLTexture> src = (__bridge id<MTLTexture>)(void *)srcTexPtr;
        id<MTLTexture> dst = (__bridge id<MTLTexture>)(void *)dstTexPtr;
        NSUInteger w = MIN(src.width, dst.width);
        NSUInteger h = MIN(src.height, dst.height);
        if (w == 0 || h == 0) return;

        cm_ensure_cmd_begun(ctx);
        cm_flush_encoders(ctx);
        cm_commit_residency_if_dirty(ctx);

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                if (!ce) return;
                if (ctx.debugLabels) ce.label = @"CelestiaShade.CopyFull";
                [ce copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(w, h, 1)
                          toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [ce barrierAfterStages:MTLStageBlit
                     beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
                [ce endEncoding];
            }
        } else {
            id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
            if (!be) return;
            if (ctx.debugLabels) be.label = @"CelestiaShade.CopyFull";
            [be copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(w, h, 1)
                      toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [be endEncoding];
        }
        ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
    }
}

static void encode_pyr_fullscreen_pass(CMContext *ctx, id<MTLRenderPipelineState> pso,
                                       id<MTLTexture> srcTex, id<MTLTexture> dstTex,
                                       NSUInteger vpY, NSUInteger vpW, NSUInteger vpH,
                                       BOOL loadDst, const int32_t *uData, NSUInteger uBytes,
                                       NSString *label) {
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
            rpd.colorAttachments[0].texture = dstTex;
            rpd.colorAttachments[0].loadAction = loadDst ? MTLLoadActionLoad : MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return;
            if (ctx.debugLabels && label) enc.label = label;
            id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
            [at setTexture:srcTex.gpuResourceID atIndex:0];
            MTLGPUAddress addr = cm_m4_push_ring_alloc(ctx, uData, uBytes);
            [at setAddress:addr atIndex:0];
            [enc setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
            [enc setRenderPipelineState:pso];
            [enc setCullMode:MTLCullModeNone];
            [enc setViewport:(MTLViewport){0.0, (double)vpY, (double)vpW, (double)vpH, 0.0, 1.0}];
            [enc setScissorRect:(MTLScissorRect){0, vpY, vpW, vpH}];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            cm_emit_m4_render_producer_barrier(enc);
            [enc endEncoding];
        }
    } else {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = dstTex;
        rpd.colorAttachments[0].loadAction = loadDst ? MTLLoadActionLoad : MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
        if (!enc) return;
        if (ctx.debugLabels && label) enc.label = label;
        [enc setRenderPipelineState:pso];
        [enc setCullMode:MTLCullModeNone];
        [enc setViewport:(MTLViewport){0.0, (double)vpY, (double)vpW, (double)vpH, 0.0, 1.0}];
        [enc setScissorRect:(MTLScissorRect){0, vpY, vpW, vpH}];
        [enc setFragmentTexture:srcTex atIndex:0];
        [enc setFragmentBytes:uData length:uBytes atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }
    ctx->_stats[CM_STAT_DRAWS]++;
    ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
}

int32_t cm_water_capture(int64_t ctxPtr, int64_t pyrPsoPtr, int64_t pyr2PsoPtr) {
    if (!ctxPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (!ctx.activeRenderEnc || ctx.passSoftEnded || ctx.passColorCount < 1 || !ctx->_passColorViews[0] || !ctx.passDepthView) {
            return 0;
        }
        id<MTLTexture> color0 = (__bridge id<MTLTexture>)(void *)ctx->_passColorViews[0];
        id<MTLTexture> depth = (__bridge id<MTLTexture>)(void *)ctx.passDepthView;
        if (!color0 || !depth) return 0;
        if (color0.storageMode == MTLStorageModeMemoryless || depth.storageMode == MTLStorageModeMemoryless ||
            color0.sampleCount != 1 || depth.sampleCount != 1) {
            return 0;
        }

        NSUInteger w = MIN(color0.width, depth.width);
        NSUInteger h = MIN(color0.height, depth.height);
        if (w == 0 || h == 0) return 0;

        // Save current render pass attachments & scissor state before ending the open encoder.
        int32_t savedColorCount = MAX(1, MIN(ctx.passColorCount, CM_MAX_COLOR_ATTACHMENTS));
        int64_t savedColorViews[CM_MAX_COLOR_ATTACHMENTS];
        for (int32_t i = 0; i < savedColorCount; i++) savedColorViews[i] = (int64_t)ctx->_passColorViews[i];
        int64_t savedDepthView = (int64_t)ctx.passDepthView;
        int32_t savedPassW = ctx.currentPassWidth;
        int32_t savedPassH = ctx.currentPassHeight;
        BOOL savedScissorEnabled = ctx.currentScissorEnabled;
        int32_t savedScissorX = ctx.currentScissorX;
        int32_t savedScissorY = ctx.currentScissorY;
        int32_t savedScissorW = ctx.currentScissorW;
        int32_t savedScissorH = ctx.currentScissorH;

        // End active render encoder cleanly (flush prior opaque/sky work to main color+depth).
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
                cm_emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc endEncoding];
        }
        ctx.activeRenderEnc = nil;
        ctx.passSoftEnded = NO;
        ctx.passMergeable = NO;
        cm_reset_pass_cache(ctx);

        ctx.waterSceneCopy = ensure_copy_tex(ctx, ctx.waterSceneCopy, color0.pixelFormat, w, h, @"CelestiaWater.SceneCopy");
        ctx.waterDepthCopy = ensure_copy_tex(ctx, ctx.waterDepthCopy, depth.pixelFormat, w, h, @"CelestiaWater.DepthCopy");
        if (!ctx.waterSceneCopy || !ctx.waterDepthCopy) {
            return 0;
        }

        NSUInteger w8 = (w + 7) / 8, h8 = (h + 7) / 8;
        NSUInteger w16 = (w + 15) / 16, h16 = (h + 15) / 16;
        NSUInteger w128 = (w + 127) / 128, h128 = (h + 127) / 128;

        BOOL buildPyr = (pyrPsoPtr != 0 && pyr2PsoPtr != 0);
        if (buildPyr) {
            ctx.waterPyrTmp8 = ensure_pyr_tex(ctx, ctx.waterPyrTmp8, w8, h8, @"CelestiaWater.Pyr8");
            ctx.waterPyrTmp16 = ensure_pyr_tex(ctx, ctx.waterPyrTmp16, w16, h16, @"CelestiaWater.Pyr16");
            // 16-px blocks at (0, 0), 128-px at (0, h16), dilated 8-px blocks at (0, h16 + h128) (water.metal shadeSsrhRange8)
            ctx.waterPyrTex = ensure_pyr_tex(ctx, ctx.waterPyrTex, MAX(w16, w8), h16 + h128 + h8, @"CelestiaWater.DepthPyramid");
            if (!ctx.waterPyrTmp8 || !ctx.waterPyrTmp16 || !ctx.waterPyrTex) buildPyr = NO;
        }
        cm_commit_residency_if_dirty(ctx);

        // Step 1: Blit opaque color0 & depth into private ShaderRead copies.
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                if (ce) {
                    if (ctx.debugLabels) ce.label = @"CelestiaWater.CopySceneDepth";
                    [ce copyFromTexture:color0 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(w, h, 1)
                              toTexture:ctx.waterSceneCopy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [ce copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(w, h, 1)
                              toTexture:ctx.waterDepthCopy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [ce barrierAfterStages:MTLStageBlit
                         beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                         visibilityOptions:MTL4VisibilityOptionDevice];
                    [ce endEncoding];
                }
            }
        } else {
            id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
            if (be) {
                if (ctx.debugLabels) be.label = @"CelestiaWater.CopySceneDepth";
                [be copyFromTexture:color0 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(w, h, 1)
                          toTexture:ctx.waterSceneCopy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [be copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(w, h, 1)
                          toTexture:ctx.waterDepthCopy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [be endEncoding];
            }
        }
        ctx->_stats[CM_STAT_BLIT_ENCODERS]++;

        // Step 2: 3-pass RG16Float depth pyramid (8px -> 16px -> copy to (0,0) + 128px at (0,h16)).
        if (buildPyr) {
            CMPipelineBox *pyrBox = (__bridge CMPipelineBox *)(void *)pyrPsoPtr;
            CMPipelineBox *pyr2Box = (__bridge CMPipelineBox *)(void *)pyr2PsoPtr;

            int32_t u0[8] = { 8, 0, 0, 0, (int32_t)w, (int32_t)h, 0, 0 };
            encode_pyr_fullscreen_pass(ctx, pyrBox.state, ctx.waterDepthCopy, ctx.waterPyrTmp8,
                                       0, w8, h8, NO, u0, sizeof(u0), @"CelestiaWater.Pyr8");

            int32_t u1[8] = { 2, 0, 0, 1, (int32_t)w8, (int32_t)h8, 0, 0 };
            encode_pyr_fullscreen_pass(ctx, pyr2Box.state, ctx.waterPyrTmp8, ctx.waterPyrTmp16,
                                       0, w16, h16, NO, u1, sizeof(u1), @"CelestiaWater.Pyr16");

            // Copy 16-px blocks to top rows [0..h16) of waterPyrTex
            if (ctx.metal4Active) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                    if (ce) {
                        if (ctx.debugLabels) ce.label = @"CelestiaWater.PyrCopy16";
                        [ce copyFromTexture:ctx.waterPyrTmp16 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                                 sourceSize:MTLSizeMake(w16, h16, 1)
                                  toTexture:ctx.waterPyrTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                        [ce barrierAfterStages:MTLStageBlit
                             beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                             visibilityOptions:MTL4VisibilityOptionDevice];
                        [ce endEncoding];
                    }
                }
            } else {
                id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
                if (be) {
                    if (ctx.debugLabels) be.label = @"CelestiaWater.PyrCopy16";
                    [be copyFromTexture:ctx.waterPyrTmp16 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(w16, h16, 1)
                              toTexture:ctx.waterPyrTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [be endEncoding];
                }
            }
            ctx->_stats[CM_STAT_BLIT_ENCODERS]++;

            int32_t u2[8] = { 8, 0, (int32_t)h16, 4, (int32_t)w16, (int32_t)h16, 0, 0 };
            encode_pyr_fullscreen_pass(ctx, pyr2Box.state, ctx.waterPyrTmp16, ctx.waterPyrTex,
                                       h16, w128, h128, YES, u2, sizeof(u2), @"CelestiaWater.Pyr128");

            // The 8-px blocks with their 8 neighbours (a texel bounds everything within 8 px of any point in its block): lets the
            // fine march skip the 4 depth reads of a half 16-px interval its ray is in front of (water.metal, SHADE_SSRH_L2)
            int32_t u3[8] = { 1, 0, (int32_t)(h16 + h128), 1, (int32_t)w8, (int32_t)h8, 0, 0 };
            encode_pyr_fullscreen_pass(ctx, pyr2Box.state, ctx.waterPyrTmp8, ctx.waterPyrTex,
                                       h16 + h128, w8, h8, YES, u3, sizeof(u3), @"CelestiaWater.Pyr8Ring");
        }

        // Step 3: Reopen original render pass with MTLLoadActionLoad to preserve opaque world + sky.
        cm_reset_pass_cache(ctx);
        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
        ctx.currentColorCount = savedColorCount;
        ctx.currentHasDepth = YES;
        ctx.currentDepthFormat = depth.pixelFormat;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                for (int32_t i = 0; i < savedColorCount; i++) {
                    id<MTLTexture> ctex = (__bridge id<MTLTexture>)(void *)savedColorViews[i];
                    ctx->_currentColorFormats[i] = ctex.pixelFormat;
                    rpd.colorAttachments[(NSUInteger)i].texture = ctex;
                    rpd.colorAttachments[(NSUInteger)i].loadAction = MTLLoadActionLoad;
                    rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
                }
                rpd.depthAttachment.texture = depth;
                rpd.depthAttachment.loadAction = MTLLoadActionLoad;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
                if (depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                    rpd.stencilAttachment.texture = depth;
                    rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
                    rpd.stencilAttachment.storeAction = MTLStoreActionStore;
                }
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return 0;
                if (ctx.debugLabels) enc.label = @"CelestiaWater.ReopenedWorld";
                [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4VertexArgTable
                             atStages:MTLRenderStageVertex | MTLRenderStageFragment];
                [enc setFrontFacingWinding:MTLWindingClockwise];
                ctx.activeRenderEnc = enc;
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            for (int32_t i = 0; i < savedColorCount; i++) {
                id<MTLTexture> ctex = (__bridge id<MTLTexture>)(void *)savedColorViews[i];
                ctx->_currentColorFormats[i] = ctex.pixelFormat;
                rpd.colorAttachments[(NSUInteger)i].texture = ctex;
                rpd.colorAttachments[(NSUInteger)i].loadAction = MTLLoadActionLoad;
                rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
            }
            rpd.depthAttachment.texture = depth;
            rpd.depthAttachment.loadAction = MTLLoadActionLoad;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            if (depth.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                rpd.stencilAttachment.texture = depth;
                rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
                rpd.stencilAttachment.storeAction = MTLStoreActionStore;
            }
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return 0;
            if (ctx.debugLabels) enc.label = @"CelestiaWater.ReopenedWorld";
            [enc setFrontFacingWinding:MTLWindingClockwise];
            ctx.activeRenderEnc = enc;
        }

        ctx.passSoftEnded = NO;
        ctx.passMergeable = YES;
        ctx.passColorCount = savedColorCount;
        ctx.passDepthView = (uintptr_t)savedDepthView;
        for (int32_t i = 0; i < savedColorCount; i++) ctx->_passColorViews[i] = (uintptr_t)savedColorViews[i];
        ctx.currentPassWidth = MAX(1, savedPassW);
        ctx.currentPassHeight = MAX(1, savedPassH);

        ctx.waterCopyValid = YES;
        if (ctx.shadeGlobalsEnabled) {
            cm_shade_bind_render_encoder(ctx, savedColorViews, savedColorCount);
        } else {
            cm_water_bind_render_encoder(ctx, savedColorViews, savedColorCount);
        }

        MTLViewport vp = { 0.0, 0.0, (double)ctx.currentPassWidth, (double)ctx.currentPassHeight, 0.0, 1.0 };
        if (ctx.metal4Active) {
            [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
        } else {
            [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
        }
        if (savedScissorEnabled && savedScissorW > 0 && savedScissorH > 0) {
            cm_pass_set_scissor(ctxPtr, 1, savedScissorX, savedScissorY, savedScissorW, savedScissorH);
        } else {
            cm_pass_set_scissor(ctxPtr, 0, 0, 0, 0, 0);
        }
        return 1;
    }
}
