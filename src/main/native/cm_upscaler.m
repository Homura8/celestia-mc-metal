#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@interface CMUpscalerBox : NSObject
@property (nonatomic) BOOL temporal;
@property (nonatomic) BOOL metal4;
@property (nonatomic, strong) id scaler; // MTLFXSpatialScaler / MTL4FXSpatialScaler / MTLFXTemporalScaler / MTL4FXTemporalScaler
@property (nonatomic) NSUInteger inW;
@property (nonatomic) NSUInteger inH;
@end

@implementation CMUpscalerBox
@end

int64_t cm_upscaler_create(int64_t ctxPtr, int32_t temporal, int32_t colorFmt, int32_t outputFmt,
                           int32_t inW, int32_t inH, int32_t outW, int32_t outH, int32_t hdrMode) {
    if (!ctxPtr || inW <= 0 || inH <= 0 || outW <= 0 || outH <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLPixelFormat cf = cm_pixel_format(colorFmt);
        MTLPixelFormat of = cm_pixel_format(outputFmt);
        if (cf == MTLPixelFormatInvalid || of == MTLPixelFormatInvalid) return 0;

        CMUpscalerBox *box = [CMUpscalerBox new];
        box.temporal = temporal != 0;
        box.inW = (NSUInteger)inW;
        box.inH = (NSUInteger)inH;

        if (temporal) {
            if (![MTLFXTemporalScalerDescriptor supportsDevice:ctx.device]) return 0;
            MTLFXTemporalScalerDescriptor *td = [MTLFXTemporalScalerDescriptor new];
            td.colorTextureFormat = cf;
            td.depthTextureFormat = MTLPixelFormatDepth32Float;
            td.motionTextureFormat = MTLPixelFormatRG16Float;
            td.outputTextureFormat = of;
            td.inputWidth = (NSUInteger)inW;
            td.inputHeight = (NSUInteger)inH;
            td.outputWidth = (NSUInteger)outW;
            td.outputHeight = (NSUInteger)outH;
            td.autoExposureEnabled = NO;
            td.reactiveMaskTextureEnabled = NO;
            if (ctx.metal4Active && ctx.m4Compiler && [MTLFXTemporalScalerDescriptor respondsToSelector:@selector(supportsMetal4FX:)] && [MTLFXTemporalScalerDescriptor supportsMetal4FX:ctx.device]) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4FXTemporalScaler> s4 = [td newTemporalScalerWithDevice:ctx.device compiler:(id<MTL4Compiler>)ctx.m4Compiler];
                    if (s4) {
                        box.metal4 = YES;
                        box.scaler = s4;
                    }
                }
            }
            if (!box.scaler) {
                box.scaler = [td newTemporalScalerWithDevice:ctx.device];
            }
        } else {
            if (![MTLFXSpatialScalerDescriptor supportsDevice:ctx.device]) return 0;
            MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
            sd.colorTextureFormat = cf;
            sd.outputTextureFormat = of;
            sd.inputWidth = (NSUInteger)inW;
            sd.inputHeight = (NSUInteger)inH;
            sd.outputWidth = (NSUInteger)outW;
            sd.outputHeight = (NSUInteger)outH;
            sd.colorProcessingMode = hdrMode ? MTLFXSpatialScalerColorProcessingModeHDR : MTLFXSpatialScalerColorProcessingModePerceptual;
            if (ctx.metal4Active && ctx.m4Compiler && [MTLFXSpatialScalerDescriptor respondsToSelector:@selector(supportsMetal4FX:)] && [MTLFXSpatialScalerDescriptor supportsMetal4FX:ctx.device]) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4FXSpatialScaler> s4 = [sd newSpatialScalerWithDevice:ctx.device compiler:(id<MTL4Compiler>)ctx.m4Compiler];
                    if (s4) {
                        box.metal4 = YES;
                        box.scaler = s4;
                    }
                }
            }
            if (!box.scaler) {
                box.scaler = [sd newSpatialScalerWithDevice:ctx.device];
            }
        }

        if (!box.scaler) return 0;
        return (int64_t)(__bridge_retained void *)box;
    }
}

void cm_upscaler_destroy(int64_t ctxPtr, int64_t upscalerPtr) {
    if (!upscalerPtr) return;
    @autoreleasepool {
        CMUpscalerBox *box = (__bridge_transfer CMUpscalerBox *)(void *)upscalerPtr;
        if (ctxPtr) {
            CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
            cm_retire_object(ctx, box, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
    }
}

void cm_upscaler_encode(int64_t ctxPtr, int64_t upscalerPtr, int64_t colorTexPtr,
                        int64_t depthTexPtr, int64_t motionTexPtr, int64_t outTexPtr,
                        float jitterX, float jitterY, int32_t resetHistory) {
    if (!ctxPtr || !upscalerPtr || !colorTexPtr || !outTexPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        CMUpscalerBox *box = (__bridge CMUpscalerBox *)(void *)upscalerPtr;
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);

        id<MTLTexture> col = (__bridge id<MTLTexture>)(void *)colorTexPtr;
        id<MTLTexture> out = (__bridge id<MTLTexture>)(void *)outTexPtr;

        if (box.temporal) {
            id<MTLFXTemporalScalerBase> ts = (id<MTLFXTemporalScalerBase>)box.scaler;
            ts.colorTexture = col;
            ts.depthTexture = depthTexPtr ? (__bridge id<MTLTexture>)(void *)depthTexPtr : nil;
            ts.motionTexture = motionTexPtr ? (__bridge id<MTLTexture>)(void *)motionTexPtr : nil;
            ts.outputTexture = out;
            ts.inputContentWidth = box.inW;
            ts.inputContentHeight = box.inH;
            ts.jitterOffsetX = jitterX;
            ts.jitterOffsetY = jitterY;
            ts.depthReversed = YES;
            ts.reset = resetHistory != 0;
            if (box.metal4 && ctx.metal4Active && ctx.activeM4CmdBuf) {
                if (@available(macOS 26.0, *)) {
                    [(id<MTL4FXTemporalScaler>)ts encodeToCommandBuffer:(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf];
                }
            } else if (!ctx.metal4Active && ctx.activeM3CmdBuf) {
                [(id<MTLFXTemporalScaler>)ts encodeToCommandBuffer:(id<MTLCommandBuffer>)ctx.activeM3CmdBuf];
            }
        } else {
            id<MTLFXSpatialScalerBase> ss = (id<MTLFXSpatialScalerBase>)box.scaler;
            ss.colorTexture = col;
            ss.outputTexture = out;
            ss.inputContentWidth = box.inW;
            ss.inputContentHeight = box.inH;
            if (box.metal4 && ctx.metal4Active && ctx.activeM4CmdBuf) {
                if (@available(macOS 26.0, *)) {
                    [(id<MTL4FXSpatialScaler>)ss encodeToCommandBuffer:(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf];
                }
            } else if (!ctx.metal4Active && ctx.activeM3CmdBuf) {
                [(id<MTLFXSpatialScaler>)ss encodeToCommandBuffer:(id<MTLCommandBuffer>)ctx.activeM3CmdBuf];
            }
        }
    }
}


// ---- World render scale: whole-texture upscale (bilinear pass or MetalFX Spatial) ----

static const char *const kUpscaleBlitMSL = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct BlitOut { float4 pos [[position]]; float2 uv; };
vertex BlitOut cm_upscale_vs(uint vid [[vertex_id]]) {
    BlitOut o;
    float2 p = float2((vid == 1) ? 3.0f : -1.0f, (vid == 2) ? 3.0f : -1.0f);
    o.pos = float4(p, 0.0f, 1.0f);
    // Same orientation in source and destination (no Y flip, unlike the present pass).
    o.uv = float2((p.x + 1.0f) * 0.5f, (1.0f - p.y) * 0.5f);
    return o;
}
fragment float4 cm_upscale_fs(BlitOut in [[stage_in]], texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
    return src.sample(s, in.uv);
}
)MSL";

@interface CMUpscalePath : NSObject
@property (nonatomic, strong) id<MTLLibrary> lib;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *blitPsos;
@property (nonatomic, strong) id<MTLSamplerState> linear;
@property (nonatomic, strong) id spatial;            // MTLFXSpatialScaler or MTL4FXSpatialScaler
@property (nonatomic) BOOL spatialM4;
@property (nonatomic) BOOL spatialUnavailable;
@property (nonatomic) NSUInteger inW, inH, outW, outH;
@property (nonatomic) MTLPixelFormat inFmt, outFmt;
@property (nonatomic, strong) id<MTLTexture> spatialOut;
@property (nonatomic, strong) id temporal;           // MTLFXTemporalScaler or MTL4FXTemporalScaler
@property (nonatomic) BOOL temporalM4;
@property (nonatomic) BOOL temporalUnavailable;
@property (nonatomic) NSUInteger tInW, tInH, tOutW, tOutH;
@property (nonatomic) MTLPixelFormat tInFmt, tOutFmt;
@property (nonatomic, strong) id<MTLTexture> temporalOut;
@end
@implementation CMUpscalePath
@end

static CMUpscalePath *upscale_path(CMContext *ctx) {
    CMUpscalePath *p = (CMUpscalePath *)ctx.upscalePath;
    if (p) return p;
    p = [CMUpscalePath new];
    p.blitPsos = [NSMutableDictionary dictionary];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.supportArgumentBuffers = YES;
    p.linear = [ctx.device newSamplerStateWithDescriptor:sd];
    ctx.upscalePath = p;
    return p;
}

static id<MTLRenderPipelineState> blit_pso(CMContext *ctx, CMUpscalePath *p, MTLPixelFormat fmt) {
    id<MTLRenderPipelineState> pso = p.blitPsos[@(fmt)];
    if (pso) return pso;
    NSError *err = nil;
    if (!p.lib) {
        p.lib = [ctx.device newLibraryWithSource:[NSString stringWithUTF8String:kUpscaleBlitMSL] options:nil error:&err];
        if (!p.lib) { cm_record_error(ctx, err ? err.localizedDescription : @"upscale blit shader failed"); return nil; }
    }
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    rpd.vertexFunction = [p.lib newFunctionWithName:@"cm_upscale_vs"];
    rpd.fragmentFunction = [p.lib newFunctionWithName:@"cm_upscale_fs"];
    rpd.colorAttachments[0].pixelFormat = fmt;
    pso = [ctx.device newRenderPipelineStateWithDescriptor:rpd error:&err];
    if (!pso) { cm_record_error(ctx, err ? err.localizedDescription : @"upscale blit pipeline failed"); return nil; }
    p.blitPsos[@(fmt)] = pso;
    return pso;
}

static BOOL encode_bilinear(CMContext *ctx, CMUpscalePath *p, id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLRenderPipelineState> pso = blit_pso(ctx, p, dst.pixelFormat);
    if (!pso) return NO;
    MTLViewport vp = { 0.0, 0.0, (double)dst.width, (double)dst.height, 0.0, 1.0 };
    MTLScissorRect sr = { 0, 0, dst.width, dst.height };
    ctx->_stats[CM_STAT_RENDER_ENCODERS]++;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
            rpd.colorAttachments[0].texture = dst;
            rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return NO;
            [enc setViewport:vp];
            [enc setScissorRect:sr];
            [enc setCullMode:MTLCullModeNone];
            [enc setRenderPipelineState:pso];
            id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4FragmentArgTable;
            [at setTexture:src.gpuResourceID atIndex:0];
            [at setSamplerState:p.linear.gpuResourceID atIndex:0];
            [enc setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc barrierAfterStages:MTLStageFragment
                  beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                  visibilityOptions:MTL4VisibilityOptionDevice];
            [enc endEncoding];
        }
    } else {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = dst;
        rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
        if (!enc) return NO;
        [enc setViewport:vp];
        [enc setScissorRect:sr];
        [enc setCullMode:MTLCullModeNone];
        [enc setRenderPipelineState:pso];
        [enc setFragmentTexture:src atIndex:0];
        [enc setFragmentSamplerState:p.linear atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }
    return YES;
}

static BOOL ensure_spatial(CMContext *ctx, CMUpscalePath *p, id<MTLTexture> src, id<MTLTexture> dst) {
    if (p.spatialUnavailable) return NO;
    if (p.spatial && p.inW == src.width && p.inH == src.height && p.outW == dst.width && p.outH == dst.height
        && p.inFmt == src.pixelFormat && p.outFmt == dst.pixelFormat) {
        return YES;
    }
    if (![MTLFXSpatialScalerDescriptor supportsDevice:ctx.device]) { p.spatialUnavailable = YES; return NO; }
    MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
    sd.colorTextureFormat = src.pixelFormat;
    sd.outputTextureFormat = dst.pixelFormat;
    sd.inputWidth = src.width;
    sd.inputHeight = src.height;
    sd.outputWidth = dst.width;
    sd.outputHeight = dst.height;
    sd.colorProcessingMode = (dst.pixelFormat == MTLPixelFormatRGBA16Float)
        ? MTLFXSpatialScalerColorProcessingModeHDR : MTLFXSpatialScalerColorProcessingModePerceptual;
    id scaler = nil;
    BOOL m4 = NO;
    if (ctx.metal4Active && ctx.m4Compiler && [MTLFXSpatialScalerDescriptor respondsToSelector:@selector(supportsMetal4FX:)]
        && [MTLFXSpatialScalerDescriptor supportsMetal4FX:ctx.device]) {
        if (@available(macOS 26.0, *)) {
            scaler = [sd newSpatialScalerWithDevice:ctx.device compiler:(id<MTL4Compiler>)ctx.m4Compiler];
            m4 = scaler != nil;
        }
    }
    if (!scaler && !ctx.metal4Active) scaler = [sd newSpatialScalerWithDevice:ctx.device];
    if (!scaler) { p.spatialUnavailable = YES; return NO; }
    // MetalFX writes an output texture with the usage it requests; Minecraft's main target is copied from it.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst.pixelFormat
                                                                                   width:dst.width height:dst.height mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = [(id<MTLFXSpatialScalerBase>)scaler outputTextureUsage] | MTLTextureUsageShaderRead;
    id<MTLTexture> out = [ctx.device newTextureWithDescriptor:td];
    if (!out) { p.spatialUnavailable = YES; return NO; }
    if (ctx.debugLabels) out.label = @"CelestiaMetal.WorldUpscaleOut";
    if (p.spatialOut) {
        cm_untrack_allocation(ctx, p.spatialOut);
        cm_retire_object(ctx, p.spatialOut, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    if (p.spatial) cm_retire_object(ctx, p.spatial, atomic_load(&ctx->_nextSubmitSerial) + 1);
    cm_track_allocation(ctx, out);
    p.spatial = scaler;
    p.spatialM4 = m4;
    p.spatialOut = out;
    p.inW = src.width; p.inH = src.height; p.outW = dst.width; p.outH = dst.height;
    p.inFmt = src.pixelFormat; p.outFmt = dst.pixelFormat;
    return YES;
}

static BOOL encode_spatial(CMContext *ctx, CMUpscalePath *p, id<MTLTexture> src, id<MTLTexture> dst) {
    if (!ensure_spatial(ctx, p, src, dst)) return NO;
    id<MTLFXSpatialScalerBase> ss = (id<MTLFXSpatialScalerBase>)p.spatial;
    ss.colorTexture = src;
    ss.outputTexture = p.spatialOut;
    ss.inputContentWidth = src.width;
    ss.inputContentHeight = src.height;
    if (ctx.metal4Active) {
        if (@available(macOS 26.0, *)) {
            if (!p.spatialM4) return NO;
            [(id<MTL4FXSpatialScaler>)ss encodeToCommandBuffer:(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf];
            // Copy MetalFX's output into the destination: the copy must wait for MetalFX's write (consumer barrier)
            // and later render passes must see the copy (producer barrier).
            id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
            [ce barrierAfterQueueStages:MTLStageDispatch | MTLStageBlit | MTLStageFragment | MTLStageVertex
                           beforeStages:MTLStageBlit
                      visibilityOptions:MTL4VisibilityOptionDevice];
            [ce copyFromTexture:p.spatialOut toTexture:dst];
            [ce barrierAfterStages:MTLStageBlit
                 beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                 visibilityOptions:MTL4VisibilityOptionDevice];
            [ce endEncoding];
            ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
        }
    } else {
        [(id<MTLFXSpatialScaler>)ss encodeToCommandBuffer:(id<MTLCommandBuffer>)ctx.activeM3CmdBuf];
        id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
        [be copyFromTexture:p.spatialOut toTexture:dst];
        [be endEncoding];
        ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
    }
    return YES;
}

int32_t cm_upscale_to(int64_t ctxPtr, int64_t srcTexPtr, int64_t dstTexPtr, int32_t mode) {
    if (!ctxPtr || !srcTexPtr || !dstTexPtr) return -1;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLTexture> src = (__bridge id<MTLTexture>)(void *)srcTexPtr;
        id<MTLTexture> dst = (__bridge id<MTLTexture>)(void *)dstTexPtr;
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        CMUpscalePath *p = upscale_path(ctx);
        if (mode == 1 && encode_spatial(ctx, p, src, dst)) return 1;
        return encode_bilinear(ctx, p, src, dst) ? 0 : -1;
    }
}

// ---- World render scale: MetalFX Temporal (TemporalUpscaler.java in METALFX_TEMPORAL mode) ----
static BOOL ensure_temporal(CMContext *ctx, CMUpscalePath *p, id<MTLTexture> src, id<MTLTexture> dst) {
    if (p.temporalUnavailable) return NO;
    if (p.temporal && p.tInW == src.width && p.tInH == src.height && p.tOutW == dst.width && p.tOutH == dst.height
        && p.tInFmt == src.pixelFormat && p.tOutFmt == dst.pixelFormat) {
        return YES;
    }
    if (![MTLFXTemporalScalerDescriptor supportsDevice:ctx.device]) { p.temporalUnavailable = YES; return NO; }
    MTLFXTemporalScalerDescriptor *td = [MTLFXTemporalScalerDescriptor new];
    td.colorTextureFormat = src.pixelFormat;
    td.depthTextureFormat = MTLPixelFormatDepth32Float;
    td.motionTextureFormat = MTLPixelFormatRG16Float;
    td.outputTextureFormat = dst.pixelFormat;
    td.inputWidth = src.width;
    td.inputHeight = src.height;
    td.outputWidth = dst.width;
    td.outputHeight = dst.height;
    td.autoExposureEnabled = NO;
    td.reactiveMaskTextureEnabled = NO;
    id scaler = nil;
    BOOL m4 = NO;
    if (ctx.metal4Active && ctx.m4Compiler && [MTLFXTemporalScalerDescriptor respondsToSelector:@selector(supportsMetal4FX:)]
        && [MTLFXTemporalScalerDescriptor supportsMetal4FX:ctx.device]) {
        if (@available(macOS 26.0, *)) {
            scaler = [td newTemporalScalerWithDevice:ctx.device compiler:(id<MTL4Compiler>)ctx.m4Compiler];
            m4 = scaler != nil;
        }
    }
    if (!scaler && !ctx.metal4Active) scaler = [td newTemporalScalerWithDevice:ctx.device];
    if (!scaler) { p.temporalUnavailable = YES; return NO; }
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:dst.pixelFormat
                                                                                   width:dst.width height:dst.height mipmapped:NO];
    od.storageMode = MTLStorageModePrivate;
    od.usage = [(id<MTLFXTemporalScalerBase>)scaler outputTextureUsage] | MTLTextureUsageShaderRead;
    id<MTLTexture> out = [ctx.device newTextureWithDescriptor:od];
    if (!out) { p.temporalUnavailable = YES; return NO; }
    if (ctx.debugLabels) out.label = @"CelestiaMetal.WorldTemporalOut";
    if (p.temporalOut) {
        cm_untrack_allocation(ctx, p.temporalOut);
        cm_retire_object(ctx, p.temporalOut, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    if (p.temporal) cm_retire_object(ctx, p.temporal, atomic_load(&ctx->_nextSubmitSerial) + 1);
    cm_track_allocation(ctx, out);
    p.temporal = scaler;
    p.temporalM4 = m4;
    p.temporalOut = out;
    p.tInW = src.width; p.tInH = src.height; p.tOutW = dst.width; p.tOutH = dst.height;
    p.tInFmt = src.pixelFormat; p.tOutFmt = dst.pixelFormat;
    return YES;
}

int32_t cm_upscale_temporal(int64_t ctxPtr, int64_t srcTexPtr, int64_t depthTexPtr, int64_t motionTexPtr,
                            int64_t dstTexPtr, float jitterX, float jitterY, int32_t reset) {
    if (!ctxPtr || !srcTexPtr || !depthTexPtr || !motionTexPtr || !dstTexPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLTexture> src = (__bridge id<MTLTexture>)(void *)srcTexPtr;
        id<MTLTexture> dst = (__bridge id<MTLTexture>)(void *)dstTexPtr;
        cm_cmd_begin(ctxPtr);
        cm_flush_encoders(ctx);
        CMUpscalePath *p = upscale_path(ctx);
        if (!ensure_temporal(ctx, p, src, dst)) return 0;
        id<MTLFXTemporalScalerBase> ts = (id<MTLFXTemporalScalerBase>)p.temporal;
        ts.colorTexture = src;
        ts.depthTexture = (__bridge id<MTLTexture>)(void *)depthTexPtr;
        ts.motionTexture = (__bridge id<MTLTexture>)(void *)motionTexPtr;
        ts.outputTexture = p.temporalOut;
        ts.inputContentWidth = src.width;
        ts.inputContentHeight = src.height;
        // Jitter in input pixels and motion in UV (scaled to pixels here), both in texture space (+y down).
        ts.jitterOffsetX = jitterX;
        ts.jitterOffsetY = jitterY;
        ts.motionVectorScaleX = (float)src.width;
        ts.motionVectorScaleY = (float)src.height;
        ts.depthReversed = YES;
        ts.reset = reset != 0;
        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                if (!p.temporalM4) return 0;
                id<MTL4ComputeCommandEncoder> pre = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                // MetalFX reads the motion pass's output and the depth copy (consumer barrier for its dispatches).
                [pre barrierAfterQueueStages:MTLStageDispatch | MTLStageBlit | MTLStageFragment | MTLStageVertex
                                beforeStages:MTLStageDispatch | MTLStageBlit
                           visibilityOptions:MTL4VisibilityOptionDevice];
                [pre endEncoding];
                [(id<MTL4FXTemporalScaler>)ts encodeToCommandBuffer:(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf];
                id<MTL4ComputeCommandEncoder> ce = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                [ce barrierAfterQueueStages:MTLStageDispatch | MTLStageBlit | MTLStageFragment | MTLStageVertex
                               beforeStages:MTLStageBlit
                          visibilityOptions:MTL4VisibilityOptionDevice];
                [ce copyFromTexture:p.temporalOut toTexture:dst];
                [ce barrierAfterStages:MTLStageBlit
                     beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                     visibilityOptions:MTL4VisibilityOptionDevice];
                [ce endEncoding];
                ctx->_stats[CM_STAT_BLIT_ENCODERS] += 2;
            }
        } else {
            [(id<MTLFXTemporalScaler>)ts encodeToCommandBuffer:(id<MTLCommandBuffer>)ctx.activeM3CmdBuf];
            id<MTLBlitCommandEncoder> be = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf blitCommandEncoder];
            [be copyFromTexture:p.temporalOut toTexture:dst];
            [be endEncoding];
            ctx->_stats[CM_STAT_BLIT_ENCODERS]++;
        }
        return 1;
    }
}
