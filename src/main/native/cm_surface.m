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

@interface CMSurface : NSObject
@property (nonatomic, weak) CMContext *ctx;
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<CAMetalDrawable> currentDrawable;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentPsoSdr;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentPsoHdr;
@property (nonatomic, strong) id<MTLSamplerState> linearSampler;
@property (nonatomic) BOOL hdrEnabled;
@property (nonatomic) int32_t width;
@property (nonatomic) int32_t height;
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

int64_t cm_surface_create(int64_t ctxPtr, int64_t caMetalLayerPtr, int32_t hdrEnabled) {
    if (!ctxPtr || !caMetalLayerPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CAMetalLayer *layer = (__bridge CAMetalLayer *)(void *)caMetalLayerPtr;
        layer.device = ctx.device;
        layer.framebufferOnly = YES;
        layer.maximumDrawableCount = 3;

        CMSurface *surf = [CMSurface new];
        surf.ctx = ctx;
        surf.layer = layer;
        surf.hdrEnabled = hdrEnabled != 0;

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
        CAMetalLayer *layer = surf.layer;
        layer.drawableSize = CGSizeMake(surf.width, surf.height);
        layer.displaySyncEnabled = vsync ? YES : NO;

        if (surf.hdrEnabled) {
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
        surf.currentDrawable = [surf.layer nextDrawable];
        return surf.currentDrawable ? 1 : 0;
    }
}

void cm_surface_blit_and_present(int64_t ctxPtr, int64_t surfPtr, int64_t srcTexViewPtr, int32_t maxInFlight) {
    if (!ctxPtr || !surfPtr || !srcTexViewPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMSurface *surf = (__bridge CMSurface *)(void *)surfPtr;
        if (!surf.currentDrawable) {
            surf.currentDrawable = [surf.layer nextDrawable];
            if (!surf.currentDrawable) return;
        }
        id<CAMetalDrawable> drawable = surf.currentDrawable;
        surf.currentDrawable = nil;
        id<MTLTexture> dstTex = drawable.texture;
        id<MTLTexture> srcTex = (__bridge id<MTLTexture>)(void *)srcTexViewPtr;

        cm_cmd_begin(ctxPtr);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

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
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = dstTex;
            rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (enc && pso) {
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
