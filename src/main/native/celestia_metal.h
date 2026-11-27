#ifndef CELESTIA_METAL_H
#define CELESTIA_METAL_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <os/lock.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>

#define CM_ABI_VERSION 10
#define CM_MAX_COLOR_ATTACHMENTS 8
#define CM_MAX_VERTEX_BUFFERS 8
#define CM_MAX_UNIFORM_BUFFERS 15
#define CM_PUSH_CONSTANT_SLOT 15
#define CM_VERTEX_BUFFER_BASE 16
#define CM_MAX_TEXTURES 31
#define CM_MAX_SAMPLERS 16
#define CM_INFLIGHT_SLOTS 4
#define CM_MAX_PENDING_CLEARS 8

// Global shader-suite slot reservations (CelestiaShade P1+)
#define CM_SHADE_BUF_FRAME     24
#define CM_SHADE_BUF_LOOK      25
#define CM_SHADE_BUF_GPU       26
#define CM_SHADE_BUF_RESOURCES 27
#define CM_SHADE_BUF_WATER     28
#define CM_SHADE_BUF_DYNLIGHTS 29
#define CM_SHADE_BUF_COLORLIGHT 30
#define CM_SHADE_TEX_SHADOW       16
#define CM_SHADE_TEX_SKY_LUT      17
#define CM_SHADE_TEX_WATER_SCENE  18
#define CM_SHADE_TEX_WATER_DEPTH  19
#define CM_SHADE_TEX_WATER_WAVES  20
#define CM_SHADE_TEX_WATER_PYR    21
#define CM_SHADE_TEX_WATER_DETAIL 22
#define CM_SHADE_TEX_DL_VIS       23
#define CM_SHADE_TEX_DL_IRR       24
#define CM_SHADE_TEX_DL_DIR       25
#define CM_SHADE_TEX_CL_FINE      26
#define CM_SHADE_TEX_CL_COARSE    27
#define CM_SHADE_TEX_CL_LEVELS    28
#define CM_SHADE_SAMP_SHADOW      12
#define CM_SHADE_SAMP_LINEAR      13
#define CM_SHADE_MAX_RES_TEX      16

typedef enum CMFormat {
    CM_FMT_R8_UNORM = 0,
    CM_FMT_R8_SNORM = 1,
    CM_FMT_RG8_UNORM = 2,
    CM_FMT_RG8_SNORM = 3,
    CM_FMT_RGBA8_UNORM = 4,
    CM_FMT_RGBA8_SNORM = 5,
    CM_FMT_R16_UNORM = 6,
    CM_FMT_R16_SNORM = 7,
    CM_FMT_RG16_UNORM = 8,
    CM_FMT_RG16_SNORM = 9,
    CM_FMT_RGBA16_UNORM = 10,
    CM_FMT_RGBA16_SNORM = 11,
    CM_FMT_R8_UINT = 12,
    CM_FMT_R8_SINT = 13,
    CM_FMT_RG8_UINT = 14,
    CM_FMT_RG8_SINT = 15,
    CM_FMT_RGBA8_UINT = 16,
    CM_FMT_RGBA8_SINT = 17,
    CM_FMT_R16_UINT = 18,
    CM_FMT_R16_SINT = 19,
    CM_FMT_RG16_UINT = 20,
    CM_FMT_RG16_SINT = 21,
    CM_FMT_RGBA16_UINT = 22,
    CM_FMT_RGBA16_SINT = 23,
    CM_FMT_R32_UINT = 24,
    CM_FMT_R32_SINT = 25,
    CM_FMT_RG32_UINT = 26,
    CM_FMT_RG32_SINT = 27,
    CM_FMT_RGBA32_UINT = 28,
    CM_FMT_RGBA32_SINT = 29,
    CM_FMT_R16_FLOAT = 30,
    CM_FMT_RG16_FLOAT = 31,
    CM_FMT_RGBA16_FLOAT = 32,
    CM_FMT_R32_FLOAT = 33,
    CM_FMT_RG32_FLOAT = 34,
    CM_FMT_RGBA32_FLOAT = 35,
    CM_FMT_RGB10A2_UNORM = 36,
    CM_FMT_RGB10A2_UINT = 37,
    CM_FMT_RG11B10_FLOAT = 38,
    CM_FMT_D32_FLOAT = 39,
    CM_FMT_D32_FLOAT_S8_UINT = 40,
    CM_FMT_D16_UNORM = 41,
    CM_FMT_S8_UINT = 42,
    CM_FMT_BGRA8_UNORM = 43,
    CM_FMT_BGRA8_UNORM_SRGB = 44,
    CM_FMT_RGBA8_UNORM_SRGB = 45,
    CM_FMT_RGB8_UNORM = 46,
    CM_FMT_RGB8_SNORM = 47,
    CM_FMT_RGB16_UNORM = 48,
    CM_FMT_RGB16_SNORM = 49,
    CM_FMT_RGB8_UINT = 50,
    CM_FMT_RGB8_SINT = 51,
    CM_FMT_RGB16_UINT = 52,
    CM_FMT_RGB16_SINT = 53,
    CM_FMT_RGB32_UINT = 54,
    CM_FMT_RGB32_SINT = 55,
    CM_FMT_RGB16_FLOAT = 56,
    CM_FMT_RGB32_FLOAT = 57,
} CMFormat;

typedef enum CMCompareFunc {
    CM_CMP_ALWAYS = 0,
    CM_CMP_LESS = 1,
    CM_CMP_LESS_EQUAL = 2,
    CM_CMP_EQUAL = 3,
    CM_CMP_NOT_EQUAL = 4,
    CM_CMP_GREATER_EQUAL = 5,
    CM_CMP_GREATER = 6,
    CM_CMP_NEVER = 7,
} CMCompareFunc;

typedef enum CMBlendFactor {
    CM_BLEND_ZERO = 0,
    CM_BLEND_ONE = 1,
    CM_BLEND_SRC_COLOR = 2,
    CM_BLEND_ONE_MINUS_SRC_COLOR = 3,
    CM_BLEND_DST_COLOR = 4,
    CM_BLEND_ONE_MINUS_DST_COLOR = 5,
    CM_BLEND_SRC_ALPHA = 6,
    CM_BLEND_ONE_MINUS_SRC_ALPHA = 7,
    CM_BLEND_DST_ALPHA = 8,
    CM_BLEND_ONE_MINUS_DST_ALPHA = 9,
    CM_BLEND_CONSTANT_COLOR = 10,
    CM_BLEND_ONE_MINUS_CONSTANT_COLOR = 11,
    CM_BLEND_CONSTANT_ALPHA = 12,
    CM_BLEND_ONE_MINUS_CONSTANT_ALPHA = 13,
    CM_BLEND_SRC_ALPHA_SATURATE = 14,
} CMBlendFactor;

typedef enum CMBlendOp {
    CM_OP_ADD = 0,
    CM_OP_SUBTRACT = 1,
    CM_OP_REVERSE_SUBTRACT = 2,
    CM_OP_MIN = 3,
    CM_OP_MAX = 4,
} CMBlendOp;

typedef enum CMTopology {
    CM_TOPO_POINTS = 0,
    CM_TOPO_LINES = 1,
    CM_TOPO_LINE_STRIP = 2,
    CM_TOPO_TRIANGLES = 3,
    CM_TOPO_TRIANGLE_STRIP = 4,
    CM_TOPO_TRIANGLE_FAN = 5,
} CMTopology;

// Device option ids for cm_device_set_option
typedef enum CMDeviceOption {
    CM_OPT_PASS_MERGE = 0,   // 1 = merge consecutive load-only passes on identical attachments (default 1)
    CM_OPT_DEFER_CLEARS = 1, // 1 = fold clears into the next pass load action (default 1)
} CMDeviceOption;

// Cumulative encoder statistics (indices into cm_device_stats output array)
typedef enum CMStatIndex {
    CM_STAT_PASSES_BEGUN = 0,      // RenderPearl render passes begun
    CM_STAT_RENDER_ENCODERS = 1,   // Metal render encoders actually created (passes + flushed clears + present)
    CM_STAT_PASSES_MERGED = 2,     // passes that reused the still-open previous encoder
    CM_STAT_CLEARS_FOLDED = 3,     // clear requests folded into a pass load action
    CM_STAT_CLEARS_FLUSHED = 4,    // clear requests emitted as standalone clear encoders
    CM_STAT_DRAWS = 5,             // individual GPU draw calls encoded
    CM_STAT_BLIT_ENCODERS = 6,     // blit (Metal 4 compute) encoders opened
    CM_STAT_FRAMES_SUBMITTED = 7,  // frames handed to the surface (blitFromTexture)
    CM_STAT_PRESENTS_SHOWN = 8,    // presents macOS reported on screen (non-blocking present path)
    CM_STAT_FRAMES_DROPPED = 9,    // finished frames superseded by a newer one before reaching the screen
    CM_STAT_WAIT_THROTTLE_US = 10, // CPU time blocked waiting for in-flight frames (submit / command-buffer ring)
    CM_STAT_WAIT_FENCE_US = 11,    // CPU time blocked in fence waits (cm_wait_submit from Java: ring buffers, readbacks)
    CM_STAT_WAIT_SLOT_US = 12,     // CPU time blocked waiting for a free present slot (non-blocking present)
    CM_STAT_COUNT = 13,
} CMStatIndex;

typedef struct CMProbeInfo {
    int32_t supported;
    int32_t metal4Supported;
    int32_t appleGpuFamily;
    int32_t maxTextureSize;
    int32_t maxAnisotropy;
    int32_t maxRefreshRateHz;
    int32_t thermalState;
    int32_t lowPowerMode;
    float edrHeadroom;
    uint64_t recommendedMaxWorkingSetBytes;
    char gpuName[256];
    char unsupportedReason[256];
} CMProbeInfo;

typedef struct CMColorAttachmentDesc {
    int32_t format;
    int32_t blendEnabled;
    int32_t srcColor;
    int32_t dstColor;
    int32_t colorOp;
    int32_t srcAlpha;
    int32_t dstAlpha;
    int32_t alphaOp;
    int32_t writeMask;
} CMColorAttachmentDesc;

typedef struct CMVertexBufferDesc {
    int32_t slot;
    int32_t stride;
    int32_t stepRate;
} CMVertexBufferDesc;

typedef struct CMAttribBindingDesc {
    int32_t bufferSlot;
    int32_t location;
    int32_t offset;
    int32_t vertexFormat;
} CMAttribBindingDesc;

typedef struct CMShadowSodiumDraw {
    int64_t arenaBufPtr;
    uint32_t firstChunk;
    uint32_t chunkCount;
    uint32_t kind;   // 0 = solid, 1 = cutout
    uint32_t pad;
} CMShadowSodiumDraw;

typedef struct CMShadowVanillaDraw {
    int64_t vertexBufPtr;
    uint64_t vertexByteOffset;
    uint32_t quadCount;
    uint32_t kind;   // 0 = solid, 1 = cutout
    float originX;
    float originY;
    float originZ;
    float pad;
} CMShadowVanillaDraw;

@interface CMRetiredEntry : NSObject
@property (nonatomic, strong) id object;
@property (nonatomic) uint64_t retireSerial;
@end

@interface CMShaderPass : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) id<MTLRenderPipelineState> renderPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> computePipeline;
@property (nonatomic) BOOL isCompute;
@end

// Properties are direct (no objc_msgSend): CMContext is read on every native draw/bind call.
__attribute__((objc_direct_members))
@interface CMContext : NSObject {
@public
    MTLPixelFormat _currentColorFormats[CM_MAX_COLOR_ATTACHMENTS];
    uintptr_t _boundVtxBufs[CM_MAX_VERTEX_BUFFERS];
    NSUInteger _boundVtxOffsets[CM_MAX_VERTEX_BUFFERS];
    NSUInteger _boundVtxStrides[CM_MAX_VERTEX_BUFFERS];
    uintptr_t _boundTextures[CM_MAX_TEXTURES];
    uintptr_t _boundSamplers[CM_MAX_SAMPLERS];
    _Atomic uint64_t _nextSubmitSerial;
    _Atomic uint64_t _completedSubmitSerial;
    _Atomic uint64_t _lastGpuFrameNs;
    _Atomic int32_t _deviceLost;
    _Atomic int32_t _errorCount;
    // Metal 4 argument-table GPU address dedup caches (reset on every new render encoder)
    MTLGPUAddress _boundUboAddrV[CM_MAX_UNIFORM_BUFFERS];
    MTLGPUAddress _boundUboAddrF[CM_MAX_UNIFORM_BUFFERS];
    MTLGPUAddress _boundVtxAddr[CM_MAX_VERTEX_BUFFERS];
    // Last push-constant bytes and their ring address (Metal 4): identical consecutive pushes reuse the address.
    uint8_t _lastPush[256];
    int32_t _lastPushSize;
    MTLGPUAddress _lastPushAddr;
    // Soft-ended pass attachments (used to merge the next compatible pass into the same encoder)
    uintptr_t _passColorViews[CM_MAX_COLOR_ATTACHMENTS];
    // Deferred clears (folded into the next pass that targets the texture, or flushed before other work)
    __strong id<MTLTexture> _pendingClearTex[CM_MAX_PENDING_CLEARS];
    float _pendingClearColor[CM_MAX_PENDING_CLEARS][4];
    double _pendingClearDepth[CM_MAX_PENDING_CLEARS];
    BOOL _pendingClearIsDepth[CM_MAX_PENDING_CLEARS];
    int32_t _pendingClearCount;
    // Cumulative statistics (render thread only, except the atomics below)
    int64_t _stats[CM_STAT_COUNT];
    // Written by the surface present queue / presented handlers
    _Atomic int64_t _presentsShown;
    _Atomic int64_t _framesDropped;
    _Atomic int64_t _waitThrottleUs;
    _Atomic int64_t _waitFenceUs;
    _Atomic int64_t _waitSlotUs;
    id _shadeResTextures[CM_SHADE_MAX_RES_TEX];
}
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic) BOOL metal4Active;
@property (nonatomic) BOOL debugLabels;
@property (nonatomic) int appleGpuFamily;
@property (nonatomic, strong) NSString *archivePath;

// Metal 3 queue
@property (nonatomic, strong) id<MTLCommandQueue> m3Queue;

// Metal 4 objects (allocated only when metal4Active == YES)
@property (nonatomic, strong) id m4Queue;       // id<MTL4CommandQueue>
@property (nonatomic, strong) id m4Compiler;    // id<MTL4Compiler>
@property (nonatomic, strong) id residencySet;  // id<MTLResidencySet>
@property (nonatomic, strong) NSMutableArray *m4Allocators; // id<MTL4CommandAllocator>
@property (nonatomic) BOOL residencyDirty;

// Active command recording state
@property (nonatomic, strong) id activeM3CmdBuf;
@property (nonatomic, strong) id activeM4CmdBuf;
@property (nonatomic) NSUInteger activeM4AllocatorIdx;
@property (nonatomic, strong) id activeRenderEnc;   // id<MTLRenderCommandEncoder> or id<MTL4RenderCommandEncoder>
@property (nonatomic, strong) id activeBlitEnc;     // id<MTLBlitCommandEncoder> or id<MTL4ComputeCommandEncoder>
@property (nonatomic) BOOL blitHasOps;
@property (nonatomic, strong) id m4VertexArgTable;  // id<MTL4ArgumentTable>
@property (nonatomic, strong) id m4FragmentArgTable;// id<MTL4ArgumentTable>

// Triangle-fan shared index buffer cache
@property (nonatomic, strong) id<MTLBuffer> fanIndexBuffer;
@property (nonatomic) NSUInteger fanIndexCapacity;

// Binary archive for persistent pipeline caching
@property (nonatomic, strong) id<MTLBinaryArchive> binaryArchive;

// Synchronization & lifetime management
@property (nonatomic, strong) id<MTLSharedEvent> submitEvent;
@property (nonatomic, strong) NSMutableArray<CMRetiredEntry *> *retired;
@property (nonatomic, strong) NSMutableArray<NSString *> *errors;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLDepthStencilState>> *depthStateCache;

// Transient push-constant ring for Metal 4 (stores bytes & gives GPU address)
@property (nonatomic, strong) id<MTLBuffer> pushRingBuffer;
@property (nonatomic) NSUInteger pushRingOffset;
@property (nonatomic) NSUInteger pushRingSize;

// Current render pass cached bindings for native deduplication
@property (nonatomic) uintptr_t boundPipeline;
@property (nonatomic) uint32_t boundDepthKey;
@property (nonatomic) int32_t boundCullMode;
@property (nonatomic) int32_t boundFillMode;
@property (nonatomic) int32_t currentColorCount;
@property (nonatomic) MTLPixelFormat currentDepthFormat;
@property (nonatomic) BOOL currentHasDepth;
@property (nonatomic) int32_t currentPassWidth;
@property (nonatomic) int32_t currentPassHeight;
@property (nonatomic) uintptr_t boundIndexBuffer;
@property (nonatomic) MTLIndexType boundIndexType;
@property (nonatomic) BOOL m4ArgDirtyVertex;
@property (nonatomic) BOOL m4ArgDirtyFragment;
@property (nonatomic) dispatch_semaphore_t inflightSem;

// Render pass merging state
@property (nonatomic) BOOL passMergeEnabled;
@property (nonatomic) BOOL deferClearsEnabled;
@property (nonatomic) BOOL passSoftEnded;       // RenderPearl ended the pass but the encoder is kept open
@property (nonatomic) BOOL passMergeable;       // the open encoder can accept a following load-only pass
@property (nonatomic) int32_t passColorCount;
@property (nonatomic) uintptr_t passDepthView;

// World render-scale upscaling state (CMUpscalePath, cm_upscaler.m)
@property (nonatomic, strong) id upscalePath;
// Global shader-suite state (CelestiaShade P1+)
@property (nonatomic, assign) BOOL shadeGlobalsEnabled;
@property (nonatomic, strong) id shadeFrameBuf;
@property (nonatomic, assign) uint64_t shadeFrameOffset;
@property (nonatomic, strong) id shadeLookBuf;
@property (nonatomic, assign) uint64_t shadeLookOffset;
@property (nonatomic, strong) id shadeGpuBuf;
@property (nonatomic, assign) uint64_t shadeGpuOffset;
@property (nonatomic, strong) id shadeResBuf;
@property (nonatomic, assign) uint64_t shadeResOffset;
@property (nonatomic, strong) id shadeSkyLutTex;
@property (nonatomic, strong) id shadeShadowTex;
@property (nonatomic, strong) id shadeDummyTex;
// Dynamic lights (P6a, cm_dynlight.m): active module state and the zeroed fallback bound when it is off.
@property (nonatomic, strong) id dynLightState;
@property (nonatomic, strong) id dynLightFallback;
@property (nonatomic, strong) id colorLightState;
@property (nonatomic, strong) id colorLightFallback;
@property (nonatomic, strong) id shadeLinearSampler;
@property (nonatomic, strong) id shadeShadowSampler;
// Native sun/moon shadow pass state (P2+, cm_shadow.m)
@property (nonatomic, strong) id<MTLBuffer> shadowQuadIdx16;
@property (nonatomic, strong) id<MTLBuffer> shadowQuadIdx32;
@property (nonatomic) NSUInteger shadowQuadIdx32Cap;
@property (nonatomic, strong) NSMutableArray *shadowOrigRing;
@property (nonatomic, strong) id<MTLDepthStencilState> shadowDepthState;
// Scissor mirror for reopening passes (cm_water.m)
@property (nonatomic) BOOL currentScissorEnabled;
@property (nonatomic) int32_t currentScissorX;
@property (nonatomic) int32_t currentScissorY;
@property (nonatomic) int32_t currentScissorW;
@property (nonatomic) int32_t currentScissorH;
// Native water pass state (P3a+, cm_water.m)
@property (nonatomic) BOOL waterEnabled;
@property (nonatomic) BOOL waterCopyValid;
@property (nonatomic, strong) id<MTLBuffer> waterParamsBuf;
@property (nonatomic) uint64_t waterParamsOffset;
@property (nonatomic, strong) id<MTLBuffer> waterDummyParamsBuf;
@property (nonatomic, strong) id<MTLTexture> waterSceneCopy;
@property (nonatomic, strong) id<MTLTexture> waterDepthCopy;
@property (nonatomic, strong) id<MTLTexture> waterPyrTex;
@property (nonatomic, strong) id<MTLTexture> waterPyrTmp8;
@property (nonatomic, strong) id<MTLTexture> waterPyrTmp16;
@property (nonatomic, strong) id<MTLTexture> waterWavesTex;
@property (nonatomic, strong) id<MTLTexture> waterDetailTex;
@property (nonatomic, strong) id<MTLTexture> waterDummyHalf;
@property (nonatomic, strong) id<MTLTexture> waterDummyDepth;
@property (nonatomic, strong) id<MTLTexture> waterDummyFloat;
@end

// Internal helpers shared across native .m modules
MTLPixelFormat cm_pixel_format(int32_t fmt);
MTLVertexFormat cm_vertex_format(int32_t fmt);
MTLCompareFunction cm_compare_func(int32_t cmp);
MTLBlendFactor cm_blend_factor(int32_t factor);
MTLBlendOperation cm_blend_op(int32_t op);
MTLPrimitiveType cm_primitive_type(int32_t topo);
void cm_record_error(CMContext *ctx, NSString *msg);
void cm_track_allocation(CMContext *ctx, id allocation);
void cm_untrack_allocation(CMContext *ctx, id allocation);
void cm_commit_residency_if_dirty(CMContext *ctx);
void cm_retire_object(CMContext *ctx, id obj, uint64_t serial);
void cm_drain_retired(CMContext *ctx);
id<MTLDepthStencilState> cm_get_depth_state(CMContext *ctx, BOOL enabled, int32_t cmp, BOOL writeDepth);
void cm_end_blit_if_active(CMContext *ctx);
// Ends any open render encoder, flushes deferred clears and ends the blit encoder.
// Call before encoding any non-render-pass GPU work (compute, MetalFX, present, submit).
void cm_flush_encoders(CMContext *ctx);
void cm_ensure_cmd_begun(CMContext *ctx);
void cm_reset_pass_cache(CMContext *ctx);
void cm_emit_m4_render_producer_barrier(id enc);
MTLGPUAddress cm_m4_push_ring_alloc(CMContext *ctx, const void *data, NSUInteger size);
void cm_shade_bind_render_encoder(CMContext *ctx, const int64_t *colorViewPtrs, int32_t colorCount);
void cm_water_bind_render_encoder(CMContext *ctx, const int64_t *colorViewPtrs, int32_t colorCount);
void cm_dynlight_bind_render_encoder(CMContext *ctx);
void cm_colorlight_bind_render_encoder(CMContext *ctx);
// Opt-in Metal 4 GPU pass profiler (cm_profiler.m; CELESTIA_GPU_PROFILE=1).
void cm_prof_init(CMContext *ctx);
void cm_prof_begin(id cb);
int cm_prof_end(id cb);
void cm_prof_done(int slot);
// Waits for submit `serial`; the blocked time is accounted to *waitUs (may be NULL). timeoutNs == 0 only polls.
int32_t cm_wait_submit_accounted(CMContext *ctx, uint64_t serial, uint64_t timeoutNs, _Atomic int64_t *waitUs);
NSUInteger cm_bytes_per_pixel(MTLPixelFormat fmt);

// Public C ABI exported to Java FFM & native test harness
#ifdef __cplusplus
extern "C" {
#endif

int32_t cm_abi_version(void);
void cm_probe_device(CMProbeInfo *outInfo);
void cm_query_system_telemetry(int32_t *outThermalState, int32_t *outLowPowerMode,
                               int32_t *outRefreshHz, float *outEdrHeadroom);

int64_t cm_device_create(int32_t preferMetal4, int32_t debugLabels, const char *archivePathUtf8);
void cm_device_destroy(int64_t ctxPtr);
int32_t cm_device_is_metal4(int64_t ctxPtr);
int32_t cm_device_is_lost(int64_t ctxPtr);
uint64_t cm_device_completed_submit(int64_t ctxPtr);
uint64_t cm_device_next_submit(int64_t ctxPtr);
uint64_t cm_device_last_gpu_ns(int64_t ctxPtr);
int32_t cm_device_drain_errors(int64_t ctxPtr, char *buf, int32_t bufSize);
void cm_device_wait_idle(int64_t ctxPtr);
void cm_device_set_option(int64_t ctxPtr, int32_t option, int32_t value);
// Copies min(count, CM_STAT_COUNT) cumulative counters (see CMStatIndex) into out.
void cm_device_stats(int64_t ctxPtr, int64_t *out, int32_t count);

// Buffers
int64_t cm_buffer_create(int64_t ctxPtr, int64_t sizeBytes, const void *initialData, const char *labelUtf8);
void cm_buffer_destroy(int64_t ctxPtr, int64_t bufPtr);
int64_t cm_buffer_contents(int64_t bufPtr);
uint64_t cm_buffer_gpu_address(int64_t bufPtr);
void cm_buffer_write(int64_t bufPtr, int64_t offset, const void *src, int64_t length);

// Textures & Views & Samplers
int64_t cm_texture_create(int64_t ctxPtr, int32_t format, int32_t width, int32_t height,
                          int32_t depthOrLayers, int32_t mipLevels, int32_t isCube,
                          int32_t isRenderTarget, int32_t isShaderRead, int32_t isShaderWrite,
                          const char *labelUtf8);
void cm_texture_destroy(int64_t ctxPtr, int64_t texPtr);
int64_t cm_texture_view_create(int64_t ctxPtr, int64_t texPtr, int32_t baseMip, int32_t mipCount);
int64_t cm_texture_buffer_create(int64_t ctxPtr, int64_t bufPtr, int64_t offset, int64_t lengthBytes, int32_t format);
void cm_texture_view_destroy(int64_t ctxPtr, int64_t viewPtr);
int64_t cm_sampler_create(int64_t ctxPtr, int32_t addrU, int32_t addrV,
                          int32_t minFilter, int32_t magFilter, int32_t mipFilter,
                          int32_t maxAnisotropy, int32_t hasCompare, int32_t compareFunc);
void cm_sampler_destroy(int64_t ctxPtr, int64_t sampPtr);

// Shaders & Pipelines
int64_t cm_compile_msl_library(int64_t ctxPtr, const char *mslSourceUtf8, const char *labelUtf8,
                               int32_t fastMath, char *errBuf, int32_t errBufSize);
void cm_library_destroy(int64_t libPtr);
int64_t cm_compile_function(int64_t libPtr, const char *entryPointUtf8, int32_t hasConst,
                            int32_t constId, int32_t constVal, char *errBuf, int32_t errBufSize);
void cm_function_destroy(int64_t fnPtr);

int64_t cm_render_pipeline_create(int64_t ctxPtr, int64_t vsFnPtr, int64_t fsFnPtr,
                                  const CMVertexBufferDesc *vtxBufs, int32_t vtxBufCount,
                                  const CMAttribBindingDesc *attribs, int32_t attribCount,
                                  const CMColorAttachmentDesc *colors, int32_t colorCount,
                                  int32_t depthFormat, int32_t topology, int32_t polygonMode,
                                  int32_t cullEnabled, int32_t depthTestEnabled,
                                  int32_t depthCompare, int32_t depthWrite,
                                  float depthBiasSlope, float depthBiasConst,
                                  const char *labelUtf8, char *errBuf, int32_t errBufSize);
void cm_pipeline_destroy(int64_t ctxPtr, int64_t pipePtr);
int64_t cm_compute_pipeline_create(int64_t ctxPtr, int64_t csFnPtr, const char *labelUtf8,
                                   char *errBuf, int32_t errBufSize);
void cm_compute_pipeline_destroy(int64_t ctxPtr, int64_t pipePtr);

// Command encoding & submission
void cm_cmd_begin(int64_t ctxPtr);
int32_t cm_cmd_has_active(int64_t ctxPtr);
uint64_t cm_cmd_submit(int64_t ctxPtr, int32_t maxInFlight);
int32_t cm_wait_submit(int64_t ctxPtr, uint64_t serial, uint64_t timeoutNs);

void cm_blit_clear_color(int64_t ctxPtr, int64_t texPtr, float r, float g, float b, float a);
void cm_blit_clear_depth(int64_t ctxPtr, int64_t texPtr, double depth);
void cm_blit_clear_color_depth(int64_t ctxPtr, int64_t colorTexPtr, float r, float g, float b, float a,
                               int64_t depthTexPtr, double depth);
void cm_blit_copy_buffer(int64_t ctxPtr, int64_t srcBuf, int64_t srcOff, int64_t dstBuf, int64_t dstOff, int64_t size);
void cm_blit_write_texture(int64_t ctxPtr, int64_t texPtr, const void *srcData, int64_t dataSize,
                           int32_t rowStride, int32_t mip, int32_t slice,
                           int32_t x, int32_t y, int32_t w, int32_t h);
void cm_blit_copy_buffer_to_texture(int64_t ctxPtr, int64_t srcBuf, int64_t srcOff, int32_t srcRowBytes,
                                    int64_t dstTex, int32_t mip, int32_t slice,
                                    int32_t dstX, int32_t dstY, int32_t w, int32_t h);
void cm_blit_copy_texture_to_buffer(int64_t ctxPtr, int64_t srcTex, int32_t mip, int32_t slice,
                                    int32_t srcX, int32_t srcY, int32_t w, int32_t h,
                                    int64_t dstBuf, int64_t dstOff, int32_t dstRowBytes);
void cm_blit_copy_texture(int64_t ctxPtr, int64_t srcTex, int32_t srcMip, int32_t srcSlice,
                          int32_t srcX, int32_t srcY, int64_t dstTex, int32_t dstMip, int32_t dstSlice,
                          int32_t dstX, int32_t dstY, int32_t w, int32_t h);

// Render pass
int32_t cm_pass_begin(int64_t ctxPtr,
                      const int64_t *colorViewPtrs, const int32_t *colorHasClear, const float *colorClearsRGBA,
                      int32_t colorCount,
                      int64_t depthViewPtr, int32_t depthHasClear, double depthClear,
                      int32_t areaX, int32_t areaY, int32_t areaW, int32_t areaH,
                      const char *labelUtf8);
// Hard end: always ends the open render encoder (flushes deferred clears too).
void cm_pass_end(int64_t ctxPtr);
// Soft end used by RenderPearl: keeps the encoder open so an immediately following pass on the
// same attachments without clears can merge into it. Any other GPU work hard-ends it first.
void cm_pass_finish(int64_t ctxPtr);
void cm_pass_set_pipeline(int64_t ctxPtr, int64_t pipePtr);
void cm_pass_set_scissor(int64_t ctxPtr, int32_t enabled, int32_t x, int32_t y, int32_t w, int32_t h);
void cm_pass_set_uniform_buffer(int64_t ctxPtr, int32_t slot, int64_t bufPtr, int64_t offset);
void cm_pass_set_texture_sampler(int64_t ctxPtr, int32_t texSlot, int64_t texViewPtr,
                                 int32_t sampSlot, int64_t sampPtr);
void cm_pass_push_constants(int64_t ctxPtr, int32_t slot, const void *data, int32_t size);
void cm_pass_set_vertex_buffer(int64_t ctxPtr, int32_t slot, int64_t bufPtr, int64_t offset, int32_t stride);
void cm_pass_set_index_buffer(int64_t ctxPtr, int64_t bufPtr, int32_t isInt32);
void cm_pass_draw(int64_t ctxPtr, int32_t topology, int32_t vertexCount, int32_t instanceCount,
                  int32_t firstVertex, int32_t firstInstance);
void cm_pass_draw_indexed(int64_t ctxPtr, int32_t topology, int64_t indexBufOffset,
                          int32_t indexCount, int32_t instanceCount,
                          int32_t baseVertex, int32_t firstIndex, int32_t firstInstance);
void cm_pass_multi_draw(int64_t ctxPtr, int32_t topology, const int32_t *firstVertices,
                        const int32_t *vertexCounts, int32_t count, int32_t instanceCount, int32_t firstInstance);
void cm_pass_multi_draw_indexed(int64_t ctxPtr, int32_t topology,
                                const int64_t *indexOffsetsBytes, const int32_t *indexCounts,
                                const int32_t *baseVertices, int32_t count,
                                int32_t instanceCount, int32_t firstInstance);
// Packed multi-draw variants that read RenderPearl's interleaved command arrays directly (zero copy):
//   cmds = { uint32 firstVertex, uint32 vertexCount } x count
void cm_pass_multi_draw_packed(int64_t ctxPtr, int32_t topology, const uint32_t *cmds, int32_t count,
                               int32_t instanceCount, int32_t firstInstance);
//   cmds = { uint32 firstIndex, uint32 indexCount, int32 vertexOffset } x count; indexBaseOffset in bytes
void cm_pass_multi_draw_indexed_packed(int64_t ctxPtr, int32_t topology, const uint32_t *cmds, int32_t count,
                                       int64_t indexBaseOffset, int32_t instanceCount, int32_t firstInstance);
void cm_pass_draw_indirect(int64_t ctxPtr, int32_t topology, int64_t indirectBufPtr, int64_t offset,
                           int32_t count, int32_t stride, int32_t indexed);

// Surface / Presentation
int64_t cm_surface_create(int64_t ctxPtr, int64_t caMetalLayerPtr, int32_t hdrEnabled);
void cm_surface_destroy(int64_t ctxPtr, int64_t surfPtr);
void cm_surface_configure(int64_t surfPtr, int32_t width, int32_t height, int32_t vsync, int32_t hdrEnabled);
int32_t cm_surface_acquire(int64_t surfPtr);
void cm_surface_blit_and_present(int64_t ctxPtr, int64_t surfPtr, int64_t srcTexViewPtr, int32_t maxInFlight);
// Non-blocking presentation with VSync off (default on). The render thread never waits for a drawable: each frame is
// rendered into a present slot and a present queue shows the newest finished frame (MAILBOX semantics, no tearing).
void cm_surface_set_nonblocking(int64_t surfPtr, int32_t enabled);

// MetalFX Upscaling
int64_t cm_upscaler_create(int64_t ctxPtr, int32_t temporal, int32_t colorFmt, int32_t outputFmt,
                           int32_t inW, int32_t inH, int32_t outW, int32_t outH, int32_t hdrMode);
void cm_upscaler_destroy(int64_t ctxPtr, int64_t upscalerPtr);
// Upscales the whole of srcTex into the whole of dstTex (world render scale). mode 0 = bilinear, 1 = MetalFX Spatial
// (falls back to bilinear when MetalFX is unavailable). Returns the mode actually used, or -1 on bad arguments.
int32_t cm_upscale_to(int64_t ctxPtr, int64_t srcTexPtr, int64_t dstTexPtr, int32_t mode);
void cm_upscaler_encode(int64_t ctxPtr, int64_t upscalerPtr, int64_t colorTexPtr,
                        int64_t depthTexPtr, int64_t motionTexPtr, int64_t outTexPtr,
                        float jitterX, float jitterY, int32_t resetHistory);

// Native Shader Runtime helpers (compute dispatch + fullscreen triangle pass)
void cm_compute_dispatch(int64_t ctxPtr, int64_t computePipePtr,
                         const int64_t *bufPtrs, const int64_t *bufOffsets, int32_t bufCount,
                         const int64_t *texPtrs, int32_t texCount,
                         const int64_t *sampPtrs, int32_t sampCount,
                         int32_t gx, int32_t gy, int32_t gz,
                         int32_t tx, int32_t ty, int32_t tz);

// Global shader-suite bindings & fullscreen post passes (P1+)
void cm_shade_set_enabled(int64_t ctxPtr, int32_t enabled);
void cm_shade_set_globals(int64_t ctxPtr,
                          int64_t frameBufPtr, int64_t frameOffset,
                          int64_t lookBufPtr, int64_t lookOffset,
                          int64_t gpuBufPtr, int64_t gpuOffset,
                          int64_t resBufPtr, int64_t resOffset,
                          int64_t shadowTexPtr, int64_t skyLutTexPtr,
                          int64_t shadowSampPtr, int64_t linearSampPtr);
void cm_shade_set_resource(int64_t ctxPtr, int32_t slot, int64_t texPtr);
void cm_shade_fullscreen_pass(int64_t ctxPtr, int64_t psoPtr, int64_t colorTexPtr,
                              const int64_t *texPtrs, int32_t texCount,
                              const int64_t *sampPtrs, int32_t sampCount,
                              const void *pushData, int32_t pushBytes);
void cm_shade_exposure_run(int64_t ctxPtr,
                           int64_t histComputePsoPtr, int64_t expComputePsoPtr,
                           int64_t srcTexPtr, int64_t gpuBufPtr, int64_t gpuOffset,
                           int64_t lookBufPtr, int64_t lookOffset,
                           int32_t gx, int32_t gy);

// Sun/moon shadow depth passes (P2+)
void cm_shadow_render_sodium(int64_t ctxPtr, int64_t shadowTexPtr, int32_t layer, int32_t resolution,
                             int64_t solidPsoPtr, int64_t cutoutPsoPtr,
                             const void *cascadeData, int32_t cascadeBytes,
                             int64_t chunksBufPtr, int64_t chunksOffset,
                             int64_t regionsBufPtr, int64_t regionsOffset,
                             const void *draws, int32_t drawCount,
                             int64_t atlasTexPtr, int64_t atlasSampPtr,
                             float slopeScale, float clamp, int32_t loadExisting);

void cm_shadow_render_vanilla(int64_t ctxPtr, int64_t shadowTexPtr, int32_t layer, int32_t resolution,
                              int64_t solidPsoPtr, int64_t cutoutPsoPtr,
                              const void *cascadeData, int32_t cascadeBytes,
                              const void *draws, int32_t drawCount,
                              int64_t atlasTexPtr, int64_t atlasSampPtr,
                              float slopeScale, float clamp, int32_t loadExisting);

// Water scene copy, depth pyramid & wave mipmap generation (P3a+, cm_water.m)
void cm_water_set_params(int64_t ctxPtr, int64_t paramsBufPtr, int64_t paramsOffset,
                         int64_t wavesTexPtr, int64_t detailTexPtr, int32_t enabled);
void cm_water_generate_mipmaps(int64_t ctxPtr, int64_t wavesPtr, int64_t detailPtr, int64_t swellPtr);
int32_t cm_water_capture(int64_t ctxPtr, int64_t pyrPsoPtr, int64_t pyr2PsoPtr);
void cm_blit_copy_texture_full(int64_t ctxPtr, int64_t srcTexPtr, int64_t dstTexPtr);

// Dynamic lights (P6a, cm_dynlight.m; adapted from Metal Shaders' mcdynlight.m). Kernels come from MSL source
// (dynlight.metal with SHADE_DL_KERNELS + dynlight_vis.metal). Returns a state handle, or 0 with the message in err.
int64_t cm_dl_new(int64_t ctxPtr, const char *source, int32_t bytes, int32_t ring, int32_t slabs, int32_t occBytes,
                  int32_t irrW, int32_t irrH, int32_t irrD, char *err, int32_t errCap);
void cm_dl_free(int64_t ctxPtr, int64_t statePtr);
int64_t cm_dl_contents(int64_t statePtr, int32_t slot);
void cm_dl_occupancy(int64_t statePtr, const void *src);
int32_t cm_dl_fallback(int64_t ctxPtr, int32_t bytes);
void cm_dl_slot(int64_t statePtr, int32_t slot);
int32_t cm_dl_has_flood(int64_t statePtr);
void cm_dl_vis(int64_t ctxPtr, int64_t statePtr, const void *params, int32_t length, int32_t volumes);
void cm_dl_irr(int64_t ctxPtr, int64_t statePtr, int32_t x0, int32_t y0, int32_t z0, int32_t w, int32_t h, int32_t d);

// P6b coloured block light (cm_colorlight.m; shaders/ported/colorlight.metal): buffer 30 header, textures 26 / 27 volumes.
int64_t cm_cl_new(int64_t ctxPtr, const char *source, int32_t fw, int32_t fh, int32_t fd, int32_t cw, int32_t ch, int32_t cd,
                  int64_t cells, int32_t listCap, int32_t ring, char *err, int32_t errCap);
void cm_cl_free(int64_t ctxPtr, int64_t statePtr);
int32_t cm_cl_fallback(int64_t ctxPtr);
int64_t cm_cl_ids(int64_t statePtr);
int64_t cm_cl_levels(int64_t statePtr);
int64_t cm_cl_list(int64_t statePtr, int32_t slot);
void cm_cl_header(int64_t statePtr, int32_t slot, const void *bytes);
void cm_cl_frame(int64_t ctxPtr, int64_t statePtr, int32_t slot, int32_t clears, int32_t fine, int32_t coarse, int32_t fineSteps,
                 int32_t uploadOffset, int32_t uploads);

#ifdef __cplusplus
}
#endif

#endif // CELESTIA_METAL_H
