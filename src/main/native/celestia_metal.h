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

#define CM_ABI_VERSION 3
#define CM_MAX_COLOR_ATTACHMENTS 8
#define CM_MAX_VERTEX_BUFFERS 8
#define CM_MAX_UNIFORM_BUFFERS 15
#define CM_PUSH_CONSTANT_SLOT 15
#define CM_VERTEX_BUFFER_BASE 16
#define CM_MAX_TEXTURES 31
#define CM_MAX_SAMPLERS 16
#define CM_INFLIGHT_SLOTS 4
#define CM_MAX_PENDING_CLEARS 8

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
    CM_STAT_COUNT = 10,
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

#ifdef __cplusplus
}
#endif

#endif // CELESTIA_METAL_H
