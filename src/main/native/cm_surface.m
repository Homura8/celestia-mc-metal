#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static const char *const kPresentShaderMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct PresentOut {
    float4 pos [[position]];
    float2 uv;
};

vertex PresentOut cm_present_vs(uint vid [[vertex_id]]) {
    PresentOut out;
    float2 pos = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? 3.0f : -1.0f);
    out.pos = float4(pos, 0.0f, 1.0f);
    // Flip Y on present so Vulkan-layout (top-down flipped) render targets appear upright on CAMetalLayer.
    out.uv = float2((pos.x + 1.0f) * 0.5f, (pos.y + 1.0f) * 0.5f);
    return out;
}

fragment float4 cm_present_fs(PresentOut in [[stage_in]],
                              texture2d<float> srcTex [[texture(0)]],
                              sampler srcSamp [[sampler(0)]]) {
    return srcTex.sample(srcSamp, in.uv);
}
)MSL";

#define CM_PRESENT_SLOTS 4
// At most this many presented drawables may wait to be shown; a newer finished frame replaces a waiting one.
#define CM_MAX_UNSHOWN_PRESENTS 2

@interface CMSurface : NSObject {
@public
    // Non-blocking present slots (render thread renders into a free slot; the present queue copies it to a drawable)
    __strong id<MTLTexture> _slotTex[CM_PRESENT_SLOTS];
    _Atomic int32_t _slotBusy[CM_PRESENT_SLOTS];
    _Atomic int32_t _onScreenPending;   // presented drawables whose presented handler has not run yet
    _Atomic int32_t _shutdown;
    int32_t _waitingSlot;               // present queue only: finished frame waiting for a credit, or -1
    double _lastPresent;                // present queue only: CACurrentMediaTime() of the last present
}
@property (nonatomic, weak) CMContext *ctx;
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<CAMetalDrawable> currentDrawable;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentPsoSdr;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentPsoHdr;
@property (nonatomic, strong) id<MTLSamplerState> linearSampler;
@property (nonatomic) BOOL hdrEnabled;
@property (nonatomic) int32_t width;
@property (nonatomic) int32_t height;
@property (nonatomic) BOOL vsync;
@property (nonatomic) BOOL nonBlocking;
@property (nonatomic, strong) dispatch_queue_t presentQueue;
@property (nonatomic, strong) dispatch_semaphore_t slotsFree;
@property (nonatomic, strong) id<MTLCommandQueue> presentCmdQueue;
@property (nonatomic, strong) MTLSharedEventListener *listener;
@end

@implementation CMSurface
@end

static id<MTLRenderPipelineState> make_present_pso(CMContext *ctx, id<MTLLibrary> lib, MTLPixelFormat fmt) {
    id<MTLFunction> vs = [lib newFunctionWithName:@"cm_present_vs"];
    id<MTLFunction> fs = [lib newFunctionWithName:@"cm_present_fs"];
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = vs;
    rpd.fragmentFunction = fs;
    rpd.colorAttachments[0].pixelFormat = fmt;
    NSError *err = nil;
    return [ctx.device newRenderPipelineStateWithDescriptor:rpd error:&err];
}

static void cm_surface_apply_layer_config(CMSurface *surf, int32_t width, int32_t height, int32_t vsync, int32_t hdrEnabled);
static void cm_surface_submit_nonblocking(CMContext *ctx, CMSurface *surf, id<MTLTexture> srcTex, int32_t maxInFlight);

// ---- Non-blocking presentation (VSync off) ----
//
// Render thread: renders the Y-flip present pass into a free slot texture inside the frame's own command buffer and
// submits it. GPU completion of that submit (submitEvent >= serial) wakes the present queue through an
// MTLSharedEventListener. Present queue: takes a drawable, blits the slot into it and presents it. At most
// CM_MAX_UNSHOWN_PRESENTS presents wait to be shown; until one is, a newer finished frame replaces the waiting one, so
// the screen always gets the newest frame without tearing and the render thread never blocks in nextDrawable.
// Approach adapted from Pure Metal's present credits / present queue (Apache-2.0, see CREDITS.md).

static void release_slot(CMSurface *surf, int32_t slot) {
    atomic_store(&surf->_slotBusy[slot], 0);
    dispatch_semaphore_signal(surf.slotsFree);
}

static void present_slot_now(CMSurface *surf, int32_t slot);

// Present queue: a presented handler reported a frame on screen (or dropped by the compositor).
static void on_frame_shown(CMSurface *surf) {
    if (atomic_load(&surf->_shutdown)) {
        if (surf->_waitingSlot >= 0) { release_slot(surf, surf->_waitingSlot); surf->_waitingSlot = -1; }
        return;
    }
    if (surf->_waitingSlot >= 0 && atomic_load(&surf->_onScreenPending) < CM_MAX_UNSHOWN_PRESENTS) {
        int32_t slot = surf->_waitingSlot;
        surf->_waitingSlot = -1;
        present_slot_now(surf, slot);
    }
}

// Present queue: the GPU finished the frame rendered into `slot`. Frames complete in submit order.
static void on_frame_ready(CMSurface *surf, int32_t slot) {
    CMContext *ctx = surf.ctx;
    if (surf->_waitingSlot >= 0) {
        // The waiting frame is older than this one: never show it after a newer frame.
        release_slot(surf, surf->_waitingSlot);
        surf->_waitingSlot = -1;
        if (ctx) atomic_fetch_add(&ctx->_framesDropped, 1);
    }
    if (atomic_load(&surf->_shutdown)) { release_slot(surf, slot); return; }
    BOOL credit = atomic_load(&surf->_onScreenPending) < CM_MAX_UNSHOWN_PRESENTS;
    // Presented handlers can stop arriving (window hidden / occluded); never stall the screen for longer than 100 ms.
    if (!credit && CACurrentMediaTime() - surf->_lastPresent < 0.1) {
        surf->_waitingSlot = slot;
        return;
    }
    present_slot_now(surf, slot);
}

static void present_slot_now(CMSurface *surf, int32_t slot) {
    CMContext *ctx = surf.ctx;
    CAMetalLayer *layer = surf.layer;
    id<MTLTexture> src = surf->_slotTex[slot];
    if (!layer || !src || atomic_load(&surf->_shutdown)) { release_slot(surf, slot); return; }
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        id<MTLTexture> dst = drawable.texture;
        if (!drawable || !dst || dst.width != src.width || dst.height != src.height || dst.pixelFormat != src.pixelFormat) {
            // Resized or reconfigured since this frame was rendered: drop it, the next frame matches the layer.
            release_slot(surf, slot);
            if (ctx) atomic_fetch_add(&ctx->_framesDropped, 1);
            return;
        }
        id<MTLCommandBuffer> cb = [surf.presentCmdQueue commandBufferWithUnretainedReferences];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:src toTexture:dst];
        [blit endEncoding];
        atomic_fetch_add(&surf->_onScreenPending, 1);
        CMSurface *strongSurf = surf;
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            atomic_fetch_sub(&strongSurf->_onScreenPending, 1);
            CMContext *c = strongSurf.ctx;
            if (c && shown.presentedTime > 0) atomic_fetch_add(&c->_presentsShown, 1);
            dispatch_async(strongSurf.presentQueue, ^{ on_frame_shown(strongSurf); });
        }];
        [cb presentDrawable:drawable];
        // Keep the slot texture alive (unretained references) and free the slot once the copy has executed.
        id<MTLTexture> keep = src;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)keep;
            release_slot(strongSurf, slot);
        }];
        [cb commit];
        surf->_lastPresent = CACurrentMediaTime();
    }
}

static void encode_present_pass_into(CMContext *ctx, CMSurface *surf, id<MTLTexture> srcTex, id<MTLTexture> dstTex) {
    id<MTLRenderPipelineState> pso = (dstTex.pixelFormat == MTLPixelFormatRGBA16Float) ? surf.presentPsoHdr : surf.presentPsoSdr;
    if (!pso) return;
    MTLViewport vp = { 0.0, 0.0, (double)dstTex.width, (double)dstTex.height, 0.0, 1.0 };
    MTLScissorRect sr = { 0, 0, dstTex.width, dstTex.height };
    ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
            rpd.colorAttachments[0].texture = dstTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return;
            [enc setViewport:vp];
            [enc setScissorRect:sr];
            [enc setCullMode:MTLCullModeNone];
            [enc setRenderPipelineState:pso];
            [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setTexture:srcTex.gpuResourceID atIndex:0];
            [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setSamplerState:surf.linearSampler.gpuResourceID atIndex:0];
            [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable atStages:MTLRenderStageFragment];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc barrierAfterStages:MTLStageFragment
                  beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                  visibilityOptions:MTL4VisibilityOptionDevice];
            [enc endEncoding];
        }
    } else {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = dstTex;
        rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
        if (!enc) return;
        [enc setViewport:vp];
        [enc setScissorRect:sr];
        [enc setCullMode:MTLCullModeNone];
        [enc setRenderPipelineState:pso];
        [enc setFragmentTexture:srcTex atIndex:0];
        [enc setFragmentSamplerState:surf.linearSampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }
}

static void cm_surface_submit_nonblocking(CMContext *ctx, CMSurface *surf, id<MTLTexture> srcTex, int32_t maxInFlight) {
    int64_t ctxPtr = (int64_t)(__bridge void *)ctx;
    // A free slot exists unless the present queue is far behind; never wait long (a hidden window shows nothing).
    if (dispatch_semaphore_wait(surf.slotsFree, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0) {
        atomic_fetch_add(&ctx->_framesDropped, 1);
        cm_cmd_submit(ctxPtr, maxInFlight);
        return;
    }
    int32_t slot = -1;
    for (int32_t i = 0; i < CM_PRESENT_SLOTS; i++) {
        int32_t expected = 0;
        if (atomic_compare_exchange_strong(&surf->_slotBusy[i], &expected, 1)) { slot = i; break; }
    }
    if (slot < 0) {
        dispatch_semaphore_signal(surf.slotsFree);
        atomic_fetch_add(&ctx->_framesDropped, 1);
        cm_cmd_submit(ctxPtr, maxInFlight);
        return;
    }
    MTLPixelFormat fmt = surf.hdrEnabled ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    id<MTLTexture> tex = surf->_slotTex[slot];
    if (!tex || (int32_t)tex.width != surf.width || (int32_t)tex.height != surf.height || tex.pixelFormat != fmt) {
        // Free slot: its last present copy completed, so the old texture can be released (tracked until retired).
        if (tex) {
            cm_untrack_allocation(ctx, tex);
            cm_retire_object(ctx, tex, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                       width:(NSUInteger)surf.width
                                                                                      height:(NSUInteger)surf.height
                                                                                   mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        tex = [ctx.device newTextureWithDescriptor:td];
        if (ctx.debugLabels) tex.label = [NSString stringWithFormat:@"CelestiaMetal.PresentSlot%d", slot];
        if (tex) cm_track_allocation(ctx, tex);
        surf->_slotTex[slot] = tex;
    }
    if (!tex) {
        release_slot(surf, slot);
        cm_cmd_submit(ctxPtr, maxInFlight);
        return;
    }
    cm_cmd_begin(ctxPtr);
    cm_flush_encoders(ctx);
    encode_present_pass_into(ctx, surf, srcTex, tex);
    uint64_t serial = cm_cmd_submit(ctxPtr, maxInFlight);
    CMSurface *strongSurf = surf;
    int32_t s = slot;
    [ctx.submitEvent notifyListener:surf.listener atValue:serial block:^(id<MTLSharedEvent> ev, uint64_t value) {
        on_frame_ready(strongSurf, s);
    }];
}

void cm_surface_set_nonblocking(int64_t surfPtr, int32_t enabled) {
    if (!surfPtr) return;
    CMSurface *surf = (__bridge CMSurface *)(void *)surfPtr;
    BOOL on = enabled != 0;
    if (surf.nonBlocking == on) return;
    if (surf.presentQueue) {
        // Hand any waiting frame back before switching paths; in-flight presents finish on their own.
        dispatch_sync(surf.presentQueue, ^{
            if (surf->_waitingSlot >= 0) { release_slot(surf, surf->_waitingSlot); surf->_waitingSlot = -1; }
        });
    }
    surf.nonBlocking = on;
}

int64_t cm_surface_create(int64_t ctxPtr, int64_t caMetalLayerPtr, int32_t hdrEnabled) {
    if (!ctxPtr || !caMetalLayerPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CAMetalLayer *layer = (__bridge CAMetalLayer *)(void *)caMetalLayerPtr;
        layer.device = ctx.device;
        // The non-blocking present queue copies a finished present slot into the drawable with a blit.
        layer.framebufferOnly = NO;
        layer.maximumDrawableCount = 3;

        CMSurface *surf = [CMSurface new];
        surf.ctx = ctx;
        surf.layer = layer;
        surf.hdrEnabled = hdrEnabled != 0;
        surf.nonBlocking = YES;
        surf->_waitingSlot = -1;
        atomic_init(&surf->_onScreenPending, 0);
        atomic_init(&surf->_shutdown, 0);
        for (int i = 0; i < CM_PRESENT_SLOTS; i++) atomic_init(&surf->_slotBusy[i], 0);
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        surf.presentQueue = dispatch_queue_create("dev.celestia.metal.present", attr);
        // Created at 0 and signalled up to the pool size: libdispatch traps if a semaphore is disposed below its
        // initial value, which happens when the surface is torn down while frames still hold slots.
        surf.slotsFree = dispatch_semaphore_create(0);
        for (int i = 0; i < CM_PRESENT_SLOTS; i++) dispatch_semaphore_signal(surf.slotsFree);
        surf.presentCmdQueue = [ctx.device newCommandQueue];
        surf.presentCmdQueue.label = @"CelestiaMetal.PresentQueue";
        surf.listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:surf.presentQueue];

        NSError *err = nil;
        NSString *src = [NSString stringWithUTF8String:kPresentShaderMSL];
        id<MTLLibrary> lib = [ctx.device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            cm_record_error(ctx, err ? err.localizedDescription : @"Failed to compile present shader");
            return 0;
        }
        surf.presentPsoSdr = make_present_pso(ctx, lib, MTLPixelFormatBGRA8Unorm);
        surf.presentPsoHdr = make_present_pso(ctx, lib, MTLPixelFormatRGBA16Float);

        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.supportArgumentBuffers = YES;
        surf.linearSampler = [ctx.device newSamplerStateWithDescriptor:sd];

        cm_surface_configure((int64_t)(__bridge void *)surf,
                             (int32_t)MAX(1.0, layer.drawableSize.width),
                             (int32_t)MAX(1.0, layer.drawableSize.height),
                             1, hdrEnabled);
        return (int64_t)(__bridge_retained void *)surf;
    }
}

void cm_surface_destroy(int64_t ctxPtr, int64_t surfPtr) {
    if (!surfPtr) return;
    @autoreleasepool {
        CMSurface *surf = (__bridge_transfer CMSurface *)(void *)surfPtr;
        atomic_store(&surf->_shutdown, 1);
        // Let queued present work observe the shutdown flag (it releases slots without presenting).
        if (surf.presentQueue) dispatch_sync(surf.presentQueue, ^{
            if (surf->_waitingSlot >= 0) { release_slot(surf, surf->_waitingSlot); surf->_waitingSlot = -1; }
        });
        surf.currentDrawable = nil;
        surf.layer = nil;
    }
}

void cm_surface_configure(int64_t surfPtr, int32_t width, int32_t height, int32_t vsync, int32_t hdrEnabled) {
    if (!surfPtr) return;
    @autoreleasepool {
        CMSurface *surf = (__bridge CMSurface *)(void *)surfPtr;
        surf.width = MAX(1, width);
        surf.height = MAX(1, height);
        surf.hdrEnabled = hdrEnabled != 0;
        surf.vsync = vsync != 0;
        if (surf.presentQueue) {
            // The present queue may be inside nextDrawable; serialize layer changes behind it (rare: resize / mode change).
            int32_t w = surf.width, h = surf.height, hdr = hdrEnabled;
            dispatch_sync(surf.presentQueue, ^{
                // A waiting frame was rendered for the old configuration: hand its slot back (never just forget it,
                // or the slot pool shrinks permanently).
                if (surf->_waitingSlot >= 0) { release_slot(surf, surf->_waitingSlot); surf->_waitingSlot = -1; }
                cm_surface_apply_layer_config(surf, w, h, vsync, hdr);
            });
            return;
        }
        cm_surface_apply_layer_config(surf, surf.width, surf.height, vsync, hdrEnabled);
    }
}

static void cm_surface_apply_layer_config(CMSurface *surf, int32_t width, int32_t height, int32_t vsync, int32_t hdrEnabled) {
    {
        CAMetalLayer *layer = surf.layer;
        if (!layer) return;
        layer.drawableSize = CGSizeMake(width, height);
        layer.displaySyncEnabled = vsync ? YES : NO;

        if (hdrEnabled) {
            layer.pixelFormat = MTLPixelFormatRGBA16Float;
            if (@available(macOS 10.15, *)) {
                layer.wantsExtendedDynamicRangeContent = YES;
            }
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
            if (cs) {
                layer.colorspace = cs;
                CGColorSpaceRelease(cs);
            }
        } else {
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            if (@available(macOS 10.15, *)) {
                layer.wantsExtendedDynamicRangeContent = NO;
            }
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            if (cs) {
                layer.colorspace = cs;
                CGColorSpaceRelease(cs);
            }
        }
    }
}

int32_t cm_surface_acquire(int64_t surfPtr) {
    if (!surfPtr) return 0;
    @autoreleasepool {
        CMSurface *surf = (__bridge CMSurface *)(void *)surfPtr;
        // Non-blocking path: drawables are taken by the present queue, never by the render thread.
        if (surf.nonBlocking && !surf.vsync) return 1;
        surf.currentDrawable = [surf.layer nextDrawable];
        return surf.currentDrawable ? 1 : 0;
    }
}

void cm_surface_blit_and_present(int64_t ctxPtr, int64_t surfPtr, int64_t srcTexViewPtr, int32_t maxInFlight) {
    if (!ctxPtr || !surfPtr || !srcTexViewPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMSurface *surf = (__bridge CMSurface *)(void *)surfPtr;
        ctx->_stats[CM_STAT_FRAMES_SUBMITTED]++;
        if (surf.nonBlocking && !surf.vsync) {
            cm_surface_submit_nonblocking(ctx, surf, (__bridge id<MTLTexture>)(void *)srcTexViewPtr, maxInFlight);
            return;
        }
        if (!surf.currentDrawable) {
            surf.currentDrawable = [surf.layer nextDrawable];
            if (!surf.currentDrawable) return;
        }
        id<CAMetalDrawable> drawable = surf.currentDrawable;
        surf.currentDrawable = nil;
        id<MTLTexture> dstTex = drawable.texture;
        id<MTLTexture> srcTex = (__bridge id<MTLTexture>)(void *)srcTexViewPtr;

        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;

        id<MTLRenderPipelineState> pso = (dstTex.pixelFormat == MTLPixelFormatRGBA16Float)
            ? surf.presentPsoHdr : surf.presentPsoSdr;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.colorAttachments[0].texture = dstTex;
                rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (enc && pso) {
                    MTLViewport vp = { 0.0, 0.0, (double)dstTex.width, (double)dstTex.height, 0.0, 1.0 };
                    MTLScissorRect sr = { 0, 0, dstTex.width, dstTex.height };
                    [enc setViewport:vp];
                    [enc setScissorRect:sr];
                    [enc setCullMode:MTLCullModeNone];
                    [enc setRenderPipelineState:pso];
                    [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setTexture:srcTex.gpuResourceID atIndex:0];
                    [(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable setSamplerState:surf.linearSampler.gpuResourceID atIndex:0];
                    [enc setArgumentTable:(id<MTL4ArgumentTable>)ctx.m4FragmentArgTable atStages:MTLRenderStageFragment];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    [enc endEncoding];
                }
                id<MTL4CommandBuffer> cb = (id<MTL4CommandBuffer>)ctx.activeM4CmdBuf;
                ctx.activeM4CmdBuf = nil;
                [cb endCommandBuffer];

                cm_commit_residency_if_dirty(ctx);
                uint64_t serial = atomic_fetch_add(&ctx->_nextSubmitSerial, 1) + 1;
                id<MTL4CommandQueue> q = (id<MTL4CommandQueue>)ctx.m4Queue;
                [q waitForDrawable:drawable];
                MTL4CommitOptions *opts = [MTL4CommitOptions new];
                CMContext *weakCtx = ctx;
                [opts addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
                    if (feedback.error) cm_record_error(weakCtx, feedback.error.localizedDescription);
                    double dt = feedback.GPUEndTime - feedback.GPUStartTime;
                    if (dt > 0.0) atomic_store(&weakCtx->_lastGpuFrameNs, (uint64_t)(dt * 1e9));
                }];
                [q commit:&cb count:1 options:opts];
                [q signalDrawable:drawable];
                [q signalEvent:ctx.submitEvent value:serial];
                [drawable present];
                uint64_t signaled = ctx.submitEvent.signaledValue;
                uint64_t cur = atomic_load(&ctx->_completedSubmitSerial);
                while (cur < signaled && !atomic_compare_exchange_weak(&ctx->_completedSubmitSerial, &cur, signaled)) {}
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = dstTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (enc && pso) {
                MTLViewport vp = { 0.0, 0.0, (double)dstTex.width, (double)dstTex.height, 0.0, 1.0 };
                MTLScissorRect sr = { 0, 0, dstTex.width, dstTex.height };
                [enc setViewport:vp];
                [enc setScissorRect:sr];
                [enc setCullMode:MTLCullModeNone];
                [enc setRenderPipelineState:pso];
                [enc setFragmentTexture:srcTex atIndex:0];
                [enc setFragmentSamplerState:surf.linearSampler atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
            }
            [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf presentDrawable:drawable];
            cm_cmd_submit(ctxPtr, maxInFlight);
            return;
        }

        int32_t cap = maxInFlight > 0 ? MIN(maxInFlight, CM_INFLIGHT_SLOTS) : 2;
        uint64_t next = atomic_load(&ctx->_nextSubmitSerial);
        if (next > (uint64_t)cap) {
            cm_wait_submit(ctxPtr, next - (uint64_t)cap, 5000000000ULL);
        }
        cm_drain_retired(ctx);
    }
}
