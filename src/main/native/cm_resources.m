#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

MTLPixelFormat cm_pixel_format(int32_t fmt) {
    switch (fmt) {
        case CM_FMT_R8_UNORM: return MTLPixelFormatR8Unorm;
        case CM_FMT_R8_SNORM: return MTLPixelFormatR8Snorm;
        case CM_FMT_RG8_UNORM: return MTLPixelFormatRG8Unorm;
        case CM_FMT_RG8_SNORM: return MTLPixelFormatRG8Snorm;
        case CM_FMT_RGBA8_UNORM: return MTLPixelFormatRGBA8Unorm;
        case CM_FMT_RGBA8_SNORM: return MTLPixelFormatRGBA8Snorm;
        case CM_FMT_R16_UNORM: return MTLPixelFormatR16Unorm;
        case CM_FMT_R16_SNORM: return MTLPixelFormatR16Snorm;
        case CM_FMT_RG16_UNORM: return MTLPixelFormatRG16Unorm;
        case CM_FMT_RG16_SNORM: return MTLPixelFormatRG16Snorm;
        case CM_FMT_RGBA16_UNORM: return MTLPixelFormatRGBA16Unorm;
        case CM_FMT_RGBA16_SNORM: return MTLPixelFormatRGBA16Snorm;
        case CM_FMT_R8_UINT: return MTLPixelFormatR8Uint;
        case CM_FMT_R8_SINT: return MTLPixelFormatR8Sint;
        case CM_FMT_RG8_UINT: return MTLPixelFormatRG8Uint;
        case CM_FMT_RG8_SINT: return MTLPixelFormatRG8Sint;
        case CM_FMT_RGBA8_UINT: return MTLPixelFormatRGBA8Uint;
        case CM_FMT_RGBA8_SINT: return MTLPixelFormatRGBA8Sint;
        case CM_FMT_R16_UINT: return MTLPixelFormatR16Uint;
        case CM_FMT_R16_SINT: return MTLPixelFormatR16Sint;
        case CM_FMT_RG16_UINT: return MTLPixelFormatRG16Uint;
        case CM_FMT_RG16_SINT: return MTLPixelFormatRG16Sint;
        case CM_FMT_RGBA16_UINT: return MTLPixelFormatRGBA16Uint;
        case CM_FMT_RGBA16_SINT: return MTLPixelFormatRGBA16Sint;
        case CM_FMT_R32_UINT: return MTLPixelFormatR32Uint;
        case CM_FMT_R32_SINT: return MTLPixelFormatR32Sint;
        case CM_FMT_RG32_UINT: return MTLPixelFormatRG32Uint;
        case CM_FMT_RG32_SINT: return MTLPixelFormatRG32Sint;
        case CM_FMT_RGBA32_UINT: return MTLPixelFormatRGBA32Uint;
        case CM_FMT_RGBA32_SINT: return MTLPixelFormatRGBA32Sint;
        case CM_FMT_R16_FLOAT: return MTLPixelFormatR16Float;
        case CM_FMT_RG16_FLOAT: return MTLPixelFormatRG16Float;
        case CM_FMT_RGBA16_FLOAT: return MTLPixelFormatRGBA16Float;
        case CM_FMT_R32_FLOAT: return MTLPixelFormatR32Float;
        case CM_FMT_RG32_FLOAT: return MTLPixelFormatRG32Float;
        case CM_FMT_RGBA32_FLOAT: return MTLPixelFormatRGBA32Float;
        case CM_FMT_RGB10A2_UNORM: return MTLPixelFormatRGB10A2Unorm;
        case CM_FMT_RGB10A2_UINT: return MTLPixelFormatRGB10A2Uint;
        case CM_FMT_RG11B10_FLOAT: return MTLPixelFormatRG11B10Float;
        case CM_FMT_D32_FLOAT: return MTLPixelFormatDepth32Float;
        case CM_FMT_D32_FLOAT_S8_UINT: return MTLPixelFormatDepth32Float_Stencil8;
        case CM_FMT_D16_UNORM: return MTLPixelFormatDepth16Unorm;
        case CM_FMT_S8_UINT: return MTLPixelFormatStencil8;
        case CM_FMT_BGRA8_UNORM: return MTLPixelFormatBGRA8Unorm;
        case CM_FMT_BGRA8_UNORM_SRGB: return MTLPixelFormatBGRA8Unorm_sRGB;
        case CM_FMT_RGBA8_UNORM_SRGB: return MTLPixelFormatRGBA8Unorm_sRGB;
        default: return MTLPixelFormatInvalid;
    }
}

MTLVertexFormat cm_vertex_format(int32_t fmt) {
    switch (fmt) {
        case CM_FMT_R8_UNORM: return MTLVertexFormatUCharNormalized;
        case CM_FMT_R8_SNORM: return MTLVertexFormatCharNormalized;
        case CM_FMT_RG8_UNORM: return MTLVertexFormatUChar2Normalized;
        case CM_FMT_RG8_SNORM: return MTLVertexFormatChar2Normalized;
        case CM_FMT_RGB8_UNORM: return MTLVertexFormatUChar3Normalized;
        case CM_FMT_RGB8_SNORM: return MTLVertexFormatChar3Normalized;
        case CM_FMT_RGBA8_UNORM: return MTLVertexFormatUChar4Normalized;
        case CM_FMT_RGBA8_SNORM: return MTLVertexFormatChar4Normalized;
        case CM_FMT_R16_UNORM: return MTLVertexFormatUShortNormalized;
        case CM_FMT_R16_SNORM: return MTLVertexFormatShortNormalized;
        case CM_FMT_RG16_UNORM: return MTLVertexFormatUShort2Normalized;
        case CM_FMT_RG16_SNORM: return MTLVertexFormatShort2Normalized;
        case CM_FMT_RGB16_UNORM: return MTLVertexFormatUShort3Normalized;
        case CM_FMT_RGB16_SNORM: return MTLVertexFormatShort3Normalized;
        case CM_FMT_RGBA16_UNORM: return MTLVertexFormatUShort4Normalized;
        case CM_FMT_RGBA16_SNORM: return MTLVertexFormatShort4Normalized;
        case CM_FMT_R8_UINT: return MTLVertexFormatUChar;
        case CM_FMT_R8_SINT: return MTLVertexFormatChar;
        case CM_FMT_RG8_UINT: return MTLVertexFormatUChar2;
        case CM_FMT_RG8_SINT: return MTLVertexFormatChar2;
        case CM_FMT_RGB8_UINT: return MTLVertexFormatUChar3;
        case CM_FMT_RGB8_SINT: return MTLVertexFormatChar3;
        case CM_FMT_RGBA8_UINT: return MTLVertexFormatUChar4;
        case CM_FMT_RGBA8_SINT: return MTLVertexFormatChar4;
        case CM_FMT_R16_UINT: return MTLVertexFormatUShort;
        case CM_FMT_R16_SINT: return MTLVertexFormatShort;
        case CM_FMT_RG16_UINT: return MTLVertexFormatUShort2;
        case CM_FMT_RG16_SINT: return MTLVertexFormatShort2;
        case CM_FMT_RGB16_UINT: return MTLVertexFormatUShort3;
        case CM_FMT_RGB16_SINT: return MTLVertexFormatShort3;
        case CM_FMT_RGBA16_UINT: return MTLVertexFormatUShort4;
        case CM_FMT_RGBA16_SINT: return MTLVertexFormatShort4;
        case CM_FMT_R32_UINT: return MTLVertexFormatUInt;
        case CM_FMT_R32_SINT: return MTLVertexFormatInt;
        case CM_FMT_RG32_UINT: return MTLVertexFormatUInt2;
        case CM_FMT_RG32_SINT: return MTLVertexFormatInt2;
        case CM_FMT_RGB32_UINT: return MTLVertexFormatUInt3;
        case CM_FMT_RGB32_SINT: return MTLVertexFormatInt3;
        case CM_FMT_RGBA32_UINT: return MTLVertexFormatUInt4;
        case CM_FMT_RGBA32_SINT: return MTLVertexFormatInt4;
        case CM_FMT_R16_FLOAT: return MTLVertexFormatHalf;
        case CM_FMT_RG16_FLOAT: return MTLVertexFormatHalf2;
        case CM_FMT_RGB16_FLOAT: return MTLVertexFormatHalf3;
        case CM_FMT_RGBA16_FLOAT: return MTLVertexFormatHalf4;
        case CM_FMT_R32_FLOAT: return MTLVertexFormatFloat;
        case CM_FMT_RG32_FLOAT: return MTLVertexFormatFloat2;
        case CM_FMT_RGB32_FLOAT: return MTLVertexFormatFloat3;
        case CM_FMT_RGBA32_FLOAT: return MTLVertexFormatFloat4;
        case CM_FMT_RGB10A2_UNORM: return MTLVertexFormatUInt1010102Normalized;
        default: return MTLVertexFormatInvalid;
    }
}

NSUInteger cm_bytes_per_pixel(MTLPixelFormat fmt) {
    switch (fmt) {
        case MTLPixelFormatR8Unorm:
        case MTLPixelFormatR8Snorm:
        case MTLPixelFormatR8Uint:
        case MTLPixelFormatR8Sint:
        case MTLPixelFormatStencil8:
            return 1;
        case MTLPixelFormatRG8Unorm:
        case MTLPixelFormatRG8Snorm:
        case MTLPixelFormatRG8Uint:
        case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR16Unorm:
        case MTLPixelFormatR16Snorm:
        case MTLPixelFormatR16Uint:
        case MTLPixelFormatR16Sint:
        case MTLPixelFormatR16Float:
        case MTLPixelFormatDepth16Unorm:
            return 2;
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Snorm:
        case MTLPixelFormatRGBA8Uint:
        case MTLPixelFormatRGBA8Sint:
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRG16Unorm:
        case MTLPixelFormatRG16Snorm:
        case MTLPixelFormatRG16Uint:
        case MTLPixelFormatRG16Sint:
        case MTLPixelFormatRG16Float:
        case MTLPixelFormatR32Uint:
        case MTLPixelFormatR32Sint:
        case MTLPixelFormatR32Float:
        case MTLPixelFormatRGB10A2Unorm:
        case MTLPixelFormatRGB10A2Uint:
        case MTLPixelFormatRG11B10Float:
        case MTLPixelFormatDepth32Float:
            return 4;
        case MTLPixelFormatRGBA16Unorm:
        case MTLPixelFormatRGBA16Snorm:
        case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatRGBA16Sint:
        case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRG32Uint:
        case MTLPixelFormatRG32Sint:
        case MTLPixelFormatRG32Float:
        case MTLPixelFormatDepth32Float_Stencil8:
            return 8;
        case MTLPixelFormatRGBA32Uint:
        case MTLPixelFormatRGBA32Sint:
        case MTLPixelFormatRGBA32Float:
            return 16;
        default:
            return 4;
    }
}

MTLCompareFunction cm_compare_func(int32_t cmp) {
    switch (cmp) {
        case CM_CMP_ALWAYS: return MTLCompareFunctionAlways;
        case CM_CMP_LESS: return MTLCompareFunctionLess;
        case CM_CMP_LESS_EQUAL: return MTLCompareFunctionLessEqual;
        case CM_CMP_EQUAL: return MTLCompareFunctionEqual;
        case CM_CMP_NOT_EQUAL: return MTLCompareFunctionNotEqual;
        case CM_CMP_GREATER_EQUAL: return MTLCompareFunctionGreaterEqual;
        case CM_CMP_GREATER: return MTLCompareFunctionGreater;
        case CM_CMP_NEVER: return MTLCompareFunctionNever;
        default: return MTLCompareFunctionAlways;
    }
}

MTLBlendFactor cm_blend_factor(int32_t factor) {
    switch (factor) {
        case CM_BLEND_ZERO: return MTLBlendFactorZero;
        case CM_BLEND_ONE: return MTLBlendFactorOne;
        case CM_BLEND_SRC_COLOR: return MTLBlendFactorSourceColor;
        case CM_BLEND_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
        case CM_BLEND_DST_COLOR: return MTLBlendFactorDestinationColor;
        case CM_BLEND_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
        case CM_BLEND_SRC_ALPHA: return MTLBlendFactorSourceAlpha;
        case CM_BLEND_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
        case CM_BLEND_DST_ALPHA: return MTLBlendFactorDestinationAlpha;
        case CM_BLEND_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case CM_BLEND_CONSTANT_COLOR: return MTLBlendFactorBlendColor;
        case CM_BLEND_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case CM_BLEND_CONSTANT_ALPHA: return MTLBlendFactorBlendAlpha;
        case CM_BLEND_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        case CM_BLEND_SRC_ALPHA_SATURATE: return MTLBlendFactorSourceAlphaSaturated;
        default: return MTLBlendFactorOne;
    }
}

MTLBlendOperation cm_blend_op(int32_t op) {
    switch (op) {
        case CM_OP_ADD: return MTLBlendOperationAdd;
        case CM_OP_SUBTRACT: return MTLBlendOperationSubtract;
        case CM_OP_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case CM_OP_MIN: return MTLBlendOperationMin;
        case CM_OP_MAX: return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

MTLPrimitiveType cm_primitive_type(int32_t topo) {
    switch (topo) {
        case CM_TOPO_POINTS: return MTLPrimitiveTypePoint;
        case CM_TOPO_LINES: return MTLPrimitiveTypeLine;
        case CM_TOPO_LINE_STRIP: return MTLPrimitiveTypeLineStrip;
        case CM_TOPO_TRIANGLES: return MTLPrimitiveTypeTriangle;
        case CM_TOPO_TRIANGLE_STRIP: return MTLPrimitiveTypeTriangleStrip;
        default: return MTLPrimitiveTypeTriangle;
    }
}

id<MTLDepthStencilState> cm_get_depth_state(CMContext *ctx, BOOL enabled, int32_t cmp, BOOL writeDepth) {
    uint32_t key = ((enabled ? 1u : 0u) << 8) | (((uint32_t)cmp & 0xFu) << 1) | (writeDepth ? 1u : 0u);
    @synchronized(ctx.depthStateCache) {
        id<MTLDepthStencilState> cached = ctx.depthStateCache[@(key)];
        if (cached) return cached;
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = enabled ? cm_compare_func(cmp) : MTLCompareFunctionAlways;
        dsd.depthWriteEnabled = enabled && writeDepth;
        id<MTLDepthStencilState> created = [ctx.device newDepthStencilStateWithDescriptor:dsd];
        if (created) ctx.depthStateCache[@(key)] = created;
        return created;
    }
}

// ---- Buffers ----

int64_t cm_buffer_create(int64_t ctxPtr, int64_t sizeBytes, const void *initialData, const char *labelUtf8) {
    if (!ctxPtr || sizeBytes <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        NSUInteger len = (NSUInteger)sizeBytes;
        // Pad to 4 bytes minimum for Metal safety
        if (len < 16) len = 16;
        id<MTLBuffer> buf = initialData
            ? [ctx.device newBufferWithBytes:initialData length:(NSUInteger)sizeBytes options:MTLResourceStorageModeShared]
            : [ctx.device newBufferWithLength:len options:MTLResourceStorageModeShared];
        if (!buf) return 0;
        if (ctx.debugLabels && labelUtf8) {
            buf.label = [NSString stringWithUTF8String:labelUtf8];
        }
        cm_track_allocation(ctx, buf);
        return (int64_t)(__bridge_retained void *)buf;
    }
}

void cm_buffer_destroy(int64_t ctxPtr, int64_t bufPtr) {
    if (!bufPtr) return;
    @autoreleasepool {
        id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)(void *)bufPtr;
        if (ctxPtr) {
            CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
            uint64_t retireAt = atomic_load(&ctx->_nextSubmitSerial) + 1;
            cm_retire_object(ctx, buf, retireAt);
        }
    }
}

int64_t cm_buffer_contents(int64_t bufPtr) {
    if (!bufPtr) return 0;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
    return (int64_t)(uintptr_t)buf.contents;
}

uint64_t cm_buffer_gpu_address(int64_t bufPtr) {
    if (!bufPtr) return 0;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
    return (uint64_t)buf.gpuAddress;
}

void cm_buffer_write(int64_t bufPtr, int64_t offset, const void *src, int64_t length) {
    if (!bufPtr || !src || length <= 0) return;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
    uint8_t *dst = (uint8_t *)buf.contents;
    if (!dst) return;
    memcpy(dst + offset, src, (size_t)length);
}

// ---- Textures, Views, Samplers ----

int64_t cm_texture_create(int64_t ctxPtr, int32_t format, int32_t width, int32_t height,
                          int32_t depthOrLayers, int32_t mipLevels, int32_t isCube,
                          int32_t isRenderTarget, int32_t isShaderRead, int32_t isShaderWrite,
                          const char *labelUtf8) {
    if (!ctxPtr || width <= 0 || height <= 0) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLPixelFormat pf = cm_pixel_format(format);
        if (pf == MTLPixelFormatInvalid) return 0;

        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.pixelFormat = pf;
        td.width = (NSUInteger)width;
        td.height = (NSUInteger)height;
        td.mipmapLevelCount = (NSUInteger)(mipLevels > 0 ? mipLevels : 1);
        if (isCube) {
            td.textureType = (depthOrLayers > 6) ? MTLTextureTypeCubeArray : MTLTextureTypeCube;
            td.arrayLength = (NSUInteger)MAX(1, depthOrLayers / 6);
            td.depth = 1;
        } else if (depthOrLayers > 1) {
            td.textureType = MTLTextureType2DArray;
            td.arrayLength = (NSUInteger)depthOrLayers;
            td.depth = 1;
        } else {
            td.textureType = MTLTextureType2D;
            td.arrayLength = 1;
            td.depth = 1;
        }
        MTLTextureUsage usage = MTLTextureUsagePixelFormatView;
        if (isShaderRead) usage |= MTLTextureUsageShaderRead;
        if (isShaderWrite) usage |= MTLTextureUsageShaderWrite;
        if (isRenderTarget) usage |= MTLTextureUsageRenderTarget;
        td.usage = usage;
        td.storageMode = MTLStorageModePrivate;

        id<MTLTexture> tex = [ctx.device newTextureWithDescriptor:td];
        if (!tex) return 0;
        if (ctx.debugLabels && labelUtf8) {
            tex.label = [NSString stringWithUTF8String:labelUtf8];
        }
        cm_track_allocation(ctx, tex);
        return (int64_t)(__bridge_retained void *)tex;
    }
}

void cm_texture_destroy(int64_t ctxPtr, int64_t texPtr) {
    if (!texPtr) return;
    @autoreleasepool {
        id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)(void *)texPtr;
        if (ctxPtr) {
            CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
            cm_retire_object(ctx, tex, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
    }
}

int64_t cm_texture_view_create(int64_t ctxPtr, int64_t texPtr, int32_t baseMip, int32_t mipCount) {
    if (!ctxPtr || !texPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)(void *)texPtr;
        NSUInteger maxMips = tex.mipmapLevelCount;
        NSUInteger start = (NSUInteger)MAX(0, baseMip);
        NSUInteger count = (NSUInteger)MIN((NSInteger)mipCount, (NSInteger)(maxMips - start));
        if (count == 0) count = 1;
        NSRange levels = NSMakeRange(start, count);
        NSRange slices = NSMakeRange(0, tex.textureType == MTLTextureTypeCube ? 6 : tex.arrayLength);
        id<MTLTexture> view = [tex newTextureViewWithPixelFormat:tex.pixelFormat
                                                   textureType:tex.textureType
                                                        levels:levels
                                                        slices:slices];
        if (!view) return 0;
        cm_track_allocation(ctx, view);
        return (int64_t)(__bridge_retained void *)view;
    }
}

int64_t cm_texture_buffer_create(int64_t ctxPtr, int64_t bufPtr, int64_t offset, int64_t lengthBytes, int32_t format) {
    if (!ctxPtr || !bufPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)(void *)bufPtr;
        MTLPixelFormat pf = cm_pixel_format(format);
        if (pf == MTLPixelFormatInvalid) return 0;

        NSUInteger bpp = cm_bytes_per_pixel(pf);
        if (bpp == 0) bpp = 4;
        NSUInteger width = (NSUInteger)MAX(1LL, lengthBytes / (int64_t)bpp);
        NSUInteger neededBytes = width * bpp;
        NSUInteger align = MAX(1UL, [ctx.device minimumLinearTextureAlignmentForPixelFormat:pf]);
        NSUInteger rowBytes = ((neededBytes + align - 1UL) / align) * align;
        if (rowBytes < bpp) rowBytes = bpp;

        id<MTLBuffer> backingBuf = nil;
        NSUInteger viewOffset = 0;
        if (offset >= 0 && ((NSUInteger)offset % align) == 0 && (NSUInteger)offset + rowBytes <= buf.length) {
            backingBuf = buf;
            viewOffset = (NSUInteger)offset;
        } else {
            NSUInteger allocBytes = MAX(16UL, rowBytes);
            id<MTLBuffer> staging = [ctx.device newBufferWithLength:allocBytes options:MTLResourceStorageModeShared];
            if (!staging) return 0;
            uint8_t *dst = (uint8_t *)staging.contents;
            memset(dst, 0, allocBytes);
            if (offset >= 0 && (NSUInteger)offset < buf.length && buf.contents != NULL) {
                NSUInteger avail = buf.length - (NSUInteger)offset;
                NSUInteger copyBytes = MIN(neededBytes, avail);
                if (copyBytes > 0) {
                    memcpy(dst, (const uint8_t *)buf.contents + (NSUInteger)offset, copyBytes);
                }
            }
            cm_track_allocation(ctx, staging);
            cm_retire_object(ctx, staging, atomic_load(&ctx->_nextSubmitSerial) + 1);
            backingBuf = staging;
            viewOffset = 0;
        }

        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureTypeTextureBuffer;
        td.pixelFormat = pf;
        td.width = width;
        td.height = 1;
        td.depth = 1;
        td.mipmapLevelCount = 1;
        td.arrayLength = 1;
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = (backingBuf.storageMode == MTLStorageModePrivate) ? MTLStorageModePrivate : MTLStorageModeShared;

        id<MTLTexture> tbuf = [backingBuf newTextureWithDescriptor:td offset:viewOffset bytesPerRow:rowBytes];
        if (!tbuf) return 0;
        cm_track_allocation(ctx, tbuf);
        return (int64_t)(__bridge_retained void *)tbuf;
    }
}

void cm_texture_view_destroy(int64_t ctxPtr, int64_t viewPtr) {
    cm_texture_destroy(ctxPtr, viewPtr);
}

static MTLSamplerAddressMode to_addr_mode(int32_t mode) {
    return (mode == 0) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
}

int64_t cm_sampler_create(int64_t ctxPtr, int32_t addrU, int32_t addrV,
                          int32_t minFilter, int32_t magFilter, int32_t mipFilter,
                          int32_t maxAnisotropy, int32_t hasCompare, int32_t compareFunc) {
    if (!ctxPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = to_addr_mode(addrU);
        sd.tAddressMode = to_addr_mode(addrV);
        sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.minFilter = minFilter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.magFilter = magFilter ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.mipFilter = mipFilter == 2 ? MTLSamplerMipFilterLinear
                     : (mipFilter == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped);
        sd.maxAnisotropy = (NSUInteger)MAX(1, MIN(16, maxAnisotropy));
        sd.supportArgumentBuffers = YES;
        if (hasCompare) {
            sd.compareFunction = cm_compare_func(compareFunc);
        }
        id<MTLSamplerState> ss = [ctx.device newSamplerStateWithDescriptor:sd];
        if (!ss) return 0;
        return (int64_t)(__bridge_retained void *)ss;
    }
}

void cm_sampler_destroy(int64_t ctxPtr, int64_t sampPtr) {
    if (!sampPtr) return;
    @autoreleasepool {
        id<MTLSamplerState> ss = (__bridge_transfer id<MTLSamplerState>)(void *)sampPtr;
        (void)ss;
    }
}

// ---- Shaders & Pipelines ----

int64_t cm_compile_msl_library(int64_t ctxPtr, const char *mslSourceUtf8, const char *labelUtf8,
                               int32_t fastMath, char *errBuf, int32_t errBufSize) {
    if (!ctxPtr || !mslSourceUtf8) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        NSString *src = [NSString stringWithUTF8String:mslSourceUtf8];
        if (!src) {
            if (errBuf && errBufSize > 0) strlcpy(errBuf, "Invalid UTF-8 MSL source", (size_t)errBufSize);
            return 0;
        }
        MTLCompileOptions *opts = [MTLCompileOptions new];
        opts.languageVersion = MTLLanguageVersion3_2;
        if (@available(macOS 15.0, *)) {
            opts.mathMode = fastMath ? MTLMathModeFast : MTLMathModeSafe;
            opts.mathFloatingPointFunctions = fastMath ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
        } else {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            opts.fastMathEnabled = fastMath ? YES : NO;
            #pragma clang diagnostic pop
        }

        NSError *err = nil;
        id<MTLLibrary> lib = nil;
        if (ctx.metal4Active && ctx.m4Compiler) {
            if (@available(macOS 26.0, *)) {
                MTL4LibraryDescriptor *ld = [MTL4LibraryDescriptor new];
                ld.source = src;
                ld.options = opts;
                if (labelUtf8) ld.name = [NSString stringWithUTF8String:labelUtf8];
                lib = [(id<MTL4Compiler>)ctx.m4Compiler newLibraryWithDescriptor:ld error:&err];
            }
        }
        if (!lib && !ctx.metal4Active) {
            lib = [ctx.device newLibraryWithSource:src options:opts error:&err];
        } else if (!lib && err == nil) {
            lib = [ctx.device newLibraryWithSource:src options:opts error:&err];
        }

        if (!lib) {
            NSString *msg = err ? err.localizedDescription : @"Unknown MSL compile error";
            if (errBuf && errBufSize > 0) strlcpy(errBuf, msg.UTF8String ?: "Compile error", (size_t)errBufSize);
            return 0;
        }
        if (ctx.debugLabels && labelUtf8) {
            lib.label = [NSString stringWithUTF8String:labelUtf8];
        }
        return (int64_t)(__bridge_retained void *)lib;
    }
}

void cm_library_destroy(int64_t libPtr) {
    if (!libPtr) return;
    @autoreleasepool {
        id<MTLLibrary> lib = (__bridge_transfer id<MTLLibrary>)(void *)libPtr;
        (void)lib;
    }
}

int64_t cm_compile_function(int64_t libPtr, const char *entryPointUtf8, int32_t hasConst,
                            int32_t constId, int32_t constVal, char *errBuf, int32_t errBufSize) {
    if (!libPtr || !entryPointUtf8) return 0;
    @autoreleasepool {
        id<MTLLibrary> lib = (__bridge id<MTLLibrary>)(void *)libPtr;
        NSString *name = [NSString stringWithUTF8String:entryPointUtf8];
        id<MTLFunction> fn = nil;
        if (hasConst) {
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            int32_t val = constVal;
            [cv setConstantValue:&val type:MTLDataTypeInt atIndex:(NSUInteger)constId];
            NSError *err = nil;
            fn = [lib newFunctionWithName:name constantValues:cv error:&err];
            if (!fn && err && errBuf && errBufSize > 0) {
                strlcpy(errBuf, err.localizedDescription.UTF8String ?: "Function error", (size_t)errBufSize);
            }
        } else {
            fn = [lib newFunctionWithName:name];
            if (!fn && errBuf && errBufSize > 0) {
                snprintf(errBuf, (size_t)errBufSize, "Function '%s' not found in library", entryPointUtf8);
            }
        }
        if (!fn) return 0;
        return (int64_t)(__bridge_retained void *)fn;
    }
}

void cm_function_destroy(int64_t fnPtr) {
    if (!fnPtr) return;
    @autoreleasepool {
        id<MTLFunction> fn = (__bridge_transfer id<MTLFunction>)(void *)fnPtr;
        (void)fn;
    }
}

@interface CMPipelineBox : NSObject
@property (nonatomic, strong) id<MTLRenderPipelineState> state;
@property (nonatomic, strong) id<MTLDepthStencilState> depthState;
@property (nonatomic) MTLCullMode cullMode;
@property (nonatomic) MTLTriangleFillMode fillMode;
@property (nonatomic) float depthBiasSlope;
@property (nonatomic) float depthBiasConst;
@property (nonatomic) uint32_t depthKey;
@end

@implementation CMPipelineBox
@end

int64_t cm_render_pipeline_create(int64_t ctxPtr, int64_t vsFnPtr, int64_t fsFnPtr,
                                  const CMVertexBufferDesc *vtxBufs, int32_t vtxBufCount,
                                  const CMAttribBindingDesc *attribs, int32_t attribCount,
                                  const CMColorAttachmentDesc *colors, int32_t colorCount,
                                  int32_t depthFormat, int32_t topology, int32_t polygonMode,
                                  int32_t cullEnabled, int32_t depthTestEnabled,
                                  int32_t depthCompare, int32_t depthWrite,
                                  float depthBiasSlope, float depthBiasConst,
                                  const char *labelUtf8, char *errBuf, int32_t errBufSize) {
    if (!ctxPtr || !vsFnPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
        rpd.vertexFunction = (__bridge id<MTLFunction>)(void *)vsFnPtr;
        if (fsFnPtr) rpd.fragmentFunction = (__bridge id<MTLFunction>)(void *)fsFnPtr;
        if (labelUtf8) rpd.label = [NSString stringWithUTF8String:labelUtf8];

        if (vtxBufCount > 0 || attribCount > 0) {
            MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
            for (int32_t i = 0; i < vtxBufCount; i++) {
                NSUInteger slot = CM_VERTEX_BUFFER_BASE + (NSUInteger)vtxBufs[i].slot;
                if (vtxBufs[i].stride == 0) {
                    vd.layouts[slot].stride = 16;
                    vd.layouts[slot].stepFunction = MTLVertexStepFunctionConstant;
                    vd.layouts[slot].stepRate = 0;
                } else {
                    vd.layouts[slot].stride = (NSUInteger)vtxBufs[i].stride;
                    if (vtxBufs[i].stepRate > 0) {
                        vd.layouts[slot].stepFunction = MTLVertexStepFunctionPerInstance;
                        vd.layouts[slot].stepRate = (NSUInteger)vtxBufs[i].stepRate;
                    } else {
                        vd.layouts[slot].stepFunction = MTLVertexStepFunctionPerVertex;
                        vd.layouts[slot].stepRate = 1;
                    }
                }
            }
            for (int32_t i = 0; i < attribCount; i++) {
                NSUInteger loc = (NSUInteger)attribs[i].location;
                MTLVertexFormat vf = cm_vertex_format(attribs[i].vertexFormat);
                if (vf == MTLVertexFormatInvalid) continue;
                vd.attributes[loc].format = vf;
                vd.attributes[loc].offset = (NSUInteger)attribs[i].offset;
                vd.attributes[loc].bufferIndex = CM_VERTEX_BUFFER_BASE + (NSUInteger)attribs[i].bufferSlot;
            }
            rpd.vertexDescriptor = vd;
        }

        for (int32_t i = 0; i < colorCount && i < CM_MAX_COLOR_ATTACHMENTS; i++) {
            MTLRenderPipelineColorAttachmentDescriptor *ca = rpd.colorAttachments[(NSUInteger)i];
            ca.pixelFormat = cm_pixel_format(colors[i].format);
            ca.blendingEnabled = colors[i].blendEnabled != 0;
            if (colors[i].blendEnabled) {
                ca.sourceRGBBlendFactor = cm_blend_factor(colors[i].srcColor);
                ca.destinationRGBBlendFactor = cm_blend_factor(colors[i].dstColor);
                ca.rgbBlendOperation = cm_blend_op(colors[i].colorOp);
                ca.sourceAlphaBlendFactor = cm_blend_factor(colors[i].srcAlpha);
                ca.destinationAlphaBlendFactor = cm_blend_factor(colors[i].dstAlpha);
                ca.alphaBlendOperation = cm_blend_op(colors[i].alphaOp);
            }
            MTLColorWriteMask wm = MTLColorWriteMaskNone;
            if (colors[i].writeMask & 1) wm |= MTLColorWriteMaskRed;
            if (colors[i].writeMask & 2) wm |= MTLColorWriteMaskGreen;
            if (colors[i].writeMask & 4) wm |= MTLColorWriteMaskBlue;
            if (colors[i].writeMask & 8) wm |= MTLColorWriteMaskAlpha;
            ca.writeMask = wm;
        }

        if (depthFormat >= 0) {
            MTLPixelFormat df = cm_pixel_format(depthFormat);
            rpd.depthAttachmentPixelFormat = df;
            if (df == MTLPixelFormatDepth32Float_Stencil8) {
                rpd.stencilAttachmentPixelFormat = df;
            }
        }

        if (ctx.binaryArchive) {
            rpd.binaryArchives = @[ctx.binaryArchive];
        }

        NSError *err = nil;
        id<MTLRenderPipelineState> pso = [ctx.device newRenderPipelineStateWithDescriptor:rpd error:&err];
        if (!pso) {
            if (errBuf && errBufSize > 0) {
                strlcpy(errBuf, err ? (err.localizedDescription.UTF8String ?: "Pipeline error") : "Pipeline failed", (size_t)errBufSize);
            }
            return 0;
        }
        if (ctx.binaryArchive) {
            NSError *archErr = nil;
            @synchronized(ctx.binaryArchive) {
                [ctx.binaryArchive addRenderPipelineFunctionsWithDescriptor:rpd error:&archErr];
            }
        }

        CMPipelineBox *box = [CMPipelineBox new];
        box.state = pso;
        box.depthState = cm_get_depth_state(ctx, depthTestEnabled != 0, depthCompare, depthWrite != 0);
        box.depthKey = ((depthTestEnabled ? 1u : 0u) << 8) | (((uint32_t)depthCompare & 0xFu) << 1) | (depthWrite ? 1u : 0u);
        // RenderPearl/Vulkan Y-flip reverses triangle winding compared to GL/Metal default CCW, so cull back -> front/back appropriately
        box.cullMode = cullEnabled ? MTLCullModeBack : MTLCullModeNone;
        box.fillMode = polygonMode ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        box.depthBiasSlope = depthBiasSlope;
        box.depthBiasConst = depthBiasConst;
        return (int64_t)(__bridge_retained void *)box;
    }
}

void cm_pipeline_destroy(int64_t ctxPtr, int64_t pipePtr) {
    if (!pipePtr) return;
    @autoreleasepool {
        CMPipelineBox *box = (__bridge_transfer CMPipelineBox *)(void *)pipePtr;
        if (ctxPtr) {
            CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
            cm_retire_object(ctx, box, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
    }
}

int64_t cm_compute_pipeline_create(int64_t ctxPtr, int64_t csFnPtr, const char *labelUtf8,
                                   char *errBuf, int32_t errBufSize) {
    if (!ctxPtr || !csFnPtr) return 0;
    @autoreleasepool {
        CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
        MTLComputePipelineDescriptor *cpd = [MTLComputePipelineDescriptor new];
        cpd.computeFunction = (__bridge id<MTLFunction>)(void *)csFnPtr;
        if (labelUtf8) cpd.label = [NSString stringWithUTF8String:labelUtf8];
        if (ctx.binaryArchive) cpd.binaryArchives = @[ctx.binaryArchive];

        NSError *err = nil;
        id<MTLComputePipelineState> cps = [ctx.device newComputePipelineStateWithDescriptor:cpd
                                                                                    options:MTLPipelineOptionNone
                                                                                 reflection:nil
                                                                                      error:&err];
        if (!cps) {
            if (errBuf && errBufSize > 0) {
                strlcpy(errBuf, err ? (err.localizedDescription.UTF8String ?: "Compute pipeline error") : "Compute pipeline failed", (size_t)errBufSize);
            }
            return 0;
        }
        if (ctx.binaryArchive) {
            NSError *archErr = nil;
            @synchronized(ctx.binaryArchive) {
                [ctx.binaryArchive addComputePipelineFunctionsWithDescriptor:cpd error:&archErr];
            }
        }
        return (int64_t)(__bridge_retained void *)cps;
    }
}

void cm_compute_pipeline_destroy(int64_t ctxPtr, int64_t pipePtr) {
    if (!pipePtr) return;
    @autoreleasepool {
        id<MTLComputePipelineState> cps = (__bridge_transfer id<MTLComputePipelineState>)(void *)pipePtr;
        if (ctxPtr) {
            CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
            cm_retire_object(ctx, cps, atomic_load(&ctx->_nextSubmitSerial) + 1);
        }
    }
}
