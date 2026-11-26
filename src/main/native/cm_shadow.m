#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

#define CM_SHADOW_CHUNK_QUADS 32
#define CM_SHADOW_CHUNK_INDICES (CM_SHADOW_CHUNK_QUADS * 6)
#define CM_SHADOW_ORIG_RING_SLOTS 16

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

static id<MTLDepthStencilState> ensure_shadow_depth_state(CMContext *ctx) {
    if (ctx.shadowDepthState) return ctx.shadowDepthState;
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
    // Reversed-Z shadow map cleared to 0.0: nearer to the light = larger depth value.
    dsd.depthCompareFunction = MTLCompareFunctionGreaterEqual;
    dsd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> ds = [ctx.device newDepthStencilStateWithDescriptor:dsd];
    ctx.shadowDepthState = ds;
    return ds;
}

static id<MTLBuffer> ensure_shadow_quad_idx16(CMContext *ctx) {
    if (ctx.shadowQuadIdx16) return ctx.shadowQuadIdx16;
    uint16_t indices[CM_SHADOW_CHUNK_INDICES];
    static const uint16_t corners[6] = {0, 1, 2, 2, 3, 0};
    for (int q = 0, i = 0; q < CM_SHADOW_CHUNK_QUADS; q++) {
        for (int c = 0; c < 6; c++) {
            indices[i++] = (uint16_t)(q * 4 + corners[c]);
        }
    }
    id<MTLBuffer> buf = [ctx.device newBufferWithBytes:indices
                                               length:sizeof(indices)
                                              options:MTLResourceStorageModeShared];
    if (!buf) return nil;
    if (ctx.debugLabels) buf.label = @"CelestiaShadow.QuadIdx16";
    cm_track_allocation(ctx, buf);
    ctx.shadowQuadIdx16 = buf;
    return buf;
}

static id<MTLBuffer> ensure_shadow_quad_idx32(CMContext *ctx, uint32_t maxQuads) {
    if (maxQuads == 0) maxQuads = 1;
    NSUInteger needed = (NSUInteger)maxQuads * 6UL;
    if (ctx.shadowQuadIdx32 && ctx.shadowQuadIdx32Cap >= needed) {
        return ctx.shadowQuadIdx32;
    }
    NSUInteger quadCap = MAX(MAX((NSUInteger)maxQuads, 4096UL), (ctx.shadowQuadIdx32Cap / 6UL) * 2UL);
    NSUInteger idxCap = quadCap * 6UL;
    id<MTLBuffer> buf = [ctx.device newBufferWithLength:idxCap * sizeof(uint32_t)
                                               options:MTLResourceStorageModeShared];
    if (!buf) return nil;
    if (ctx.debugLabels) buf.label = @"CelestiaShadow.QuadIdx32";
    uint32_t *idx = (uint32_t *)buf.contents;
    static const uint32_t corners[6] = {0u, 1u, 2u, 2u, 3u, 0u};
    for (NSUInteger q = 0; q < quadCap; q++) {
        uint32_t base = (uint32_t)(q * 4UL);
        for (int c = 0; c < 6; c++) {
            idx[q * 6UL + (NSUInteger)c] = base + corners[c];
        }
    }
    cm_track_allocation(ctx, buf);
    if (ctx.shadowQuadIdx32) {
        cm_retire_object(ctx, ctx.shadowQuadIdx32, atomic_load(&ctx->_nextSubmitSerial) + 1);
    }
    ctx.shadowQuadIdx32 = buf;
    ctx.shadowQuadIdx32Cap = idxCap;
    return buf;
}

static id<MTLBuffer> acquire_vanilla_origin_buffer(CMContext *ctx, const CMShadowVanillaDraw *draws, int32_t drawCount) {
    if (!ctx.shadowOrigRing) {
        ctx.shadowOrigRing = [NSMutableArray arrayWithCapacity:CM_SHADOW_ORIG_RING_SLOTS];
        for (int i = 0; i < CM_SHADOW_ORIG_RING_SLOTS; i++) {
            [ctx.shadowOrigRing addObject:[NSNull null]];
        }
    }
    static uint32_t sOriginCursor = 0;
    uint32_t slot = sOriginCursor % CM_SHADOW_ORIG_RING_SLOTS;
    sOriginCursor++;

    NSUInteger neededBytes = MAX(256UL, (NSUInteger)drawCount * 16UL);
    id cur = ctx.shadowOrigRing[slot];
    id<MTLBuffer> buf = (cur != [NSNull null]) ? (id<MTLBuffer>)cur : nil;
    if (!buf || buf.length < neededBytes) {
        NSUInteger newCap = MAX(neededBytes, buf ? buf.length * 2UL : 4096UL);
        id<MTLBuffer> nb = [ctx.device newBufferWithLength:newCap options:MTLResourceStorageModeShared];
        if (!nb) return nil;
        if (ctx.debugLabels) nb.label = @"CelestiaShadow.VanillaOrigins";
        cm_track_allocation(ctx, nb);
        if (buf) {
            cm_retire_object(ctx, buf, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
        ctx.shadowOrigRing[slot] = nb;
        buf = nb;
    }
    float *dst = (float *)buf.contents;
    for (int32_t i = 0; i < drawCount; i++) {
        dst[i * 4 + 0] = draws[i].originX;
        dst[i * 4 + 1] = draws[i].originY;
        dst[i * 4 + 2] = draws[i].originZ;
        dst[i * 4 + 3] = 0.0f;
    }
    return buf;
}

void cm_shadow_render_sodium(int64_t ctxPtr, int64_t shadowTexPtr, int32_t layer, int32_t resolution,
                             int64_t solidPsoPtr, int64_t cutoutPsoPtr,
                             const void *cascadeData, int32_t cascadeBytes,
                             int64_t chunksBufPtr, int64_t chunksOffset,
                             int64_t regionsBufPtr, int64_t regionsOffset,
                             const void *drawsPtr, int32_t drawCount,
                             int64_t atlasTexPtr, int64_t atlasSampPtr,
                             float slopeScale, float clamp, int32_t loadExisting) {
    if (!ctxPtr || !shadowTexPtr || !solidPsoPtr || !cascadeData || cascadeBytes <= 0 || resolution <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_flush_encoders(ctx);
        cm_ensure_cmd_begun(ctx);
        cm_reset_pass_cache(ctx);

        id<MTLTexture> shadowTex = (__bridge id<MTLTexture>)(void *)shadowTexPtr;
        CMPipelineBox *solidBox = (__bridge CMPipelineBox *)(void *)solidPsoPtr;
        CMPipelineBox *cutoutBox = cutoutPsoPtr ? (__bridge CMPipelineBox *)(void *)cutoutPsoPtr : nil;
        id<MTLBuffer> chunksBuf = chunksBufPtr ? (__bridge id<MTLBuffer>)(void *)chunksBufPtr : nil;
        id<MTLBuffer> regionsBuf = regionsBufPtr ? (__bridge id<MTLBuffer>)(void *)regionsBufPtr : nil;
        id<MTLTexture> atlasTex = atlasTexPtr ? (__bridge id<MTLTexture>)(void *)atlasTexPtr : nil;
        id<MTLSamplerState> atlasSamp = atlasSampPtr ? (__bridge id<MTLSamplerState>)(void *)atlasSampPtr : nil;
        id<MTLDepthStencilState> depthState = ensure_shadow_depth_state(ctx);
        id<MTLBuffer> idx16 = ensure_shadow_quad_idx16(ctx);
        if (!depthState || !idx16) return;

        const CMShadowSodiumDraw *draws = (const CMShadowSodiumDraw *)drawsPtr;
        BOOL hasDraws = (draws != NULL && drawCount > 0 && chunksBuf != nil && regionsBuf != nil);
        int64_t encodedDraws = 0;

        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.depthAttachment.texture = shadowTex;
                rpd.depthAttachment.slice = (NSUInteger)MAX(0, layer);
                rpd.depthAttachment.loadAction = loadExisting ? MTLLoadActionLoad : MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 0.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
                rpd.renderTargetWidth = (NSUInteger)resolution;
                rpd.renderTargetHeight = (NSUInteger)resolution;

                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return;
                if (ctx.debugLabels) {
                    enc.label = (layer == 0) ? @"CelestiaShadow.Sodium.Cascade0" : @"CelestiaShadow.Sodium.Cascade1";
                }
                [enc setViewport:(MTLViewport){0.0, 0.0, (double)resolution, (double)resolution, 0.0, 1.0}];
                [enc setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)resolution, (NSUInteger)resolution}];
                [enc setDepthStencilState:depthState];
                [enc setCullMode:MTLCullModeNone];
                [enc setDepthClipMode:MTLDepthClipModeClamp];
                [enc setDepthBias:0.0f slopeScale:slopeScale clamp:clamp];

                if (hasDraws) {
                    id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
                    MTLGPUAddress casAddr = cm_m4_push_ring_alloc(ctx, cascadeData, (NSUInteger)cascadeBytes);
                    [at setAddress:casAddr atIndex:3];
                    [at setAddress:chunksBuf.gpuAddress + (MTLGPUAddress)MAX(0LL, chunksOffset) atIndex:1];
                    [at setAddress:regionsBuf.gpuAddress + (MTLGPUAddress)MAX(0LL, regionsOffset) atIndex:2];
                    if (atlasTex && atlasSamp) {
                        [at setTexture:atlasTex.gpuResourceID atIndex:0];
                        [at setSamplerState:atlasSamp.gpuResourceID atIndex:0];
                    }
                    [enc setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];

                    int32_t curKind = -1;
                    int64_t curArena = 0;
                    for (int32_t i = 0; i < drawCount; i++) {
                        const CMShadowSodiumDraw *d = &draws[i];
                        if (d->chunkCount == 0 || d->arenaBufPtr == 0) continue;
                        int32_t k = (d->kind != 0) ? 1 : 0;
                        if (k == 1 && (!cutoutBox || !atlasTex || !atlasSamp)) continue;
                        if (k != curKind) {
                            CMPipelineBox *box = (k == 1) ? cutoutBox : solidBox;
                            [enc setRenderPipelineState:box.state];
                            curKind = k;
                        }
                        if (d->arenaBufPtr != curArena) {
                            id<MTLBuffer> arena = (__bridge id<MTLBuffer>)(void *)d->arenaBufPtr;
                            [at setAddress:arena.gpuAddress atIndex:0];
                            curArena = d->arenaBufPtr;
                        }
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:CM_SHADOW_CHUNK_INDICES
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:idx16.gpuAddress
                                 indexBufferLength:idx16.length
                                     instanceCount:(NSUInteger)d->chunkCount
                                        baseVertex:0
                                      baseInstance:(NSUInteger)d->firstChunk];
                        encodedDraws++;
                    }
                }
                cm_emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.depthAttachment.texture = shadowTex;
            rpd.depthAttachment.slice = (NSUInteger)MAX(0, layer);
            rpd.depthAttachment.loadAction = loadExisting ? MTLLoadActionLoad : MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 0.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            rpd.renderTargetWidth = (NSUInteger)resolution;
            rpd.renderTargetHeight = (NSUInteger)resolution;

            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return;
            if (ctx.debugLabels) {
                enc.label = (layer == 0) ? @"CelestiaShadow.Sodium.Cascade0" : @"CelestiaShadow.Sodium.Cascade1";
            }
            [enc setViewport:(MTLViewport){0.0, 0.0, (double)resolution, (double)resolution, 0.0, 1.0}];
            [enc setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)resolution, (NSUInteger)resolution}];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeNone];
            [enc setDepthClipMode:MTLDepthClipModeClamp];
            [enc setDepthBias:0.0f slopeScale:slopeScale clamp:clamp];

            if (hasDraws) {
                [enc setVertexBytes:cascadeData length:(NSUInteger)cascadeBytes atIndex:3];
                [enc setVertexBuffer:chunksBuf offset:(NSUInteger)MAX(0LL, chunksOffset) atIndex:1];
                [enc setVertexBuffer:regionsBuf offset:(NSUInteger)MAX(0LL, regionsOffset) atIndex:2];
                if (atlasTex && atlasSamp) {
                    [enc setFragmentTexture:atlasTex atIndex:0];
                    [enc setFragmentSamplerState:atlasSamp atIndex:0];
                }
                int32_t curKind = -1;
                int64_t curArena = 0;
                for (int32_t i = 0; i < drawCount; i++) {
                    const CMShadowSodiumDraw *d = &draws[i];
                    if (d->chunkCount == 0 || d->arenaBufPtr == 0) continue;
                    int32_t k = (d->kind != 0) ? 1 : 0;
                    if (k == 1 && (!cutoutBox || !atlasTex || !atlasSamp)) continue;
                    if (k != curKind) {
                        CMPipelineBox *box = (k == 1) ? cutoutBox : solidBox;
                        [enc setRenderPipelineState:box.state];
                        curKind = k;
                    }
                    if (d->arenaBufPtr != curArena) {
                        id<MTLBuffer> arena = (__bridge id<MTLBuffer>)(void *)d->arenaBufPtr;
                        [enc setVertexBuffer:arena offset:0 atIndex:0];
                        curArena = d->arenaBufPtr;
                    }
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:CM_SHADOW_CHUNK_INDICES
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:idx16
                             indexBufferOffset:0
                                 instanceCount:(NSUInteger)d->chunkCount
                                    baseVertex:0
                                  baseInstance:(NSUInteger)d->firstChunk];
                    encodedDraws++;
                }
            }
            [enc endEncoding];
        }

        ctx->_stats[CM_STAT_DRAWS] += encodedDraws;
        cm_reset_pass_cache(ctx);
    }
}

void cm_shadow_render_vanilla(int64_t ctxPtr, int64_t shadowTexPtr, int32_t layer, int32_t resolution,
                              int64_t solidPsoPtr, int64_t cutoutPsoPtr,
                              const void *cascadeData, int32_t cascadeBytes,
                              const void *drawsPtr, int32_t drawCount,
                              int64_t atlasTexPtr, int64_t atlasSampPtr,
                              float slopeScale, float clamp, int32_t loadExisting) {
    if (!ctxPtr || !shadowTexPtr || !solidPsoPtr || !cascadeData || cascadeBytes <= 0 || resolution <= 0) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        cm_flush_encoders(ctx);
        cm_ensure_cmd_begun(ctx);
        cm_reset_pass_cache(ctx);

        id<MTLTexture> shadowTex = (__bridge id<MTLTexture>)(void *)shadowTexPtr;
        CMPipelineBox *solidBox = (__bridge CMPipelineBox *)(void *)solidPsoPtr;
        CMPipelineBox *cutoutBox = cutoutPsoPtr ? (__bridge CMPipelineBox *)(void *)cutoutPsoPtr : nil;
        id<MTLTexture> atlasTex = atlasTexPtr ? (__bridge id<MTLTexture>)(void *)atlasTexPtr : nil;
        id<MTLSamplerState> atlasSamp = atlasSampPtr ? (__bridge id<MTLSamplerState>)(void *)atlasSampPtr : nil;
        id<MTLDepthStencilState> depthState = ensure_shadow_depth_state(ctx);
        if (!depthState) return;

        const CMShadowVanillaDraw *draws = (const CMShadowVanillaDraw *)drawsPtr;
        uint32_t maxQuads = 0;
        if (draws && drawCount > 0) {
            for (int32_t i = 0; i < drawCount; i++) {
                if (draws[i].quadCount > maxQuads) maxQuads = draws[i].quadCount;
            }
        }
        BOOL hasDraws = (draws != NULL && drawCount > 0 && maxQuads > 0);
        id<MTLBuffer> idx32 = hasDraws ? ensure_shadow_quad_idx32(ctx, maxQuads) : nil;
        id<MTLBuffer> origBuf = hasDraws ? acquire_vanilla_origin_buffer(ctx, draws, drawCount) : nil;
        if (hasDraws && (!idx32 || !origBuf)) hasDraws = NO;

        int64_t encodedDraws = 0;
        ctx->_stats[CM_STAT_RENDER_ENCODERS]++;

        if (ctx.metal4Active) {
            if (@available(macOS 26.0, *)) {
                MTL4RenderPassDescriptor *rpd = [MTL4RenderPassDescriptor new];
                rpd.depthAttachment.texture = shadowTex;
                rpd.depthAttachment.slice = (NSUInteger)MAX(0, layer);
                rpd.depthAttachment.loadAction = loadExisting ? MTLLoadActionLoad : MTLLoadActionClear;
                rpd.depthAttachment.clearDepth = 0.0;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
                rpd.renderTargetWidth = (NSUInteger)resolution;
                rpd.renderTargetHeight = (NSUInteger)resolution;

                id<MTL4RenderCommandEncoder> enc = [(id<MTL4CommandBuffer>)ctx.activeM4CmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (!enc) return;
                if (ctx.debugLabels) {
                    enc.label = (layer == 0) ? @"CelestiaShadow.Vanilla.Cascade0" : @"CelestiaShadow.Vanilla.Cascade1";
                }
                [enc setViewport:(MTLViewport){0.0, 0.0, (double)resolution, (double)resolution, 0.0, 1.0}];
                [enc setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)resolution, (NSUInteger)resolution}];
                [enc setDepthStencilState:depthState];
                [enc setCullMode:MTLCullModeNone];
                [enc setDepthClipMode:MTLDepthClipModeClamp];
                [enc setDepthBias:0.0f slopeScale:slopeScale clamp:clamp];

                if (hasDraws) {
                    id<MTL4ArgumentTable> at = (id<MTL4ArgumentTable>)ctx.m4VertexArgTable;
                    MTLGPUAddress casAddr = cm_m4_push_ring_alloc(ctx, cascadeData, (NSUInteger)cascadeBytes);
                    [at setAddress:casAddr atIndex:3];
                    [at setAddress:origBuf.gpuAddress atIndex:4];
                    if (atlasTex && atlasSamp) {
                        [at setTexture:atlasTex.gpuResourceID atIndex:0];
                        [at setSamplerState:atlasSamp.gpuResourceID atIndex:0];
                    }
                    [enc setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];

                    int32_t curKind = -1;
                    MTLGPUAddress curAddr = 0;
                    for (int32_t i = 0; i < drawCount; i++) {
                        const CMShadowVanillaDraw *d = &draws[i];
                        if (d->quadCount == 0 || d->vertexBufPtr == 0) continue;
                        int32_t k = (d->kind != 0) ? 1 : 0;
                        if (k == 1 && (!cutoutBox || !atlasTex || !atlasSamp)) continue;
                        if (k != curKind) {
                            CMPipelineBox *box = (k == 1) ? cutoutBox : solidBox;
                            [enc setRenderPipelineState:box.state];
                            curKind = k;
                        }
                        id<MTLBuffer> vbuf = (__bridge id<MTLBuffer>)(void *)d->vertexBufPtr;
                        MTLGPUAddress vaddr = vbuf.gpuAddress + (MTLGPUAddress)d->vertexByteOffset;
                        if (vaddr != curAddr) {
                            [at setAddress:vaddr atIndex:0];
                            curAddr = vaddr;
                        }
                        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:(NSUInteger)d->quadCount * 6UL
                                         indexType:MTLIndexTypeUInt32
                                       indexBuffer:idx32.gpuAddress
                                 indexBufferLength:idx32.length
                                     instanceCount:1
                                        baseVertex:0
                                      baseInstance:(NSUInteger)i];
                        encodedDraws++;
                    }
                }
                cm_emit_m4_render_producer_barrier(enc);
                [enc endEncoding];
            }
        } else {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.depthAttachment.texture = shadowTex;
            rpd.depthAttachment.slice = (NSUInteger)MAX(0, layer);
            rpd.depthAttachment.loadAction = loadExisting ? MTLLoadActionLoad : MTLLoadActionClear;
            rpd.depthAttachment.clearDepth = 0.0;
            rpd.depthAttachment.storeAction = MTLStoreActionStore;
            rpd.renderTargetWidth = (NSUInteger)resolution;
            rpd.renderTargetHeight = (NSUInteger)resolution;

            id<MTLRenderCommandEncoder> enc = [(id<MTLCommandBuffer>)ctx.activeM3CmdBuf renderCommandEncoderWithDescriptor:rpd];
            if (!enc) return;
            if (ctx.debugLabels) {
                enc.label = (layer == 0) ? @"CelestiaShadow.Vanilla.Cascade0" : @"CelestiaShadow.Vanilla.Cascade1";
            }
            [enc setViewport:(MTLViewport){0.0, 0.0, (double)resolution, (double)resolution, 0.0, 1.0}];
            [enc setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)resolution, (NSUInteger)resolution}];
            [enc setDepthStencilState:depthState];
            [enc setCullMode:MTLCullModeNone];
            [enc setDepthClipMode:MTLDepthClipModeClamp];
            [enc setDepthBias:0.0f slopeScale:slopeScale clamp:clamp];

            if (hasDraws) {
                [enc setVertexBytes:cascadeData length:(NSUInteger)cascadeBytes atIndex:3];
                [enc setVertexBuffer:origBuf offset:0 atIndex:4];
                if (atlasTex && atlasSamp) {
                    [enc setFragmentTexture:atlasTex atIndex:0];
                    [enc setFragmentSamplerState:atlasSamp atIndex:0];
                }
                int32_t curKind = -1;
                int64_t curBuf = 0;
                uint64_t curOff = UINT64_MAX;
                for (int32_t i = 0; i < drawCount; i++) {
                    const CMShadowVanillaDraw *d = &draws[i];
                    if (d->quadCount == 0 || d->vertexBufPtr == 0) continue;
                    int32_t k = (d->kind != 0) ? 1 : 0;
                    if (k == 1 && (!cutoutBox || !atlasTex || !atlasSamp)) continue;
                    if (k != curKind) {
                        CMPipelineBox *box = (k == 1) ? cutoutBox : solidBox;
                        [enc setRenderPipelineState:box.state];
                        curKind = k;
                    }
                    if (d->vertexBufPtr != curBuf) {
                        id<MTLBuffer> vbuf = (__bridge id<MTLBuffer>)(void *)d->vertexBufPtr;
                        [enc setVertexBuffer:vbuf offset:(NSUInteger)d->vertexByteOffset atIndex:0];
                        curBuf = d->vertexBufPtr;
                        curOff = d->vertexByteOffset;
                    } else if (d->vertexByteOffset != curOff) {
                        [enc setVertexBufferOffset:(NSUInteger)d->vertexByteOffset atIndex:0];
                        curOff = d->vertexByteOffset;
                    }
                    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:(NSUInteger)d->quadCount * 6UL
                                     indexType:MTLIndexTypeUInt32
                                   indexBuffer:idx32
                             indexBufferOffset:0
                                 instanceCount:1
                                    baseVertex:0
                                  baseInstance:(NSUInteger)i];
                    encodedDraws++;
                }
            }
            [enc endEncoding];
        }

        ctx->_stats[CM_STAT_DRAWS] += encodedDraws;
        cm_reset_pass_cache(ctx);
    }
}
