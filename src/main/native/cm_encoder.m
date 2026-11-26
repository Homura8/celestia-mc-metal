#import "celestia_metal.h"
#include <mach/mach_time.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"
// Hot draw/bind entry points below branch on ctx.metal4Active without @available: metal4Active is only ever set on
// macOS 26+ (cm_device_create), and @available costs a __isPlatformVersionAtLeast call per invocation.

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

void cm_ensure_cmd_begun(CMContext *ctx) {
    if (ctx.metal4Active) {
        if (ctx.activeM4CmdBuf) return;
        if (@available(macOS 26.0, *)) {
            uint64_t next = atomic_load(&ctx->_nextSubmitSerial) + 1;
            if (next > CM_INFLIGHT_SLOTS) {
                cm_wait_submit_accounted(ctx, next - CM_INFLIGHT_SLOTS, 5000000000ULL, &ctx->_waitThrottleUs);
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

static void flush_pending_clears(CMContext *ctx);

static id ensure_blit_encoder(CMContext *ctx) {
    cm_ensure_cmd_begun(ctx);
    if (ctx.activeRenderEnc) {
        cm_pass_end((int64_t)(__bridge void *)ctx);
    }
    if (ctx->_pendingClearCount > 0) {
        flush_pending_clears(ctx);
    }
    if (!ctx.activeBlitEnc) {
        ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
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

void cm_emit_m4_render_producer_barrier(id rawEnc) {
    if (@available(macOS 26.0, *)) {
        id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)rawEnc;
        [enc barrierAfterStages:MTLStageVertex | MTLStageFragment
              beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
              visibilityOptions:MTL4VisibilityOptionDevice];
    }
}

void cm_cmd_begin(int64_t ctxPtr) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_ensure_cmd_begun(ctx);
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
        cm_flush_encoders(ctx);

        if (!ctx.activeM4CmdBuf && !ctx.activeM3CmdBuf) {
            cm_drain_retired(ctx);
            return atomic_load(&ctx->_completedSubmitSerial);
        }

        cm_commit_residency_if_dirty(ctx);

        uint64_t serial = atomic_fetch_add(&ctx->_nextSubmitSerial, 1) + 1;
        int32_t cap = maxInFlight > 0 ? MIN(maxInFlight, CM_INFLIGHT_SLOTS) : 2;
        if (serial > (uint64_t)cap) {
            cm_wait_submit_accounted(ctx, serial - (uint64_t)cap, 5000000000ULL, &ctx->_waitThrottleUs);
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

static BOOL advance_completed(CMContext *ctx, uint64_t signaled) {
    uint64_t cur = atomic_load(&ctx->_completedSubmitSerial);
    BOOL advanced = NO;
    while (cur < signaled) {
        if (atomic_compare_exchange_weak(&ctx->_completedSubmitSerial, &cur, signaled)) { advanced = YES; break; }
    }
    return advanced;
}

int32_t cm_wait_submit_accounted(CMContext *ctx, uint64_t serial, uint64_t timeoutNs, _Atomic int64_t *waitUs) {
    if (!ctx || serial == 0) return 1;
    // Fast path (also the whole cost of a zero-timeout poll): one signaledValue read. Retired objects are only
    // drained when the completed serial actually advanced, not on every poll.
    uint64_t signaled = ctx.submitEvent.signaledValue;
    if (signaled >= serial) {
        if (advance_completed(ctx, signaled)) cm_drain_retired(ctx);
        return 1;
    }
    if (timeoutNs == 0) return 0;
    uint64_t ms = timeoutNs / 1000000ULL;
    if (ms == 0) ms = 1;
    uint64_t t0 = mach_absolute_time();
    BOOL ok = [ctx.submitEvent waitUntilSignaledValue:serial timeoutMS:ms];
    if (waitUs) {
        static mach_timebase_info_data_t tb;
        if (tb.denom == 0) mach_timebase_info(&tb);
        uint64_t ns = (mach_absolute_time() - t0) * tb.numer / tb.denom;
        atomic_fetch_add(waitUs, (int64_t)(ns / 1000ULL));
    }
    if (ok) {
        if (advance_completed(ctx, ctx.submitEvent.signaledValue)) cm_drain_retired(ctx);
    }
    return ok ? 1 : 0;
}

int32_t cm_wait_submit(int64_t ctxPtr, uint64_t serial, uint64_t timeoutNs) {
    if (!ctxPtr || serial == 0) return 1;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return cm_wait_submit_accounted(ctx, serial, timeoutNs, &ctx->_waitFenceUs);
}

// ---- Clears (deferred & folded into the next pass load action when possible) ----

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

// Emits a standalone clear render encoder for a color and/or depth texture (either may be nil).
// Requires an active command buffer and no open render/blit encoder.
static void emit_clear_encoder(CMContext *ctx, id<MTLTexture> ctex, const float *rgba,
                               id<MTLTexture> dtex, double depth) {
    if (!ctex && !dtex) return;
    ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
            if (ctex) {
                rpd.colorAttachments[0].texture = ctex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
            }
            if (dtex) configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, dtex, YES, depth);
            id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
            cm_emit_m4_render_producer_barrier(enc);
            [enc endEncoding];
        }
    } else {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        if (ctex) {
            rpd.colorAttachments[0].texture = ctex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]);
        }
        if (dtex) configure_depth_stencil_attachments(rpd.depthAttachment, rpd.stencilAttachment, dtex, YES, depth);
        id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
        [enc endEncoding];
    }
}

static void remove_pending_clear(CMContext *ctx, int32_t idx) {
    int32_t last = ctx->_pendingClearCount - 1;
    for (int32_t i = idx; i < last; i++) {
        ctx->_pendingClearTex[i] = ctx->_pendingClearTex[i + 1];
        memcpy(ctx->_pendingClearColor[i], ctx->_pendingClearColor[i + 1], sizeof(float) * 4);
        ctx->_pendingClearDepth[i] = ctx->_pendingClearDepth[i + 1];
        ctx->_pendingClearIsDepth[i] = ctx->_pendingClearIsDepth[i + 1];
    }
    ctx->_pendingClearTex[last] = nil;
    ctx->_pendingClearCount = last;
}

// Emits every deferred clear in request order, pairing an adjacent color+depth request into one encoder.
static void flush_pending_clears(CMContext *ctx) {
    int32_t n = ctx->_pendingClearCount;
    if (n <= 0) return;
    cm_ensure_cmd_begun(ctx);
    for (int32_t i = 0; i < n; i++) {
        id<MTLTexture> tex = ctx->_pendingClearTex[i];
        if (!ctx->_pendingClearIsDepth[i] && i + 1 < n && ctx->_pendingClearIsDepth[i + 1]) {
            emit_clear_encoder(ctx, tex, ctx->_pendingClearColor[i], ctx->_pendingClearTex[i + 1], ctx->_pendingClearDepth[i + 1]);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED] += 2;
            i++;
        } else if (ctx->_pendingClearIsDepth[i]) {
            emit_clear_encoder(ctx, nil, NULL, tex, ctx->_pendingClearDepth[i]);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED]++;
        } else {
            emit_clear_encoder(ctx, tex, ctx->_pendingClearColor[i], nil, 0.0);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED]++;
        }
    }
    for (int32_t i = 0; i < n; i++) ctx->_pendingClearTex[i] = nil;
    ctx->_pendingClearCount = 0;
}

static void defer_clear(CMContext *ctx, id<MTLTexture> tex, const float *rgba, BOOL isDepth, double depth) {
    // A later clear of the same texture supersedes the earlier one.
    for (int32_t i = 0; i < ctx->_pendingClearCount; i++) {
        if (ctx->_pendingClearTex[i] == tex && ctx->_pendingClearIsDepth[i] == isDepth) {
            remove_pending_clear(ctx, i);
            break;
        }
    }
    if (ctx->_pendingClearCount >= CM_MAX_PENDING_CLEARS) {
        flush_pending_clears(ctx);
    }
    int32_t k = ctx->_pendingClearCount++;
    ctx->_pendingClearTex[k] = tex;
    ctx->_pendingClearIsDepth[k] = isDepth;
    ctx->_pendingClearDepth[k] = depth;
    if (rgba) memcpy(ctx->_pendingClearColor[k], rgba, sizeof(float) * 4);
}

static void begin_clear(CMContext *ctx) {
    cm_ensure_cmd_begun(ctx);
    if (ctx.activeRenderEnc) cm_pass_end((int64_t)(__bridge void *)ctx);
    cm_end_blit_if_active(ctx);
}

void cm_flush_encoders(CMContext *ctx) {
    if (!ctx) return;
    if (ctx.activeRenderEnc) cm_pass_end((int64_t)(__bridge void *)ctx);
    cm_end_blit_if_active(ctx);
    if (ctx->_pendingClearCount > 0) flush_pending_clears(ctx);
}

void cm_blit_clear_color(int64_t ctxPtr, int64_t texPtr, float r, float g, float b, float a) {
    if (!ctxPtr || !texPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        begin_clear(ctx);
        id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)texPtr;
        float rgba[4] = { r, g, b, a };
        if (ctx.deferClearsEnabled) {
            defer_clear(ctx, tex, rgba, NO, 0.0);
        } else {
            emit_clear_encoder(ctx, tex, rgba, nil, 0.0);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED]++;
        }
    }
}

void cm_blit_clear_depth(int64_t ctxPtr, int64_t texPtr, double depth) {
    if (!ctxPtr || !texPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        begin_clear(ctx);
        id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)texPtr;
        if (ctx.deferClearsEnabled) {
            defer_clear(ctx, tex, NULL, YES, depth);
        } else {
            emit_clear_encoder(ctx, nil, NULL, tex, depth);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED]++;
        }
    }
}

void cm_blit_clear_color_depth(int64_t ctxPtr, int64_t colorTexPtr, float r, float g, float b, float a,
                               int64_t depthTexPtr, double depth) {
    if (!ctxPtr || !colorTexPtr || !depthTexPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        begin_clear(ctx);
        id<MTLTexture> ctex = (__bridge id<MTLTexture>)(void *)colorTexPtr;
        id<MTLTexture> dtex = (__bridge id<MTLTexture>)(void *)depthTexPtr;
        float rgba[4] = { r, g, b, a };
        if (ctx.deferClearsEnabled) {
            defer_clear(ctx, ctex, rgba, NO, 0.0);
            defer_clear(ctx, dtex, NULL, YES, depth);
        } else {
            emit_clear_encoder(ctx, ctex, rgba, dtex, depth);
            ctx->_stats[CM_STAT_CLEARS_FLUSHED] += 2;
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
        // Metal 4 does not order blits inside one encoder: the source buffer is commonly filled by the previous
        // blit (writeToBuffer staging copy) and the destination may be written by an earlier upload.
        emit_m4_blit_intra_barrier_if_needed(ctx, enc);
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

void cm_reset_pass_cache(CMContext *ctx) {
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
    memset(ctx->_boundUboAddrV, 0, sizeof(ctx->_boundUboAddrV));
    memset(ctx->_boundUboAddrF, 0, sizeof(ctx->_boundUboAddrF));
    memset(ctx->_boundVtxAddr, 0, sizeof(ctx->_boundVtxAddr));
    ctx->_lastPushSize = -1;
    ctx->_lastPushAddr = 0;
    ctx.m4ArgDirtyVertex = YES;
    ctx.m4ArgDirtyFragment = YES;
}

static id<MTLTexture> base_texture(id<MTLTexture> t) {
    id<MTLTexture> parent = t.parentTexture;
    return parent ? parent : t;
}

// A clear recorded for texture `cleared` (mip 0 / slice 0) applies to attachment view `view`
// only when the view renders into that same mip 0 / slice 0.
static BOOL clear_matches_view(id<MTLTexture> cleared, id<MTLTexture> view) {
    if (base_texture(cleared) != base_texture(view)) return NO;
    if (cleared.parentTexture && (cleared.parentRelativeLevel != 0 || cleared.parentRelativeSlice != 0)) return NO;
    if (view.parentTexture && (view.parentRelativeLevel != 0 || view.parentRelativeSlice != 0)) return NO;
    return YES;
}

static int32_t find_pending_clear(CMContext *ctx, id<MTLTexture> view, BOOL isDepth) {
    for (int32_t i = 0; i < ctx->_pendingClearCount; i++) {
        if (ctx->_pendingClearIsDepth[i] == isDepth && clear_matches_view(ctx->_pendingClearTex[i], view)) {
            return i;
        }
    }
    return -1;
}

static void set_pass_viewport(CMContext *ctx) {
    MTLViewport vp = { 0.0, 0.0, (double)ctx.currentPassWidth, (double)ctx.currentPassHeight, 0.0, 1.0 };
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
    } else {
        [(id<MTLRenderCommandEncoder>)ctx.activeRenderEnc setViewport:vp];
    }
}

static BOOL can_merge_pass(CMContext *ctx, const int64_t *colorViewPtrs, const int32_t *colorHasClear,
                           int32_t colorCount, int64_t depthViewPtr, int32_t depthHasClear) {
    if (!ctx.activeRenderEnc || !ctx.passSoftEnded || !ctx.passMergeable || !ctx.passMergeEnabled) return NO;
    if (ctx->_pendingClearCount > 0) return NO;
    if (depthHasClear) return NO;
    if (colorCount != ctx.passColorCount) return NO;
    if ((uintptr_t)depthViewPtr != ctx.passDepthView) return NO;
    for (int32_t i = 0; i < colorCount; i++) {
        if (colorHasClear[i]) return NO;
        if ((uintptr_t)colorViewPtrs[i] != ctx->_passColorViews[i]) return NO;
    }
    return YES;
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
        cm_ensure_cmd_begun(ctx);
        ctx->_stats[CM_STAT_PASSES_BEGUN]++;
        colorCount = MAX(0, MIN(colorCount, CM_MAX_COLOR_ATTACHMENTS));

        // Fast path: an immediately following load-only pass on identical attachments continues the
        // still-open encoder, avoiding a full tile store/load round trip and a Metal 4 queue barrier.
        if (can_merge_pass(ctx, colorViewPtrs, colorHasClear, colorCount, depthViewPtr, depthHasClear)) {
            ctx.passSoftEnded = NO;
            ctx->_stats[CM_STAT_PASSES_MERGED]++;
            set_pass_viewport(ctx);
            if (areaW > 0 && areaH > 0) {
                cm_pass_set_scissor(ctxPtr, 1, areaX, areaY, areaW, areaH);
            } else {
                cm_pass_set_scissor(ctxPtr, 0, 0, 0, 0, 0);
            }
            return 1;
        }

        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        // Fold deferred clears of this pass's attachments into its load actions.
        int32_t effColorClear[CM_MAX_COLOR_ATTACHMENTS];
        float effColorRGBA[CM_MAX_COLOR_ATTACHMENTS][4];
        for (int32_t i = 0; i < colorCount; i++) {
            effColorClear[i] = colorHasClear[i] ? 1 : 0;
            if (effColorClear[i]) memcpy(effColorRGBA[i], &colorClearsRGBA[i * 4], sizeof(float) * 4);
            id<MTLTexture> view = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
            int32_t pc = view ? find_pending_clear(ctx, view, NO) : -1;
            if (pc >= 0) {
                if (!effColorClear[i]) {
                    effColorClear[i] = 1;
                    memcpy(effColorRGBA[i], ctx->_pendingClearColor[pc], sizeof(float) * 4);
                }
                remove_pending_clear(ctx, pc);
                ctx->_stats[CM_STAT_CLEARS_FOLDED]++;
            }
        }
        BOOL effDepthClear = depthHasClear != 0;
        double effDepthValue = depthClear;
        if (depthViewPtr) {
            id<MTLTexture> dview = (__bridge id<MTLTexture>)(void *)depthViewPtr;
            int32_t pc = find_pending_clear(ctx, dview, YES);
            if (pc >= 0) {
                if (!effDepthClear) {
                    effDepthClear = YES;
                    effDepthValue = ctx->_pendingClearDepth[pc];
                }
                remove_pending_clear(ctx, pc);
                ctx->_stats[CM_STAT_CLEARS_FOLDED]++;
            }
        }
        // Clears of textures this pass does not target are emitted now, before the pass encoder,
        // preserving their order relative to this pass (nothing else was encoded in between).
        if (ctx->_pendingClearCount > 0) flush_pending_clears(ctx);

        cm_reset_pass_cache(ctx);
        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;

        int32_t texW = 0;
        int32_t texH = 0;
        ctx.currentColorCount = colorCount;
        ctx.currentHasDepth = depthViewPtr != 0;
        ctx.currentDepthFormat = MTLPixelFormatInvalid;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                for (int32_t i = 0; i < colorCount; i++) {
                    id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
                    ctx->_currentColorFormats[i] = tex.pixelFormat;
                    if (texW <= 0) {
                        texW = (int32_t)tex.width;
                        texH = (int32_t)tex.height;
                    }
                    rpd.colorAttachments[(NSUInteger)i].texture = tex;
                    rpd.colorAttachments[(NSUInteger)i].loadAction = effColorClear[i] ? MTLLoadActionClear : MTLLoadActionLoad;
                    rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
                    if (effColorClear[i]) {
                        rpd.colorAttachments[(NSUInteger)i].clearColor = MTLClearColorMake(
                            effColorRGBA[i][0], effColorRGBA[i][1], effColorRGBA[i][2], effColorRGBA[i][3]);
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
                                                        dtex, effDepthClear, effDepthValue);
                }
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return 0;
                if (ctx.debugLabels && labelUtf8) enc.label = [NSString stringWithUTF8String:labelUtf8];
                [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4VertexArgTable
                             atStages:MTLRenderStageVertex | MTLRenderStageFragment];
                [enc setFrontFacingWinding:MTLWindingClockwise];
                ctx.activeRenderEnc = enc;
                if (ctx.shadeGlobalsEnabled) cm_shade_bind_render_encoder(ctx, colorViewPtrs, colorCount);
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            for (int32_t i = 0; i < colorCount; i++) {
                id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)colorViewPtrs[i];
                ctx->_currentColorFormats[i] = tex.pixelFormat;
                if (texW <= 0) {
                    texW = (int32_t)tex.width;
                    texH = (int32_t)tex.height;
                }
                rpd.colorAttachments[(NSUInteger)i].texture = tex;
                rpd.colorAttachments[(NSUInteger)i].loadAction = effColorClear[i] ? MTLLoadActionClear : MTLLoadActionLoad;
                rpd.colorAttachments[(NSUInteger)i].storeAction = MTLStoreActionStore;
                if (effColorClear[i]) {
                    rpd.colorAttachments[(NSUInteger)i].clearColor = MTLClearColorMake(
                        effColorRGBA[i][0], effColorRGBA[i][1], effColorRGBA[i][2], effColorRGBA[i][3]);
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
                                                    dtex, effDepthClear, effDepthValue);
            }
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return 0;
            if (ctx.debugLabels && labelUtf8) enc.label = [NSString stringWithUTF8String:labelUtf8];
            [enc setFrontFacingWinding:MTLWindingClockwise];
            ctx.activeRenderEnc = enc;
            if (ctx.shadeGlobalsEnabled) cm_shade_bind_render_encoder(ctx, colorViewPtrs, colorCount);
        }

        // Remember the attachments so an immediately following compatible pass can merge.
        ctx.passSoftEnded = NO;
        ctx.passMergeable = YES;
        ctx.passColorCount = colorCount;
        ctx.passDepthView = (uintptr_t)depthViewPtr;
        for (int32_t i = 0; i < colorCount; i++) ctx->_passColorViews[i] = (uintptr_t)colorViewPtrs[i];

        ctx.currentPassWidth = MAX(1, texW > 0 ? texW : areaW);
        ctx.currentPassHeight = MAX(1, texH > 0 ? texH : areaH);
        set_pass_viewport(ctx);
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
    ctx.passSoftEnded = NO;
    ctx.passMergeable = NO;
    if (!ctx.activeRenderEnc) return;
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
}

void cm_pass_finish(int64_t ctxPtr) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (ctx.passMergeEnabled && ctx.passMergeable) {
        ctx.passSoftEnded = YES;
    } else {
        cm_pass_end(ctxPtr);
    }
}

void cm_pass_set_pipeline(int64_t ctxPtr, int64_t pipePtr) {
    if (!ctxPtr || !pipePtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (ctx.boundPipeline == (uintptr_t)pipePtr) return;

    CMPipelineBox *box = (__bridge CMPipelineBox *)(void *)pipePtr;
    ctx.boundPipeline = (uintptr_t)pipePtr;
    if (ctx.metal4Active) {
        {
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
        [(id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc setScissorRect:sr];
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
        {
            MTLGPUAddress addr = buf.gpuAddress + (MTLGPUAddress)offset;
            if (ctx->_boundUboAddrV[slot] != addr) {
                ctx->_boundUboAddrV[slot] = addr;
                [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setAddress:addr atIndex:(NSUInteger)slot];
            }
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
        {
            if (texSlot >= 0 && texSlot < CM_MAX_TEXTURES && tex) {
                if (ctx->_boundTextures[texSlot] != (uintptr_t)texViewPtr) {
                    ctx->_boundTextures[texSlot] = (uintptr_t)texViewPtr;
                    [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setTexture:tex.gpuResourceID atIndex:(NSUInteger)texSlot];
                }
            }
            if (sampSlot >= 0 && sampSlot < CM_MAX_SAMPLERS && samp) {
                if (ctx->_boundSamplers[sampSlot] != (uintptr_t)sampPtr) {
                    ctx->_boundSamplers[sampSlot] = (uintptr_t)sampPtr;
                    [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setSamplerState:samp.gpuResourceID atIndex:(NSUInteger)sampSlot];
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
        {
            if (size <= (int32_t)sizeof(ctx->_lastPush) && size == ctx->_lastPushSize && slot == CM_PUSH_CONSTANT_SLOT
                && memcmp(ctx->_lastPush, data, (size_t)size) == 0) {
                return; // identical to the bytes already bound at this slot
            }
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
            if (slot == CM_PUSH_CONSTANT_SLOT && size <= (int32_t)sizeof(ctx->_lastPush)) {
                memcpy(ctx->_lastPush, data, (size_t)size);
                ctx->_lastPushSize = size;
                ctx->_lastPushAddr = addr;
            } else {
                ctx->_lastPushSize = -1;
            }
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
        {
            MTLGPUAddress addr = buf.gpuAddress + (MTLGPUAddress)offset;
            if (ctx->_boundVtxAddr[slot] != addr) {
                ctx->_boundVtxAddr[slot] = addr;
                [(id<MTL4ArgumentTable>)ctx.m4VertexArgTable setAddress:addr atIndex:metalSlot];
            }
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
        ctx->_stats[CM_STAT_DRAWS]++;
        id<MTLBuffer> fbuf = ensure_fan_index_buffer(ctx, idxCount);
        if (!fbuf) return;
        if (ctx.metal4Active) {
            {
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
    ctx->_stats[CM_STAT_DRAWS]++;
    if (ctx.metal4Active) {
        {
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
    ctx->_stats[CM_STAT_DRAWS]++;

    if (ctx.metal4Active) {
        {
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
    ctx->_stats[CM_STAT_DRAWS] += count;
    if (ctx.metal4Active) {
        {
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
    ctx->_stats[CM_STAT_DRAWS] += count;
    if (ctx.metal4Active) {
        {
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

void cm_pass_multi_draw_packed(int64_t ctxPtr, int32_t topology, const uint32_t *cmds, int32_t count,
                               int32_t instanceCount, int32_t firstInstance) {
    if (!ctxPtr || !cmds || count <= 0 || instanceCount <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc) return;
    if (topology == CM_TOPO_TRIANGLE_FAN) {
        for (int32_t i = 0; i < count; i++) {
            cm_pass_draw(ctxPtr, topology, (int32_t)cmds[i * 2 + 1], instanceCount, (int32_t)cmds[i * 2], firstInstance);
        }
        return;
    }
    MTLPrimitiveType pt = cm_primitive_type(topology);
    ctx->_stats[CM_STAT_DRAWS] += count;
    if (ctx.metal4Active) {
        {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                uint32_t vc = cmds[i * 2 + 1];
                if (vc == 0) continue;
                [enc drawPrimitives:pt vertexStart:(NSUInteger)cmds[i * 2] vertexCount:(NSUInteger)vc
                      instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)firstInstance];
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        for (int32_t i = 0; i < count; i++) {
            uint32_t vc = cmds[i * 2 + 1];
            if (vc == 0) continue;
            [enc drawPrimitives:pt vertexStart:(NSUInteger)cmds[i * 2] vertexCount:(NSUInteger)vc
                  instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)firstInstance];
        }
    }
}

void cm_pass_multi_draw_indexed_packed(int64_t ctxPtr, int32_t topology, const uint32_t *cmds, int32_t count,
                                       int64_t indexBaseOffset, int32_t instanceCount, int32_t firstInstance) {
    if (!ctxPtr || !cmds || count <= 0 || instanceCount <= 0) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    if (!ctx.activeRenderEnc || !ctx.boundIndexBuffer) return;
    id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)(void *)ctx.boundIndexBuffer;
    MTLGPUAddress ibase = ibuf.gpuAddress;
    NSUInteger ilen = ibuf.length;
    NSUInteger stride = (ctx.boundIndexType == MTLIndexTypeUInt32) ? 4 : 2;
    MTLIndexType itype = ctx.boundIndexType;
    MTLPrimitiveType pt = cm_primitive_type(topology);
    ctx->_stats[CM_STAT_DRAWS] += count;
    if (ctx.metal4Active) {
        {
            id<MTL4RenderCommandEncoder> enc = (id<MTL4RenderCommandEncoder>)ctx.activeRenderEnc;
            for (int32_t i = 0; i < count; i++) {
                const uint32_t *c = &cmds[i * 3];
                if (c[1] == 0) continue;
                NSUInteger off = (NSUInteger)indexBaseOffset + (NSUInteger)c[0] * stride;
                if (off >= ilen) continue;
                [enc drawIndexedPrimitives:pt indexCount:(NSUInteger)c[1] indexType:itype
                               indexBuffer:ibase + off indexBufferLength:ilen - off
                             instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)(int32_t)c[2]
                              baseInstance:(NSUInteger)firstInstance];
            }
        }
    } else {
        id<MTLRenderCommandEncoder> enc = (id<MTLRenderCommandEncoder>)ctx.activeRenderEnc;
        for (int32_t i = 0; i < count; i++) {
            const uint32_t *c = &cmds[i * 3];
            if (c[1] == 0) continue;
            NSUInteger off = (NSUInteger)indexBaseOffset + (NSUInteger)c[0] * stride;
            if (off >= ilen) continue;
            [enc drawIndexedPrimitives:pt indexCount:(NSUInteger)c[1] indexType:itype
                           indexBuffer:ibuf indexBufferOffset:off
                         instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)(int32_t)c[2]
                          baseInstance:(NSUInteger)firstInstance];
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
    ctx->_stats[CM_STAT_DRAWS] += count;

    if (indexed) {
        if (!ctx.boundIndexBuffer) return;
        id<MTLBuffer> ibuf = (__bridge id<MTLBuffer>)(void *)ctx.boundIndexBuffer;
        if (ctx.metal4Active) {
            {
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
            {
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
