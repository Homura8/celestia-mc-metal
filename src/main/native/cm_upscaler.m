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
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);
        cm_cmd_begin(ctxPtr);

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
