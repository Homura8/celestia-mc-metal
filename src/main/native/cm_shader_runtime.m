#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

void cm_compute_dispatch(int64_t ctxPtr, int64_t computePipePtr,
                         const int64_t *bufPtrs, const int64_t *bufOffsets, int32_t bufCount,
                         const int64_t *texPtrs, int32_t texCount,
                         const int64_t *sampPtrs, int32_t sampCount,
                         int32_t gx, int32_t gy, int32_t gz,
                         int32_t tx, int32_t ty, int32_t tz) {
    if (!ctxPtr || !computePipePtr || gx <= 0 || gy <= 0 || gz <= 0 || tx <= 0 || ty <= 0 || tz <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_cmd_begin(ctxPtr);
        if (ctx.activeRenderEnc) cm_pass_end(ctxPtr);
        cm_end_blit_if_active(ctx);

        id<MTLComputePipelineState> cps = (__bridge id<MTLComputePipelineState>)(void *)computePipePtr;
        MTLSize groups = MTLSizeMake((NSUInteger)gx, (NSUInteger)gy, (NSUInteger)gz);
        MTLSize threads = MTLSizeMake((NSUInteger)tx, (NSUInteger)ty, (NSUInteger)tz);

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                id<MTL4ComputeCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf computeCommandEncoder];
                if (!enc) return;
                [enc setComputePipelineState:cps];
                id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4FragmentArgTable;
                for (int32_t i = 0; i < bufCount; i++) {
                    if (bufPtrs[i]) {
                        id<MTLBuffer> b = (__bridge id<MTLBuffer>)(void *)bufPtrs[i];
                        MTLGPUAddress off = bufOffsets ? (MTLGPUAddress)bufOffsets[i] : 0;
                        [at setAddress:b.gpuAddress + off atIndex:(NSUInteger)i];
                    }
                }
                for (int32_t i = 0; i < texCount; i++) {
                    if (texPtrs[i]) {
                        id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)texPtrs[i];
                        [at setTexture:t.gpuResourceID atIndex:(NSUInteger)i];
                    }
                }
                for (int32_t i = 0; i < sampCount; i++) {
                    if (sampPtrs[i]) {
                        id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)(void *)sampPtrs[i];
                        [at setSamplerState:s.gpuResourceID atIndex:(NSUInteger)i];
                    }
                }
                [enc setArgumentTable:at];
                [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
                [enc barrierAfterStages:MTLStageDispatch
                      beforeQueueStages:MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit
                      visibilityOptions:MTL4VisibilityOptionDevice];
                [enc endEncoding];
            }
        } else {
            id<MTLComputeCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf computeCommandEncoder];
            if (!enc) return;
            [enc setComputePipelineState:cps];
            for (int32_t i = 0; i < bufCount; i++) {
                if (bufPtrs[i]) {
                    id<MTLBuffer> b = (__bridge id<MTLBuffer>)(void *)bufPtrs[i];
                    NSUInteger off = bufOffsets ? (NSUInteger)bufOffsets[i] : 0;
                    [enc setBuffer:b offset:off atIndex:(NSUInteger)i];
                }
            }
            for (int32_t i = 0; i < texCount; i++) {
                if (texPtrs[i]) {
                    id<MTLTexture> t = (__bridge id<MTLTexture>)(void *)texPtrs[i];
                    [enc setTexture:t atIndex:(NSUInteger)i];
                }
            }
            for (int32_t i = 0; i < sampCount; i++) {
                if (sampPtrs[i]) {
                    id<MTLSamplerState> s = (__bridge id<MTLSamplerState>)(void *)sampPtrs[i];
                    [enc setSamplerState:s atIndex:(NSUInteger)i];
                }
            }
            [enc dispatchThreadgroups:groups threadsPerThreadgroup:threads];
            [enc endEncoding];
        }
    }
}
