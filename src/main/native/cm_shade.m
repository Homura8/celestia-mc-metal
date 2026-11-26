#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

// Keep in sync with cm_resources.m CMPipelineBox
@interface CMPipelineBox : NSObject
@property (nonatomic, strong) id<MTLRenderPipelineState> state;
@property (nonatomic, strong) id<MTLDepthStencilState> depthState;
@property (nonatomic) MTLCullMode cullMode;
@property (nonatomic) MTLTriangleFillMode fillMode;
@property (nonatomic) float depthBiasSlope;
@property (nonatomic) float depthBiasConst;
@property (nonatomic) uint32_t depthKey;
@end

static id<MTLTexture> ensure_dummy_tex(CMContext *ctx) {
    if (ctx.shadeDummyTex) return (id<MTLTexture>)ctx.shadeDummyTex;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:1
                                                                                 height:1
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [ctx.device newTextureWithDescriptor:td];
    if (tex) {
        if (ctx.debugLabels) tex.label = @"CelestiaShade.DummyTex";
        cm_track_allocation(ctx, tex);
        ctx.shadeDummyTex = tex;
    }
    return tex;
}

static BOOL tex_matches_attachments(id<MTLTexture> tex, const int64_t *colorViewPtrs, int32_t colorCount) {
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

void cm_shade_set_enabled(int64_t ctxPtr, int32_t enabled) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    ctx.shadeGlobalsEnabled = (enabled != 0);
}

void cm_shade_set_globals(int64_t ctxPtr,
                          int64_t frameBufPtr, int64_t frameOffset,
                          int64_t lookBufPtr, int64_t lookOffset,
                          int64_t gpuBufPtr, int64_t gpuOffset,
                          int64_t resBufPtr, int64_t resOffset,
                          int64_t shadowTexPtr, int64_t skyLutTexPtr,
                          int64_t shadowSampPtr, int64_t linearSampPtr) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ctx.shadeFrameBuf = frameBufPtr ? (__bridge id<MTLBuffer>)(void *)frameBufPtr : nil;
        ctx.shadeFrameOffset = (uint64_t)MAX(0LL, frameOffset);
        ctx.shadeLookBuf = lookBufPtr ? (__bridge id<MTLBuffer>)(void *)lookBufPtr : nil;
        ctx.shadeLookOffset = (uint64_t)MAX(0LL, lookOffset);
        ctx.shadeGpuBuf = gpuBufPtr ? (__bridge id<MTLBuffer>)(void *)gpuBufPtr : nil;
        ctx.shadeGpuOffset = (uint64_t)MAX(0LL, gpuOffset);
        ctx.shadeResBuf = resBufPtr ? (__bridge id<MTLBuffer>)(void *)resBufPtr : nil;
        ctx.shadeResOffset = (uint64_t)MAX(0LL, resOffset);
        ctx.shadeShadowTex = shadowTexPtr ? (__bridge id<MTLTexture>)(void *)shadowTexPtr : nil;
        ctx.shadeSkyLutTex = skyLutTexPtr ? (__bridge id<MTLTexture>)(void *)skyLutTexPtr : nil;
        ctx.shadeShadowSampler = shadowSampPtr ? (__bridge id<MTLSamplerState>)(void *)shadowSampPtr : nil;
        ctx.shadeLinearSampler = linearSampPtr ? (__bridge id<MTLSamplerState>)(void *)linearSampPtr : nil;

        id<MTLBuffer> rBuf = (id<MTLBuffer>)ctx.shadeResBuf;
        if (rBuf && rBuf.contents) {
            id<MTLTexture> dummy = ensure_dummy_tex(ctx);
            if (dummy) {
                uint64_t dummyId = dummy.gpuResourceID._impl;
                uint64_t *ids = (uint64_t *)((uint8_t *)rBuf.contents + ctx.shadeResOffset);
                for (int32_t i = 0; i < CM_SHADE_MAX_RES_TEX; i++) {
                    id<MTLTexture> rt = (id<MTLTexture>)ctx->_shadeResTextures[i];
                    ids[i] = rt ? rt.gpuResourceID._impl : dummyId;
                }
            }
        }
    }
}

void cm_shade_set_resource(int64_t ctxPtr, int32_t slot, int64_t texPtr) {
    if (!ctxPtr || slot < 0 || slot >= CM_SHADE_MAX_RES_TEX) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLTexture> tex = texPtr ? (__bridge id<MTLTexture>)(void *)texPtr : nil;
        ctx->_shadeResTextures[slot] = tex;
        id<MTLBuffer> rBuf = (id<MTLBuffer>)ctx.shadeResBuf;
        if (rBuf && rBuf.contents) {
            id<MTLTexture> use = tex ? tex : ensure_dummy_tex(ctx);
            if (use) {
                uint64_t *ids = (uint64_t *)((uint8_t *)rBuf.contents + ctx.shadeResOffset);
                ids[slot] = use.gpuResourceID._impl;
            }
        }
    }
}

void cm_shade_bind_render_encoder(CMContext *ctx, const int64_t *colorViewPtrs, int32_t colorCount) {
    if (!ctx || !ctx.activeRenderEnc) return;
    id<MTLBuffer> fBuf = (id<MTLBuffer>)ctx.shadeFrameBuf;
    id<MTLBuffer> lBuf = (id<MTLBuffer>)ctx.shadeLookBuf;
    id<MTLBuffer> gBuf = (id<MTLBuffer>)ctx.shadeGpuBuf;
    id<MTLBuffer> rBuf = (id<MTLBuffer>)ctx.shadeResBuf;
    id<MTLTexture> shadowTex = (id<MTLTexture>)ctx.shadeShadowTex;
    id<MTLTexture> skyTex = (id<MTLTexture>)ctx.shadeSkyLutTex;
    id<MTLSamplerState> shadowSamp = (id<MTLSamplerState>)ctx.shadeShadowSampler;
    id<MTLSamplerState> linSamp = (id<MTLSamplerState>)ctx.shadeLinearSampler;

    BOOL bindShadow = shadowTex && !tex_matches_attachments(shadowTex, colorViewPtrs, colorCount);
    BOOL bindSky = skyTex && !tex_matches_attachments(skyTex, colorViewPtrs, colorCount);

    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
            if (fBuf) [at setAddress:fBuf.gpuAddress + (MTLGPUAddress)ctx.shadeFrameOffset atIndex:CM_SHADE_BUF_FRAME];
            if (lBuf) [at setAddress:lBuf.gpuAddress + (MTLGPUAddress)ctx.shadeLookOffset atIndex:CM_SHADE_BUF_LOOK];
            if (gBuf) [at setAddress:gBuf.gpuAddress + (MTLGPUAddress)ctx.shadeGpuOffset atIndex:CM_SHADE_BUF_GPU];
            if (rBuf) [at setAddress:rBuf.gpuAddress + (MTLGPUAddress)ctx.shadeResOffset atIndex:CM_SHADE_BUF_RESOURCES];
            if (bindShadow) {
                [at setTexture:shadowTex.gpuResourceID atIndex:CM_SHADE_TEX_SHADOW];
                ctx->_boundTextures[CM_SHADE_TEX_SHADOW] = (uintptr_t)(__bridge void *)shadowTex;
            }
            if (bindSky) {
                [at setTexture:skyTex.gpuResourceID atIndex:CM_SHADE_TEX_SKY_LUT];
                ctx->_boundTextures[CM_SHADE_TEX_SKY_LUT] = (uintptr_t)(__bridge void *)skyTex;
            }
            if (shadowSamp) {
                [at setSamplerState:shadowSamp.gpuResourceID atIndex:CM_SHADE_SAMP_SHADOW];
                ctx->_boundSamplers[CM_SHADE_SAMP_SHADOW] = (uintptr_t)(__bridge void *)shadowSamp;
            }
            if (linSamp) {
                [at setSamplerState:linSamp.gpuResourceID atIndex:CM_SHADE_SAMP_LINEAR];
                ctx->_boundSamplers[CM_SHADE_SAMP_LINEAR] = (uintptr_t)(__bridge void *)linSamp;
            }
        }
        cm_water_bind_render_encoder(ctx, colorViewPtrs, colorCount);
        cm_dynlight_bind_render_encoder(ctx);
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        if (fBuf) {
            [enc setVertexBuffer:fBuf offset:(NSUInteger)ctx.shadeFrameOffset atIndex:CM_SHADE_BUF_FRAME];
            [enc setFragmentBuffer:fBuf offset:(NSUInteger)ctx.shadeFrameOffset atIndex:CM_SHADE_BUF_FRAME];
        }
        if (lBuf) {
            [enc setVertexBuffer:lBuf offset:(NSUInteger)ctx.shadeLookOffset atIndex:CM_SHADE_BUF_LOOK];
            [enc setFragmentBuffer:lBuf offset:(NSUInteger)ctx.shadeLookOffset atIndex:CM_SHADE_BUF_LOOK];
        }
        if (gBuf) {
            [enc setVertexBuffer:gBuf offset:(NSUInteger)ctx.shadeGpuOffset atIndex:CM_SHADE_BUF_GPU];
            [enc setFragmentBuffer:gBuf offset:(NSUInteger)ctx.shadeGpuOffset atIndex:CM_SHADE_BUF_GPU];
        }
        if (rBuf) {
            [enc setVertexBuffer:rBuf offset:(NSUInteger)ctx.shadeResOffset atIndex:CM_SHADE_BUF_RESOURCES];
            [enc setFragmentBuffer:rBuf offset:(NSUInteger)ctx.shadeResOffset atIndex:CM_SHADE_BUF_RESOURCES];
            id<MTLResource> resList[CM_SHADE_MAX_RES_TEX];
            NSUInteger resCount = 0;
            BOOL dummyAdded = NO;
            id<MTLTexture> dummy = (id<MTLTexture>)ctx.shadeDummyTex;
            for (int32_t i = 0; i < CM_SHADE_MAX_RES_TEX; i++) {
                id<MTLTexture> t = (id<MTLTexture>)ctx->_shadeResTextures[i];
                if (!t) {
                    if (dummyAdded || !dummy) continue;
                    t = dummy;
                    dummyAdded = YES;
                }
                if (!tex_matches_attachments(t, colorViewPtrs, colorCount)) {
                    resList[resCount++] = t;
                }
            }
            if (resCount > 0) {
                [enc useResources:resList count:resCount usage:MTLResourceUsageRead
                           stages:MTLRenderStageVertex | MTLRenderStageFragment];
            }
        }
        if (bindShadow) {
            [enc setVertexTexture:shadowTex atIndex:CM_SHADE_TEX_SHADOW];
            [enc setFragmentTexture:shadowTex atIndex:CM_SHADE_TEX_SHADOW];
            ctx->_boundTextures[CM_SHADE_TEX_SHADOW] = (uintptr_t)(__bridge void *)shadowTex;
        }
        if (bindSky) {
            [enc setVertexTexture:skyTex atIndex:CM_SHADE_TEX_SKY_LUT];
            [enc setFragmentTexture:skyTex atIndex:CM_SHADE_TEX_SKY_LUT];
            ctx->_boundTextures[CM_SHADE_TEX_SKY_LUT] = (uintptr_t)(__bridge void *)skyTex;
        }
        if (shadowSamp) {
            [enc setVertexSamplerState:shadowSamp atIndex:CM_SHADE_SAMP_SHADOW];
            [enc setFragmentSamplerState:shadowSamp atIndex:CM_SHADE_SAMP_SHADOW];
            ctx->_boundSamplers[CM_SHADE_SAMP_SHADOW] = (uintptr_t)(__bridge void *)shadowSamp;
        }
        if (linSamp) {
            [enc setVertexSamplerState:linSamp atIndex:CM_SHADE_SAMP_LINEAR];
            [enc setFragmentSamplerState:linSamp atIndex:CM_SHADE_SAMP_LINEAR];
            ctx->_boundSamplers[CM_SHADE_SAMP_LINEAR] = (uintptr_t)(__bridge void *)linSamp;
        }
        cm_water_bind_render_encoder(ctx, colorViewPtrs, colorCount);
        cm_dynlight_bind_render_encoder(ctx);
    }
}

void cm_shade_fullscreen_pass(int64_t ctxPtr, int64_t psoPtr, int64_t colorTexPtr,
                              const int64_t *texPtrs, int32_t texCount,
                              const int64_t *sampPtrs, int32_t sampCount,
                              const void *pushData, int32_t pushBytes) {
    if (!ctxPtr || !psoPtr || !colorTexPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_ensure_cmd_begun(ctx);
        cm_flush_encoders(ctx);
        cm_reset_pass_cache(ctx);

        CMPipelineBox *box = (__bridge CMPipelineBox *)(void *)psoPtr;
        id<MTLTexture> dstTex = (__bridge id<MTLTexture>)(void *)colorTexPtr;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.colorAttachments[0].texture = dstTex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return;
                if (ctx.debugLabels) enc.label = @"CelestiaShade.Fullscreen";
                id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
                [enc setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
                [enc setRenderPipelineState:box.state];
                [enc setCullMode:MTLCullModeNone];
                [enc setViewport:(MTLViewport){0.0, 0.0, (double)dstTex.width, (double)dstTex.height, 0.0, 1.0}];
                [enc setScissorRect:(MTLScissorRect){0, 0, dstTex.width, dstTex.height}];

                ctx.activeRenderEnc = enc;
                cm_shade_bind_render_encoder(ctx, &colorTexPtr, 1);

                for (int32_t i = 0; i < texCount && i < CM_MAX_TEXTURES; i++) {
                    if (texPtrs && texPtrs[i]) {
                        id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)texPtrs[i];
                        [at setTexture:t.gpuResourceID atIndex:(NSUInteger)i];
                    }
                }
                for (int32_t i = 0; i < sampCount && i < CM_MAX_SAMPLERS; i++) {
                    if (sampPtrs && sampPtrs[i]) {
                        id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)(void *)sampPtrs[i];
                        [at setSamplerState:s.gpuResourceID atIndex:(NSUInteger)i];
                    }
                }
                if (pushData && pushBytes > 0) {
                    MTLGPUAddress addr = cm_m4_push_ring_alloc(ctx, pushData, (NSUInteger)pushBytes);
                    [at setAddress:addr atIndex:0];
                }

                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                cm_emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
                ctx.activeRenderEnc = nil;
                cm_reset_pass_cache(ctx);
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = dstTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return;
            if (ctx.debugLabels) enc.label = @"CelestiaShade.Fullscreen";
            [enc setRenderPipelineState:box.state];
            [enc setCullMode:MTLCullModeNone];
            [enc setViewport:(MTLViewport){0.0, 0.0, (double)dstTex.width, (double)dstTex.height, 0.0, 1.0}];
            [enc setScissorRect:(MTLScissorRect){0, 0, dstTex.width, dstTex.height}];

            ctx.activeRenderEnc = enc;
            cm_shade_bind_render_encoder(ctx, &colorTexPtr, 1);

            for (int32_t i = 0; i < texCount && i < CM_MAX_TEXTURES; i++) {
                if (texPtrs && texPtrs[i]) {
                    id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)texPtrs[i];
                    [enc setVertexTexture:t atIndex:(NSUInteger)i];
                    [enc setFragmentTexture:t atIndex:(NSUInteger)i];
                }
            }
            for (int32_t i = 0; i < sampCount && i < CM_MAX_SAMPLERS; i++) {
                if (sampPtrs && sampPtrs[i]) {
                    id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)(void *)sampPtrs[i];
                    [enc setVertexSamplerState:s atIndex:(NSUInteger)i];
                    [enc setFragmentSamplerState:s atIndex:(NSUInteger)i];
                }
            }
            if (pushData && pushBytes > 0) {
                [enc setVertexBytes:pushData length:(NSUInteger)pushBytes atIndex:0];
                [enc setFragmentBytes:pushData length:(NSUInteger)pushBytes atIndex:0];
            }

            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            ctx.activeRenderEnc = nil;
            cm_reset_pass_cache(ctx);
        }
        ctx->_stats[CM_STAT_DRAWS]++;
        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
    }
}

void cm_shade_exposure_run(int64_t ctxPtr,
                           int64_t histComputePsoPtr, int64_t expComputePsoPtr,
                           int64_t srcTexPtr, int64_t gpuBufPtr, int64_t gpuOffset,
                           int64_t lookBufPtr, int64_t lookOffset,
                           int32_t gx, int32_t gy) {
    if (!ctxPtr || !histComputePsoPtr || !expComputePsoPtr || !srcTexPtr || gx <= 0 || gy <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_ensure_cmd_begun(ctx);
        cm_flush_encoders(ctx);
        cm_reset_pass_cache(ctx);

        id<MTLComputePipelineState> histCps = (__bridge id<MTLComputePipelineState>)(void *)histComputePsoPtr;
        id<MTLComputePipelineState> expCps = (__bridge id<MTLComputePipelineState>)(void *)expComputePsoPtr;
        id<MTLTexture> srcTex = (__bridge id<MTLTexture>)(void *)srcTexPtr;
        id<MTLBuffer> gBuf = gpuBufPtr ? (__bridge id<MTLBuffer>)(void *)gpuBufPtr : (id<MTLBuffer>)ctx.shadeGpuBuf;
        uint64_t gOff = gpuBufPtr ? (uint64_t)MAX(0LL, gpuOffset) : ctx.shadeGpuOffset;
        id<MTLBuffer> lBuf = lookBufPtr ? (__bridge id<MTLBuffer>)(void *)lookBufPtr : (id<MTLBuffer>)ctx.shadeLookBuf;
        uint64_t lOff = lookBufPtr ? (uint64_t)MAX(0LL, lookOffset) : ctx.shadeLookOffset;
        if (!gBuf || !lBuf) return;

        MTLSize histGroups = MTLSizeMake((NSUInteger)gx, (NSUInteger)gy, 1);
        MTLSize histThreads = MTLSizeMake(8, 8, 1);
        MTLSize one = MTLSizeMake(1, 1, 1);

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4ComputeCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                if (!enc) return;
                id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4FragmentArgTable;
                [at setTexture:srcTex.gpuResourceID atIndex:0];
                [at setAddress:gBuf.gpuAddress + (MTLGPUAddress)gOff atIndex:CM_SHADE_BUF_GPU];
                [at setAddress:lBuf.gpuAddress + (MTLGPUAddress)lOff atIndex:CM_SHADE_BUF_LOOK];
                [enc setArgumentTable:at];
                [enc setComputePipelineState:histCps];
                [enc dispatchThreadgroups:histGroups threadsPerThreadgroup:histThreads];
                [enc barrierAfterEncoderStages:MTLStageDispatch
                               beforeEncoderStages:MTLStageDispatch
                                 visibilityOptions:MTL4VisibilityOptionDevice];
                [enc setComputePipelineState:expCps];
                [enc dispatchThreadgroups:one threadsPerThreadgroup:one];
                [enc barrierAfterStages:MTLStageDispatch
                      beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                      visibilityOptions:MTL4VisibilityOptionDevice];
                [enc endEncoding];
            }
        } else {
            id<MTLComputeCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf computeCommandEncoder];
            if (!enc) return;
            [enc setComputePipelineState:histCps];
            [enc setTexture:srcTex atIndex:0];
            [enc setBuffer:gBuf offset:(NSUInteger)gOff atIndex:CM_SHADE_BUF_GPU];
            [enc dispatchThreadgroups:histGroups threadsPerThreadgroup:histThreads];
            [enc setComputePipelineState:expCps];
            [enc setBuffer:gBuf offset:(NSUInteger)gOff atIndex:CM_SHADE_BUF_GPU];
            [enc setBuffer:lBuf offset:(NSUInteger)lOff atIndex:CM_SHADE_BUF_LOOK];
            [enc dispatchThreadgroups:one threadsPerThreadgroup:one];
            [enc endEncoding];
        }
    }
}
