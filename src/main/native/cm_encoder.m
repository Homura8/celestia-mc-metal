#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

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

static void ensure_cmd_begun(CMContext *ctx) {
    if (ctx.metal4Active) {
        if (ctx.activeM4CmdBuf) return;
        if (@available(macOS 26.0, *)) {
            uint64_t next = atomic_load(&ctx->_nextSubmitSerial) + 1;
            if (next > CM_INFLIGHT_SLOTS) {
                cm_wait_submit((int64_t)(__bridge void *)ctx, next - CM_INFLIGHT_SLOTS, 5000000000ULL);
            }
            NSUInteger idx = (NSUInteger)(next % CM_INFLIGHT_SLOTS);
            id<MTL4CommandAllocator> alloc = ctx.m4Allocators[idx];
            [alloc reset];
            id<MTL4CommandBuffer> cb = [ctx.device newCommandBuffer];
            [cb beginCommandBufferWithAllocator:alloc];
            if (ctx.residencySet) {
                [cb useResidencySet:(id<MTLResidencySet>)ctx.residencySet];
            }
            ctx.activeM4AllocatorIdx = idx;
            ctx.activeM4CmdBuf = cb;
            ctx.pushRingOffset = (idx * (ctx.pushRingSize / CM_INFLIGHT_SLOTS));
        }
    } else {
        if (ctx.activeM3CmdBuf) return;
        id<MTLCommandBuffer> cb = [ctx.m3Queue commandBufferWithUnretainedReferences];
        ctx.activeM3CmdBuf = cb;
        ctx.pushRingOffset = 0;
    }
}

void cm_end_blit_if_active(CMContext *ctx) {
    if (!ctx || !ctx.activeBlitEnc) return;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4ComputeCommandEncoder> ce = (id<MTL4ComputeCommandEncoder>)ctx.activeBlitEnc;
            [ce barrierAfterStages:MTLStageBlit | MTLStageDispatch
                 beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
            [ce endEncoding];
        }
    } else {
        [(id<MTLBlitCommandEncoder>)ctx.activeBlitEnc endEncoding];
    }
    ctx.activeBlitEnc = nil;
    ctx.blitHasOps = NO;
}

static void emit_m4_blit_intra_barrier_if_needed(CMContext *ctx, id enc) {
    if (ctx.metal4Active && ctx.blitHasOps) {
        if (@available(macOS 26.0, *)) {
            [(id<MTL4ComputeCommandEncoder>)enc barrierAfterEncoderStages:MTLStageBlit
                                                      beforeEncoderStages:MTLStageBlit
                                                        visibilityOptions:MTL4VisibilityOptionDevice];
        }
    }
}

static id ensure_blit_encoder(CMContext *ctx) {
    ensure_cmd_begun(ctx);
    if (ctx.activeRenderEnc) {
        cm_pass_end((int64_t)(__bridge void *)ctx);
    }
    if (!ctx.activeBlitEnc) {
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                ctx.activeBlitEnc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
            }
        } else {
            ctx.activeBlitEnc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
        }
        ctx.blitHasOps = NO;
    }
    return ctx.activeBlitEnc;
}

static void emit_m4_render_producer_barrier(id<MTL4RenderCommandEncoder> enc) {
    if (@available(macOS 26.0, *)) {
        [enc barrierAfterStages:MTLStageVertex | MTLStageFragment
              beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
              visibilityOptions:MTL4VisibilityOptionDevice];
    }
}

void cm_cmd_begin(int64_t ctxPtr) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ensure_cmd_begun(ctx);
    }
}

int32_t cm_cmd_has_active(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return (ctx.activeM4CmdBuf != nil || ctx.activeM3CmdBuf != nil) ? 1 : 0;
}

uint64_t cm_cmd_submit(int64_t ctxPtr, int32_t maxInFlight) {
    if (!ctxPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        if (!ctx.activeM4CmdBuf && !ctx.activeM3CmdBuf) {
            cm_drain_retired(ctx);
            return atomic_load(&ctx->_completedSubmitSerial);
        }

        cm_commit_residency_if_dirty(ctx);

        uint64_t serial = atomic_fetch_add(&ctx->_nextSubmitSerial, 1) + 1;
        int32_t cap = maxInFlight > 0 ? MIN(maxInFlight, CM_INFLIGHT_SLOTS) : 2;
        if (serial > (uint64_t)cap) {
            cm_wait_submit(ctxPtr, serial - (uint64_t)cap, 5000000000ULL);
        }

        if (ctx.metal4Active && ctx.activeM4CmdBuf) {
            if (@available(macOS 26.0, *)) {
                id<MTL4CommandBuffer> cb = (id<MTL4CommandBuffer>)ctx.activeM4CmdBuf;
                ctx.activeM4CmdBuf = nil;
                [cb endCommandBuffer];

                id<MTL4CommandQueue> q = (id<MTL4CommandQueue>)ctx.m4Queue;
                MTL4CommitOptions *opts = [MTL4CommitOptions new];
                CMContext *weakCtx = ctx;
                [opts addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
                    if (feedback.error) {
                        cm_record_error(weakCtx, feedback.error.localizedDescription);
                    }
                    double dt = feedback.GPUEndTime - feedback.GPUStartTime;
                    if (dt > 0.0) {
                        atomic_store(&weakCtx->_lastGpuFrameNs, (uint64_t)(dt * 1e9));
                    }
                }];
                [q commit:&cb count:1 options:opts];
                [q signalEvent:ctx.submitEvent value:serial];
            }
        } else if (ctx.activeM3CmdBuf) {
            id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)ctx.activeM3CmdBuf;
            ctx.activeM3CmdBuf = nil;
            CMContext *weakCtx = ctx;
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                if (done.error) {
                    cm_record_error(weakCtx, done.error.localizedDescription);
                }
                double dt = done.GPUEndTime - done.GPUStartTime;
                if (dt > 0.0) {
                    atomic_store(&weakCtx->_lastGpuFrameNs, (uint64_t)(dt * 1e9));
                }
                uint64_t prev = atomic_load(&weakCtx->_completedSubmitSerial);
                while (prev < serial && !atomic_compare_exchange_weak(&weakCtx->_completedSubmitSerial, &prev, serial)) {}
            }];
            [cb encodeSignalEvent:ctx.submitEvent value:serial];
            [cb commit];
        }

        // Synchronize completedSubmitSerial from sharedEvent
        uint64_t signaled = ctx.submitEvent.signaledValue;
        uint64_t cur = atomic_load(&ctx->_completedSubmitSerial);
        while (cur < signaled && !atomic_compare_exchange_weak(&ctx->_completedSubmitSerial, &cur, signaled)) {}
        cm_drain_retired(ctx);
        return serial;
    }
}

int32_t cm_wait_submit(int64_t ctxPtr, uint64_t serial, uint64_t timeoutNs) {
    if (!ctxPtr || serial == 0) return 1;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (ctx.submitEvent.signaledValue >= serial) {
        uint64_t cur = atomic_load(&ctx->_completedSubmitSerial);
        while (cur < serial && !atomic_compare_exchange_weak(&ctx->_completedSubmitSerial, &cur, serial)) {}
        cm_drain_retired(ctx);
        return 1;
    }
    uint64_t ms = timeoutNs / 1000000ULL;
    if (ms == 0 && timeoutNs > 0) ms = 1;
    BOOL ok = [ctx.submitEvent waitUntilSignaledValue:serial timeoutMS:ms];
    if (ok) {
        uint64_t cur = atomic_load(&ctx->_completedSubmitSerial);
        while (cur < serial && !atomic_compare_exchange_weak(&ctx->_completedSubmitSerial, &cur, serial)) {}
        cm_drain_retired(ctx);
    }
    return ok ? 1 : 0;
}

// ---- Blit operations ----

void cm_blit_clear_color(int64_t ctxPtr, int64_t texPtr, float r, float g, float b, float a) {
    if (!ctxPtr || !texPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ensure_cmd_begun(ctx);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)texPtr;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.colorAttachments[0].texture = tex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = tex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc endEncoding];
        }
    }
}

static void configure_depth_stencil_attachments(MTLRenderPassDepthAttachmentDescriptor *depthAtt,
                                                MTLRenderPassStencilAttachmentDescriptor *stencilAtt,
                                                id<MTLTexture> dtex, BOOL hasClear, double clearDepth) {
    depthAtt.texture = dtex;
    depthAtt.loadAction = hasClear ? MTLLoadActionClear : MTLLoadActionLoad;
    depthAtt.storeAction = MTLStoreActionStore;
    if (hasClear) depthAtt.clearDepth = clearDepth;
    if (dtex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
        stencilAtt.texture = dtex;
        stencilAtt.loadAction = hasClear ? MTLLoadActionClear : MTLLoadActionLoad;
        stencilAtt.storeAction = MTLStoreActionStore;
        if (hasClear) stencilAtt.clearStencil = 0;
    }
}

void cm_blit_clear_depth(int64_t ctxPtr, int64_t texPtr, double depth) {
    if (!ctxPtr || !texPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ensure_cmd_begun(ctx);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)texPtr;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, tex, YES, depth);
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, tex, YES, depth);
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc endEncoding];
        }
    }
}

void cm_blit_clear_color_depth(int64_t ctxPtr, int64_t colorTexPtr, float r, float g, float b, float a,
                               int64_t depthTexPtr, double depth) {
    if (!ctxPtr || !colorTexPtr || !depthTexPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ensure_cmd_begun(ctx);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        id<MTLTexture> ctex = (__bridge id<MTLTexture>)(void *)colorTexPtr;
        id<MTLTexture> dtex = (__bridge id<MTLTexture>)(void *)depthTexPtr;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.colorAttachments[0].texture = ctex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
                configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, dtex, YES, depth);
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = ctex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
            configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, dtex, YES, depth);
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            [enc endEncoding];
        }
    }
}

void cm_blit_copy_buffer(int64_t ctxPtr, int64_t srcBuf, int64_t srcOff, int64_t dstBuf, int64_t dstOff, int64_t size) {
    if (!ctxPtr || !srcBuf || !dstBuf || size <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLBuffer> s = (__bridge id<MTLBuffer>)(void *)srcBuf;
        id<MTLBuffer> d = (__bridge id<MTLBuffer>)(void *)dstBuf;
        if (s == d && srcOff == dstOff) return;
        id enc = ensure_blit_encoder(ctx);
        emit_m4_blit_intra_barrier_if_needed(ctx, enc);
        BOOL overlaps = (s == d)
            && ((NSUInteger)srcOff < (NSUInteger)dstOff + (NSUInteger)size)
            && ((NSUInteger)dstOff < (NSUInteger)srcOff + (NSUInteger)size);
        if (overlaps) {
            id<MTLBuffer> tmp = [ctx.device newBufferWithLength:(NSUInteger)size options:MTLResourceStorageModeShared];
            if (!tmp) return;
            cm_track_allocation(ctx, tmp);
            if (ctx.metal4Active) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4ComputeCommandEncoder> m4 = (id<MTL4ComputeCommandEncoder>)enc;
                    [m4 copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                              toBuffer:tmp destinationOffset:0
                                  size:(NSUInteger)size];
                    [m4 barrierAfterEncoderStages:MTLStageBlit
                              beforeEncoderStages:MTLStageBlit
                                visibilityOptions:MTL4VisibilityOptionDevice];
                    [m4 copyFromBuffer:tmp sourceOffset:0
                              toBuffer:d destinationOffset:(NSUInteger)dstOff
                                  size:(NSUInteger)size];
                }
            } else {
                id<MTLBlitCommandEncoder> m3 = (id<MTLBlitCommandEncoder>)enc;
                [m3 copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                          toBuffer:tmp destinationOffset:0
                              size:(NSUInteger)size];
                [m3 copyFromBuffer:tmp sourceOffset:0
                          toBuffer:d destinationOffset:(NSUInteger)dstOff
                              size:(NSUInteger)size];
            }
            cm_retire_object(ctx, tmp, atomic_load(&ctx->_nextSubmitSerial) + 1);
            ctx.blitHasOps = YES;
            return;
        }
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4ComputeCommandEncoder>)enc copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                                                         toBuffer:d destinationOffset:(NSUInteger)dstOff
                                                             size:(NSUInteger)size];
            }
        } else {
            [(id<MTLBlitCommandEncoder>)enc copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                                                  toBuffer:d destinationOffset:(NSUInteger)dstOff
                                                      size:(NSUInteger)size];
        }
        ctx.blitHasOps = YES;
    }
}

void cm_blit_write_texture(int64_t ctxPtr, int64_t texPtr, const void *srcData, int64_t dataSize,
                           int32_t rowStride, int32_t mip, int32_t slice,
                           int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!ctxPtr || !texPtr || !srcData || dataSize <= 0 || w <= 0 || h <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLBuffer> staging = [ctx.device newBufferWithBytes:srcData length:(NSUInteger)dataSize options:MTLResourceStorageModeShared];
        if (!staging) return;
        cm_track_allocation(ctx, staging);
        cm_blit_copy_buffer_to_texture(ctxPtr, (int64_t)(__bridge void *)staging, 0, rowStride,
                                       texPtr, mip, slice, x, y, w, h);
        cm_retire_object(ctx, staging, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
}

void cm_blit_copy_buffer_to_texture(int64_t ctxPtr, int64_t srcBuf, int64_t srcOff, int32_t srcRowBytes,
                                    int64_t dstTex, int32_t mip, int32_t slice,
                                    int32_t dstX, int32_t dstY, int32_t w, int32_t h) {
    if (!ctxPtr || !srcBuf || !dstTex || w <= 0 || h <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id enc = ensure_blit_encoder(ctx);
        id<MTLBuffer> s = (__bridge id<MTLBuffer>)(void *)srcBuf;
        id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)dstTex;
        NSUInteger bpr = srcRowBytes > 0 ? (NSUInteger)srcRowBytes : ((NSUInteger)w * cm_bytes_per_pixel(t.pixelFormat));
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4ComputeCommandEncoder>)enc copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                                                sourceBytesPerRow:bpr sourceBytesPerImage:0
                                                       sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                        toTexture:t destinationSlice:(NSUInteger)slice
                                                 destinationLevel:(NSUInteger)mip
                                                destinationOrigin:MTLOriginMake((NSUInteger)dstX, (NSUInteger)dstY, 0)];
            }
        } else {
            [(id<MTLBlitCommandEncoder>)enc copyFromBuffer:s sourceOffset:(NSUInteger)srcOff
                                         sourceBytesPerRow:bpr sourceBytesPerImage:0
                                                sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                 toTexture:t destinationSlice:(NSUInteger)slice
                                          destinationLevel:(NSUInteger)mip
                                         destinationOrigin:MTLOriginMake((NSUInteger)dstX, (NSUInteger)dstY, 0)];
        }
        ctx.blitHasOps = YES;
    }
}

void cm_blit_copy_texture_to_buffer(int64_t ctxPtr, int64_t srcTex, int32_t mip, int32_t slice,
                                    int32_t srcX, int32_t srcY, int32_t w, int32_t h,
                                    int64_t dstBuf, int64_t dstOff, int32_t dstRowBytes) {
    if (!ctxPtr || !srcTex || !dstBuf || w <= 0 || h <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id enc = ensure_blit_encoder(ctx);
        id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)srcTex;
        id<MTLBuffer> d = (__bridge id<MTLBuffer>)(void *)dstBuf;
        NSUInteger bpr = dstRowBytes > 0 ? (NSUInteger)dstRowBytes : ((NSUInteger)w * cm_bytes_per_pixel(t.pixelFormat));
        emit_m4_blit_intra_barrier_if_needed(ctx, enc);
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4ComputeCommandEncoder>)enc copyFromTexture:t sourceSlice:(NSUInteger)slice
                                                       sourceLevel:(NSUInteger)mip
                                                      sourceOrigin:MTLOriginMake((NSUInteger)srcX, (NSUInteger)srcY, 0)
                                                        sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                          toBuffer:d destinationOffset:(NSUInteger)dstOff
                                            destinationBytesPerRow:bpr destinationBytesPerImage:0];
            }
        } else {
            [(id<MTLBlitCommandEncoder>)enc copyFromTexture:t sourceSlice:(NSUInteger)slice
                                                sourceLevel:(NSUInteger)mip
                                               sourceOrigin:MTLOriginMake((NSUInteger)srcX, (NSUInteger)srcY, 0)
                                                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                   toBuffer:d destinationOffset:(NSUInteger)dstOff
                                     destinationBytesPerRow:bpr destinationBytesPerImage:0];
        }
        ctx.blitHasOps = YES;
    }
}

void cm_blit_copy_texture(int64_t ctxPtr, int64_t srcTex, int32_t srcMip, int32_t srcSlice,
                          int32_t srcX, int32_t srcY, int64_t dstTex, int32_t dstMip, int32_t dstSlice,
                          int32_t dstX, int32_t dstY, int32_t w, int32_t h) {
    if (!ctxPtr || !srcTex || !dstTex || w <= 0 || h <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id enc = ensure_blit_encoder(ctx);
        id<MTLTexture> s = (__bridge id<MTLTexture>)(void *)srcTex;
        id<MTLTexture> d = (__bridge id<MTLTexture>)(void *)dstTex;
        emit_m4_blit_intra_barrier_if_needed(ctx, enc);
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4ComputeCommandEncoder>)enc copyFromTexture:s sourceSlice:(NSUInteger)srcSlice
                                                       sourceLevel:(NSUInteger)srcMip
                                                      sourceOrigin:MTLOriginMake((NSUInteger)srcX, (NSUInteger)srcY, 0)
                                                        sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                         toTexture:d destinationSlice:(NSUInteger)dstSlice
                                                  destinationLevel:(NSUInteger)dstMip
                                                 destinationOrigin:MTLOriginMake((NSUInteger)dstX, (NSUInteger)dstY, 0)];
            }
        } else {
            [(id<MTLBlitCommandEncoder>)enc copyFromTexture:s sourceSlice:(NSUInteger)srcSlice
                                                sourceLevel:(NSUInteger)srcMip
                                               sourceOrigin:MTLOriginMake((NSUInteger)srcX, (NSUInteger)srcY, 0)
                                                 sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                                                  toTexture:d destinationSlice:(NSUInteger)dstSlice
                                           destinationLevel:(NSUInteger)dstMip
                                          destinationOrigin:MTLOriginMake((NSUInteger)dstX, (NSUInteger)dstY, 0)];
        }
        ctx.blitHasOps = YES;
    }
}

// ---- Render Pass & Drawing ----

static void reset_pass_cache(CMContext *ctx) {
    ctx.boundPipeline = 0;
    ctx.boundDepthKey = UINT32_MAX;
    ctx.boundCullMode = -1;
    ctx.boundFillMode = -1;
    ctx.boundIndexBuffer = 0;
    memset(ctx->_boundVtxBufs, 0, sizeof(ctx->_boundVtxBufs));
    memset(ctx->_boundVtxOffsets, 0, sizeof(ctx->_boundVtxOffsets));
    memset(ctx->_boundVtxStrides, 0, sizeof(ctx->_boundVtxStrides));
    memset(ctx->_boundTextures, 0, sizeof(ctx->_boundTextures));
    memset(ctx->_boundSamplers, 0, sizeof(ctx->_boundSamplers));
    ctx.m4ArgDirtyVertex = YES;
    ctx.m4ArgDirtyFragment = YES;
}

int32_t cm_pass_begin(int64_t ctxPtr,
                      const int64_t *colorViewPtrs, const int32_t *colorHasClear, const float *colorClearsRGBA,
                      int32_t colorCount,
                      int64_t depthViewPtr, int32_t depthHasClear, double depthClear,
                      int32_t areaX, int32_t areaY, int32_t areaW, int32_t areaH,
                      const char *labelUtf8) {
    if (!ctxPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        ensure_cmd_begun(ctx);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);
        reset_pass_cache(ctx);

        int32_t texW = 0;
        int32_t texH = 0;
        ctx.currentColorCount = MIN(colorCount, CM_MAX_COLOR_ATTACHMENTS);
        ctx.currentHasDepth = depthViewPtr != 0;
        ctx.currentDepthFormat = MTLPixelFormatInvalid;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                for (int32_t i = 0; i < ctx.currentColorCount; i++) {
                    id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
                    ctx->_currentColorFormats[i] = tex.pixelFormat;
                    if (texW <= 0) {
                        texW = (int32_t)tex.width;
                        texH = (int32_t)tex.height;
                    }
                    rpd.colorAttachments[(NSUInteger)i].texture = tex;
                    rpd.colorAttachments[(NSUInteger)i].loadAction = colorHasClear[i] ? MTLLoadActionClear : MTLLoadActionLoad;
                    rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
                    if (colorHasClear[i]) {
                        rpd.colorAttachments[(NSUInteger)i].clearColor = MTLClearColorMake(
                            colorClearsRGBA[i * 4 + 0], colorClearsRGBA[i * 4 + 1],
                            colorClearsRGBA[i * 4 + 2], colorClearsRGBA[i * 4 + 3]);
                    }
                }
                if (depthViewPtr) {
                    id<MTLTexture> dtex = (__bridge id<MTLTexture>)(void *)depthViewPtr;
                    ctx.currentDepthFormat = dtex.pixelFormat;
                    if (texW <= 0) {
                        texW = (int32_t)dtex.width;
                        texH = (int32_t)dtex.height;
                    }
                    configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment,
                                                        dtex, depthHasClear != 0, depthClear);
                }
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return 0;
                if (ctx.debugLabels && labelUtf8) enc.label = [NSString stringWithUTF8String:labelUtf8];
                [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4VertexArgTable atStages:MTLRenderStageVertex];
                [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable atStages:MTLRenderStageFragment];
                [enc setFrontFacingWinding:MTLWindingClockwise];
                ctx.activeRenderEnc = enc;
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            for (int32_t i = 0; i < ctx.currentColorCount; i++) {
                id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
                ctx->_currentColorFormats[i] = tex.pixelFormat;
                if (texW <= 0) {
                    texW = (int32_t)tex.width;
                    texH = (int32_t)tex.height;
                }
                rpd.colorAttachments[(NSUInteger)i].texture = tex;
                rpd.colorAttachments[(NSUInteger)i].loadAction = colorHasClear[i] ? MTLLoadActionClear : MTLLoadActionLoad;
                rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
                if (colorHasClear[i]) {
                    rpd.colorAttachments[(NSUInteger)i].clearColor = MTLClearColorMake(
                        colorClearsRGBA[i * 4 + 0], colorClearsRGBA[i * 4 + 1],
                        colorClearsRGBA[i * 4 + 2], colorClearsRGBA[i * 4 + 3]);
                }
            }
            if (depthViewPtr) {
                id<MTLTexture> dtex = (__bridge id<MTLTexture>)(void *)depthViewPtr;
                ctx.currentDepthFormat = dtex.pixelFormat;
                if (texW <= 0) {
                    texW = (int32_t)dtex.width;
                    texH = (int32_t)dtex.height;
                }
                configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment,
                                                    dtex, depthHasClear != 0, depthClear);
            }
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return 0;
            if (ctx.debugLabels && labelUtf8) enc.label = [NSString stringWithUTF8String:labelUtf8];
            [enc setFrontFacingWinding:MTLWindingClockwise];
            ctx.activeRenderEnc = enc;
        }

        ctx.currentPassWidth = MAX(1, texW > 0 ? texW : areaW);
        ctx.currentPassHeight = MAX(1, texH > 0 ? texH : areaH);
        MTLViewport vp = { 0.0, 0.0, (double)ctx.currentPassWidth, (double)ctx.currentPassHeight, 0.0, 1.0 };
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
        } else {
            [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
        }
        if (areaW > 0 && areaH > 0) {
            cm_pass_set_scissor(ctxPtr, 1, areaX, areaY, areaW, areaH);
        } else {
            cm_pass_set_scissor(ctxPtr, 0, 0, 0, 0, 0);
        }
        return 1;
    }
}

void cm_pass_end(int64_t ctxPtr) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            emit_m4_render_producer_barrier(enc);
            [enc endEncoding];
        }
    } else {
        [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc endEncoding];
    }
    ctx.activeRenderEnc = nil;
}

void cm_pass_set_pipeline(int64_t ctxPtr, int64_t pipePtr) {
    if (!ctxPtr || !pipePtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (ctx.boundPipeline == (uintptr_t)pipePtr) return;

    CMPipelineBox *box = (__bridge CMPipelineBox *)(void *)pipePtr;
    ctx.boundPipeline = (uintptr_t)pipePtr;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            [enc setRenderPipelineState:box.state];
            if (ctx.boundDepthKey != box.depthKey) {
                [enc setDepthStencilState:box.depthState];
                ctx.boundDepthKey = box.depthKey;
            }
            if (ctx.boundCullMode != (int32_t)box.cullMode) {
                [enc setCullMode:box.cullMode];
                ctx.boundCullMode = (int32_t)box.cullMode;
            }
            if (ctx.boundFillMode != (int32_t)box.fillMode) {
                [enc setTriangleFillMode:box.fillMode];
                ctx.boundFillMode = (int32_t)box.fillMode;
            }
            [enc setDepthBias:box.depthBiasConst slopeScale:box.depthBiasSlope clamp:0.0f];
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        [enc setRenderPipelineState:box.state];
        if (ctx.boundDepthKey != box.depthKey) {
            [enc setDepthStencilState:box.depthState];
            ctx.boundDepthKey = box.depthKey;
        }
        if (ctx.boundCullMode != (int32_t)box.cullMode) {
            [enc setCullMode:box.cullMode];
            ctx.boundCullMode = (int32_t)box.cullMode;
        }
        if (ctx.boundFillMode != (int32_t)box.fillMode) {
            [enc setTriangleFillMode:box.fillMode];
            ctx.boundFillMode = (int32_t)box.fillMode;
        }
        [enc setDepthBias:box.depthBiasConst slopeScale:box.depthBiasSlope clamp:0.0f];
    }
}

void cm_pass_set_scissor(int64_t ctxPtr, int32_t enabled, int32_t x, int32_t y, int32_t w, int32_t h) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    MTLScissorRect sr;
    if (enabled && w > 0 && h > 0) {
        NSUInteger sx = (NSUInteger)MAX(0, MIN(x, ctx.currentPassWidth - 1));
        NSUInteger sy = (NSUInteger)MAX(0, MIN(y, ctx.currentPassHeight - 1));
        NSUInteger sw = (NSUInteger)MIN(w, ctx.currentPassWidth - (int32_t)sx);
        NSUInteger sh = (NSUInteger)MIN(h, ctx.currentPassHeight - (int32_t)sy);
        sr = (MTLScissorRect){ sx, sy, MAX(1UL, sw), MAX(1UL, sh) };
    } else {
        sr = (MTLScissorRect){ 0, 0, (NSUInteger)ctx.currentPassWidth, (NSUInteger)ctx.currentPassHeight };
    }
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc setScissorRect:sr];
    } else {
        [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc setScissorRect:sr];
    }
}

void cm_pass_set_uniform_buffer(int64_t ctxPtr, int32_t slot, int64_t bufPtr, int64_t offset) {
    if (!ctxPtr || slot < 0 || slot >= CM_MAX_UNIFORM_BUFFERS || !bufPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTLGPUAddress addr = buf.gpuAddress + (MTLGPUAddress)offset;
            [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setAddress:addr atIndex:(NSUInteger)slot];
            [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setAddress:addr atIndex:(NSUInteger)slot];
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        [enc setVertexBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)slot];
        [enc setFragmentBuffer:buf offset:(NSUInteger)offset atIndex:(NSUInteger)slot];
    }
}

void cm_pass_set_texture_sampler(int64_t ctxPtr, int32_t texSlot, int64_t texViewPtr,
                                 int32_t sampSlot, int64_t sampPtr) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    id<MTLTexture> tex = texViewPtr ? (__bridge id<MTLTexture>)(void *)texViewPtr : nil;
    id<MTLSamplerState> samp = sampPtr ? (__bridge id<MTLSamplerState>)(void *)sampPtr : nil;

    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            if (texSlot >= 0 && texSlot < CM_MAX_TEXTURES && tex) {
                if (ctx->_boundTextures[texSlot] != (uintptr_t)texViewPtr) {
                    ctx->_boundTextures[texSlot] = (uintptr_t)texViewPtr;
                    [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setTexture:tex.gpuResourceID atIndex:(NSUInteger)texSlot];
                    [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setTexture:tex.gpuResourceID atIndex:(NSUInteger)texSlot];
                }
            }
            if (sampSlot >= 0 && sampSlot < CM_MAX_SAMPLERS && samp) {
                if (ctx->_boundSamplers[sampSlot] != (uintptr_t)sampPtr) {
                    ctx->_boundSamplers[sampSlot] = (uintptr_t)sampPtr;
                    [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setSamplerState:samp.gpuResourceID atIndex:(NSUInteger)sampSlot];
                    [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setSamplerState:samp.gpuResourceID atIndex:(NSUInteger)sampSlot];
                }
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        if (texSlot >= 0 && texSlot < CM_MAX_TEXTURES && ctx->_boundTextures[texSlot] != (uintptr_t)texViewPtr) {
            ctx->_boundTextures[texSlot] = (uintptr_t)texViewPtr;
            [enc setVertexTexture:tex atIndex:(NSUInteger)texSlot];
            [enc setFragmentTexture:tex atIndex:(NSUInteger)texSlot];
        }
        if (sampSlot >= 0 && sampSlot < CM_MAX_SAMPLERS && ctx->_boundSamplers[sampSlot] != (uintptr_t)sampPtr) {
            ctx->_boundSamplers[sampSlot] = (uintptr_t)sampPtr;
            [enc setVertexSamplerState:samp atIndex:(NSUInteger)sampSlot];
            [enc setFragmentSamplerState:samp atIndex:(NSUInteger)sampSlot];
        }
    }
}

void cm_pass_push_constants(int64_t ctxPtr, int32_t slot, const void *data, int32_t size) {
    if (!ctxPtr || !data || size <= 0 || slot < 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            NSUInteger aligned = (((NSUInteger)size) + 15UL) & ~15UL;
            NSUInteger slotLimit = ((ctx.activeM4AllocatorIdx + 1) * (ctx.pushRingSize / CM_INFLIGHT_SLOTS));
            if (ctx.pushRingOffset + aligned > slotLimit) {
                ctx.pushRingOffset = ctx.activeM4AllocatorIdx * (ctx.pushRingSize / CM_INFLIGHT_SLOTS);
            }
            uint8_t *dst = (uint8_t *)ctx.pushRingBuffer.contents + ctx.pushRingOffset;
            memcpy(dst, data, (size_t)size);
            MTLGPUAddress addr = ctx.pushRingBuffer.gpuAddress + ctx.pushRingOffset;
            ctx.pushRingOffset += aligned;
            [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setAddress:addr atIndex:(NSUInteger)slot];
            [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setAddress:addr atIndex:(NSUInteger)slot];
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        [enc setVertexBytes:data length:(NSUInteger)size atIndex:(NSUInteger)slot];
        [enc setFragmentBytes:data length:(NSUInteger)size atIndex:(NSUInteger)slot];
    }
}

void cm_pass_set_vertex_buffer(int64_t ctxPtr, int32_t slot, int64_t bufPtr, int64_t offset, int32_t stride) {
    if (!ctxPtr || slot < 0 || slot >= CM_MAX_VERTEX_BUFFERS || !bufPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
    NSUInteger metalSlot = CM_VERTEX_BUFFER_BASE + (NSUInteger)slot;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTLGPUAddress addr = buf.gpuAddress + (MTLGPUAddress)offset;
            [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setAddress:addr atIndex:metalSlot];
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        if (ctx->_boundVtxBufs[slot] == (uintptr_t)bufPtr) {
            if (ctx->_boundVtxOffsets[slot] != (NSUInteger)offset) {
                ctx->_boundVtxOffsets[slot] = (NSUInteger)offset;
                [enc setVertexBufferOffset:(NSUInteger)offset atIndex:metalSlot];
            }
        } else {
            ctx->_boundVtxBufs[slot] = (uintptr_t)bufPtr;
            ctx->_boundVtxOffsets[slot] = (NSUInteger)offset;
            [enc setVertexBuffer:buf offset:(NSUInteger)offset atIndex:metalSlot];
        }
    }
}

void cm_pass_set_index_buffer(int64_t ctxPtr, int64_t bufPtr, int32_t isInt32) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    ctx.boundIndexBuffer = (uintptr_t)bufPtr;
    ctx.boundIndexType = isInt32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
}

static id<MTLBuffer> ensure_fan_index_buffer(CMContext *ctx, NSUInteger neededIndices) {
    if (ctx.fanIndexBuffer && ctx.fanIndexCapacity >= neededIndices) {
        return ctx.fanIndexBuffer;
    }
    NSUInteger neededTris = (neededIndices + 2UL) / 3UL;
    NSUInteger existingTris = ctx.fanIndexCapacity / 3UL;
    NSUInteger triCap = MAX(MAX(neededTris, 256UL), existingTris * 2UL);
    NSUInteger idxCap = triCap * 3UL;
    id<MTLBuffer> buf = [ctx.device newBufferWithLength:idxCap * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    if (!buf) return nil;
    if (ctx.debugLabels) {
        buf.label = @"CelestiaMetal.FanIndices";
    }
    uint32_t *idx = (uint32_t *)buf.contents;
    for (NSUInteger i = 0; i < triCap; i++) {
        idx[i * 3 + 0] = 0;
        idx[i * 3 + 1] = (uint32_t)(i + 1);
        idx[i * 3 + 2] = (uint32_t)(i + 2);
    }
    cm_track_allocation(ctx, buf);
    if (ctx.fanIndexBuffer) {
        cm_retire_object(ctx, ctx.fanIndexBuffer, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    ctx.fanIndexBuffer = buf;
    ctx.fanIndexCapacity = idxCap;
    return buf;
}

void cm_pass_draw(int64_t ctxPtr, int32_t topology, int32_t vertexCount, int32_t instanceCount,
                  int32_t firstVertex, int32_t firstInstance) {
    if (!ctxPtr || vertexCount <= 0 || instanceCount <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (topology == CM_TOPO_TRIANGLE_FAN) {
        if (vertexCount < 3) return;
        NSUInteger idxCount = (NSUInteger)(vertexCount - 2) * 3UL;
        id<MTLBuffer> fbuf = ensure_fan_index_buffer(ctx, idxCount);
        if (!fbuf) return;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                                                              indexCount:idxCount
                                                                               indexType:MTLIndexTypeUInt32
                                                                             indexBuffer:fbuf.gpuAddress
                                                                       indexBufferLength:fbuf.length
                                                                           instanceCount:(NSUInteger)instanceCount
                                                                              baseVertex:(NSInteger)firstVertex
                                                                            baseInstance:(NSUInteger)firstInstance];
            }
        } else {
            [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                                                         indexCount:idxCount
                                                                          indexType:MTLIndexTypeUInt32
                                                                        indexBuffer:fbuf
                                                                  indexBufferOffset:0
                                                                      instanceCount:(NSUInteger)instanceCount
                                                                         baseVertex:(NSInteger)firstVertex
                                                                       baseInstance:(NSUInteger)firstInstance];
        }
        return;
    }
    MTLPrimitiveType pt = cm_primitive_type(topology);
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc drawPrimitives:pt
                                                                 vertexStart:(NSUInteger)firstVertex
                                                                 vertexCount:(NSUInteger)vertexCount
                                                               instanceCount:(NSUInteger)instanceCount
                                                                baseInstance:(NSUInteger)firstInstance];
        }
    } else {
        [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc drawPrimitives:pt
                                                             vertexStart:(NSUInteger)firstVertex
                                                             vertexCount:(NSUInteger)vertexCount
                                                           instanceCount:(NSUInteger)instanceCount
                                                            baseInstance:(NSUInteger)firstInstance];
    }
}

void cm_pass_draw_indexed(int64_t ctxPtr, int32_t topology, int64_t indexBufOffset,
                          int32_t indexCount, int32_t instanceCount,
                          int32_t baseVertex, int32_t firstIndex, int32_t firstInstance) {
    if (!ctxPtr || indexCount <= 0 || instanceCount <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc || !ctx.boundIndexBuffer) return;
    id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)(void *)ctx.boundIndexBuffer;
    NSUInteger stride = (ctx.boundIndexType == MTLIndexTypeUInt32) ? 4 : 2;
    NSUInteger byteOff = (NSUInteger)indexBufOffset + (NSUInteger)firstIndex * stride;
    MTLPrimitiveType pt = cm_primitive_type(topology);

    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc drawIndexedPrimitives:pt
                                                                          indexCount:(NSUInteger)indexCount
                                                                           indexType:ctx.boundIndexType
                                                                         indexBuffer:ibuf.gpuAddress + byteOff
                                                                   indexBufferLength:ibuf.length - byteOff
                                                                       instanceCount:(NSUInteger)instanceCount
                                                                          baseVertex:(NSInteger)baseVertex
                                                                        baseInstance:(NSUInteger)firstInstance];
        }
    } else {
        [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc drawIndexedPrimitives:pt
                                                                     indexCount:(NSUInteger)indexCount
                                                                      indexType:ctx.boundIndexType
                                                                    indexBuffer:ibuf
                                                              indexBufferOffset:byteOff
                                                                  instanceCount:(NSUInteger)instanceCount
                                                                     baseVertex:(NSInteger)baseVertex
                                                                   baseInstance:(NSUInteger)firstInstance];
    }
}

void cm_pass_multi_draw(int64_t ctxPtr, int32_t topology, const int32_t *firstVertices,
                        const int32_t *vertexCounts, int32_t count, int32_t instanceCount, int32_t firstInstance) {
    if (!ctxPtr || !firstVertices || !vertexCounts || count <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    MTLPrimitiveType pt = cm_primitive_type(topology);
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                if (vertexCounts[i] <= 0) continue;
                [enc drawPrimitives:pt vertexStart:(NSUInteger)firstVertices[i] vertexCount:(NSUInteger)vertexCounts[i]
                      instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)firstInstance];
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        for (int32_t i = 0; i < count; i++) {
            if (vertexCounts[i] <= 0) continue;
            [enc drawPrimitives:pt vertexStart:(NSUInteger)firstVertices[i] vertexCount:(NSUInteger)vertexCounts[i]
                  instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)firstInstance];
        }
    }
}

void cm_pass_multi_draw_indexed(int64_t ctxPtr, int32_t topology,
                                const int64_t *indexOffsetsBytes, const int32_t *indexCounts,
                                const int32_t *baseVertices, int32_t count,
                                int32_t instanceCount, int32_t firstInstance) {
    if (!ctxPtr || !indexOffsetsBytes || !indexCounts || count <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc || !ctx.boundIndexBuffer) return;
    id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)(void *)ctx.boundIndexBuffer;
    MTLGPUAddress ibase = ibuf.gpuAddress;
    NSUInteger ilen = ibuf.length;
    MTLPrimitiveType pt = cm_primitive_type(topology);
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                int32_t ic = indexCounts[i];
                if (ic <= 0) continue;
                NSUInteger off = (NSUInteger)indexOffsetsBytes[i];
                if (off >= ilen) continue;
                NSInteger bv = baseVertices ? (NSInteger)baseVertices[i] : 0;
                [enc drawIndexedPrimitives:pt indexCount:(NSUInteger)ic indexType:ctx.boundIndexType
                               indexBuffer:ibase + off indexBufferLength:ilen - off
                             instanceCount:(NSUInteger)instanceCount baseVertex:bv baseInstance:(NSUInteger)firstInstance];
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        for (int32_t i = 0; i < count; i++) {
            int32_t ic = indexCounts[i];
            if (ic <= 0) continue;
            NSUInteger off = (NSUInteger)indexOffsetsBytes[i];
            NSInteger bv = baseVertices ? (NSInteger)baseVertices[i] : 0;
            [enc drawIndexedPrimitives:pt indexCount:(NSUInteger)ic indexType:ctx.boundIndexType
                           indexBuffer:ibuf indexBufferOffset:off
                         instanceCount:(NSUInteger)instanceCount baseVertex:bv baseInstance:(NSUInteger)firstInstance];
        }
    }
}

void cm_pass_draw_indirect(int64_t ctxPtr, int32_t topology, int64_t indirectBufPtr, int64_t offset,
                           int32_t count, int32_t stride, int32_t indexed) {
    if (!ctxPtr || !indirectBufPtr || count <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    id<MTLBuffer> ind = (__bridge id<MTLBuffer>)(void *)indirectBufPtr;
    MTLPrimitiveType pt = cm_primitive_type(topology);
    NSUInteger step = stride > 0 ? (NSUInteger)stride : (indexed ? 20 : 16);

    if (indexed) {
        if (!ctx.boundIndexBuffer) return;
        id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)(void *)ctx.boundIndexBuffer;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
                for (int32_t i = 0; i < count; i++) {
                    [enc drawIndexedPrimitives:pt indexType:ctx.boundIndexType
                                   indexBuffer:ibuf.gpuAddress indexBufferLength:ibuf.length
                                indirectBuffer:ind.gpuAddress + (MTLGPUAddress)offset + (MTLGPUAddress)i * step];
                }
            }
        } else {
            id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                [enc drawIndexedPrimitives:pt indexType:ctx.boundIndexType
                               indexBuffer:ibuf indexBufferOffset:0
                            indirectBuffer:ind indirectBufferOffset:(NSUInteger)offset + (NSUInteger)i * step];
            }
        }
    } else {
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
                for (int32_t i = 0; i < count; i++) {
                    [enc drawPrimitives:pt indirectBuffer:ind.gpuAddress + (MTLGPUAddress)offset + (MTLGPUAddress)i * step];
                }
            }
        } else {
            id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                [enc drawPrimitives:pt indirectBuffer:ind indirectBufferOffset:(NSUInteger)offset + (NSUInteger)i * step];
            }
        }
    }
}
