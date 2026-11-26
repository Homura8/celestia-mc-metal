#import "celestia_metal.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@implementation CMRetiredEntry
@end

@implementation CMShaderPass
@end

@implementation CMContext
@end

static os_unfair_lock g_residencyLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock g_retireLock = OS_UNFAIR_LOCK_INIT;

int32_t cm_abi_version(void) {
    return CM_ABI_VERSION;
}

void cm_record_error(CMContext *ctx, NSString *msg) {
    if (!ctx || !msg) return;
    @synchronized(ctx.errors) {
        if (ctx.errors.count < 64) {
            [ctx.errors addObject:msg];
        }
    }
    int32_t prev = atomic_fetch_add(&ctx->_errorCount, 1);
    if (prev < 32 && msg.UTF8String) {
        fprintf(stderr, "[CelestiaMetal GPU Error] %s\n", msg.UTF8String);
        fflush(stderr);
    }
}

void cm_track_allocation(CMContext *ctx, id allocation) {
    if (!ctx || !ctx.metal4Active || !allocation) return;
    if (![allocation conformsToProtocol:@protocol(MTLAllocation)]) return;
    os_unfair_lock_lock(&g_residencyLock);
    id<MTLResidencySet> rs = (id<MTLResidencySet>)ctx.residencySet;
    if (rs) {
        [rs addAllocation:(id<MTLAllocation>)allocation];
        ctx.residencyDirty = YES;
    }
    os_unfair_lock_unlock(&g_residencyLock);
}

void cm_untrack_allocation(CMContext *ctx, id allocation) {
    if (!ctx || !ctx.metal4Active || !allocation) return;
    if (![allocation conformsToProtocol:@protocol(MTLAllocation)]) return;
    os_unfair_lock_lock(&g_residencyLock);
    id<MTLResidencySet> rs = (id<MTLResidencySet>)ctx.residencySet;
    if (rs) {
        [rs removeAllocation:(id<MTLAllocation>)allocation];
        ctx.residencyDirty = YES;
    }
    os_unfair_lock_unlock(&g_residencyLock);
}

void cm_commit_residency_if_dirty(CMContext *ctx) {
    if (!ctx || !ctx.metal4Active) return;
    os_unfair_lock_lock(&g_residencyLock);
    if (ctx.residencyDirty && ctx.residencySet) {
        id<MTLResidencySet> rs = (id<MTLResidencySet>)ctx.residencySet;
        [rs commit];
        ctx.residencyDirty = NO;
    }
    os_unfair_lock_unlock(&g_residencyLock);
}

void cm_retire_object(CMContext *ctx, id obj, uint64_t serial) {
    if (!ctx || !obj) return;
    CMRetiredEntry *entry = [CMRetiredEntry new];
    entry.object = obj;
    entry.retireSerial = serial;
    os_unfair_lock_lock(&g_retireLock);
    [ctx.retired addObject:entry];
    os_unfair_lock_unlock(&g_retireLock);
}

void cm_drain_retired(CMContext *ctx) {
    if (!ctx) return;
    uint64_t done = atomic_load(&ctx->_completedSubmitSerial);
    NSMutableArray<CMRetiredEntry *> *toRelease = nil;
    os_unfair_lock_lock(&g_retireLock);
    if (ctx.retired.count > 0) {
        NSUInteger keepIdx = 0;
        for (NSUInteger i = 0; i < ctx.retired.count; i++) {
            CMRetiredEntry *e = ctx.retired[i];
            if (e.retireSerial <= done) {
                if (!toRelease) toRelease = [NSMutableArray array];
                [toRelease addObject:e];
            } else {
                if (keepIdx != i) ctx.retired[keepIdx] = e;
                keepIdx++;
            }
        }
        if (keepIdx < ctx.retired.count) {
            [ctx.retired removeObjectsInRange:NSMakeRange(keepIdx, ctx.retired.count - keepIdx)];
        }
    }
    os_unfair_lock_unlock(&g_retireLock);

    if (toRelease.count > 0 && ctx.metal4Active) {
        for (CMRetiredEntry *e in toRelease) {
            cm_untrack_allocation(ctx, e.object);
        }
    }
    // toRelease drains automatically via ARC outside lock
}

static int detect_apple_family(id<MTLDevice> dev) {
    if (@available(macOS 15.0, *)) {
        if ([dev supportsFamily:MTLGPUFamilyApple10]) return 10;
    }
    if (@available(macOS 14.0, *)) {
        if ([dev supportsFamily:MTLGPUFamilyApple9]) return 9;
    }
    if ([dev supportsFamily:MTLGPUFamilyApple8]) return 8;
    if ([dev supportsFamily:MTLGPUFamilyApple7]) return 7;
    return 0;
}

static BOOL device_supports_metal4(id<MTLDevice> dev) {
    if (@available(macOS 26.0, *)) {
        return [dev supportsFamily:MTLGPUFamilyMetal4]
            && [dev respondsToSelector:@selector(newMTL4CommandQueue)]
            && [dev respondsToSelector:@selector(newCompilerWithDescriptor:error:)];
    }
    return NO;
}

void cm_query_system_telemetry(int32_t *outThermalState, int32_t *outLowPowerMode,
                               int32_t *outRefreshHz, float *outEdrHeadroom) {
    @autoreleasepool {
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        if (outThermalState) *outThermalState = (int32_t)[pi thermalState];
        if (outLowPowerMode) *outLowPowerMode = [pi isLowPowerModeEnabled] ? 1 : 0;

        __block int32_t hz = 60;
        __block float edr = 1.0f;
        void (^queryBlock)(void) = ^{
            NSScreen *scr = [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
            if (scr) {
                if (@available(macOS 12.0, *)) {
                    NSInteger maxFps = scr.maximumFramesPerSecond;
                    if (maxFps > 0) hz = (int32_t)maxFps;
                }
                if (@available(macOS 10.15, *)) {
                    edr = (float)scr.maximumPotentialExtendedDynamicRangeColorComponentValue;
                    if (edr < 1.0f) edr = 1.0f;
                }
            }
        };
        if ([NSThread isMainThread]) {
            queryBlock();
        } else {
            // Avoid blocking on main queue if main thread is busy; NSScreen properties are safe on mainScreen cache or quick fallback
            queryBlock();
        }
        if (outRefreshHz) *outRefreshHz = hz;
        if (outEdrHeadroom) *outEdrHeadroom = edr;
    }
}

void cm_probe_device(CMProbeInfo *outInfo) {
    if (!outInfo) return;
    memset(outInfo, 0, sizeof(*outInfo));
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            strlcpy(outInfo->unsupportedReason, "No Metal GPU device found", sizeof(outInfo->unsupportedReason));
            return;
        }
        int fam = detect_apple_family(dev);
        outInfo->appleGpuFamily = fam;
        strlcpy(outInfo->gpuName, dev.name.UTF8String ?: "Apple GPU", sizeof(outInfo->gpuName));
        if (fam < 7) {
            strlcpy(outInfo->unsupportedReason, "Apple Silicon GPU (Apple7+) is required", sizeof(outInfo->unsupportedReason));
            return;
        }
        outInfo->supported = 1;
        outInfo->metal4Supported = device_supports_metal4(dev) ? 1 : 0;
        outInfo->maxTextureSize = 16384;
        outInfo->maxAnisotropy = 16;
        outInfo->recommendedMaxWorkingSetBytes = (uint64_t)dev.recommendedMaxWorkingSetSize;
        cm_query_system_telemetry(&outInfo->thermalState, &outInfo->lowPowerMode,
                                  &outInfo->maxRefreshRateHz, &outInfo->edrHeadroom);
    }
}

int64_t cm_device_create(int32_t preferMetal4, int32_t debugLabels, const char *archivePathUtf8) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || detect_apple_family(dev) < 7) return 0;

        CMContext *ctx = [CMContext new];
        ctx.device = dev;
        ctx.debugLabels = debugLabels != 0;
        ctx.appleGpuFamily = detect_apple_family(dev);
        ctx.retired = [NSMutableArray array];
        ctx.errors = [NSMutableArray array];
        ctx.depthStateCache = [NSMutableDictionary dictionary];
        atomic_init(&ctx->_nextSubmitSerial, 0);
        atomic_init(&ctx->_completedSubmitSerial, 0);
        atomic_init(&ctx->_lastGpuFrameNs, 0);
        atomic_init(&ctx->_deviceLost, 0);
        atomic_init(&ctx->_errorCount, 0);
        ctx.inflightSem = dispatch_semaphore_create(CM_INFLIGHT_SLOTS);
        ctx.submitEvent = [dev newSharedEvent];
        ctx.m3Queue = [dev newCommandQueue];
        if (!ctx.m3Queue) return 0;
        ctx.m3Queue.label = @"CelestiaMetal.M3Queue";

        // 2 MB shared ring buffer for Metal 4 transient push constants / argument updates
        ctx.pushRingSize = 2 * 1024 * 1024;
        ctx.pushRingBuffer = [dev newBufferWithLength:ctx.pushRingSize options:MTLResourceStorageModeShared];
        ctx.pushRingBuffer.label = @"CelestiaMetal.PushRing";

        if (archivePathUtf8 && archivePathUtf8[0] != '\0') {
            ctx.archivePath = [NSString stringWithUTF8String:archivePathUtf8];
            MTLBinaryArchiveDescriptor *archDesc = [MTLBinaryArchiveDescriptor new];
            NSURL *archUrl = [NSURL fileURLWithPath:ctx.archivePath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:ctx.archivePath]) {
                archDesc.url = archUrl;
            }
            NSError *archErr = nil;
            ctx.binaryArchive = [dev newBinaryArchiveWithDescriptor:archDesc error:&archErr];
            if (!ctx.binaryArchive && archErr) {
                archDesc.url = nil;
                ctx.binaryArchive = [dev newBinaryArchiveWithDescriptor:archDesc error:nil];
            }
        }

        if (preferMetal4 && device_supports_metal4(dev)) {
            if (@available(macOS 26.0, *)) {
                NSError *err = nil;
                MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new];
                qd.label = @"CelestiaMetal.M4Queue";
                id<MTL4CommandQueue> m4q = [dev newMTL4CommandQueueWithDescriptor:qd error:&err];
                MTL4CompilerDescriptor *compDesc = [MTL4CompilerDescriptor new];
                compDesc.label = @"CelestiaMetal.M4Compiler";
                id<MTL4Compiler> m4c = m4q ? [dev newCompilerWithDescriptor:compDesc error:&err] : nil;

                MTLResidencySetDescriptor *rsDesc = [MTLResidencySetDescriptor new];
                rsDesc.label = @"CelestiaMetal.ResidencySet";
                rsDesc.initialCapacity = 512;
                id<MTLResidencySet> rs = (m4q && m4c) ? [dev newResidencySetWithDescriptor:rsDesc error:&err] : nil;

                if (m4q && m4c && rs) {
                    NSMutableArray *allocs = [NSMutableArray arrayWithCapacity:CM_INFLIGHT_SLOTS];
                    BOOL allocOk = YES;
                    for (int i = 0; i < CM_INFLIGHT_SLOTS; i++) {
                        MTL4CommandAllocatorDescriptor *ad = [MTL4CommandAllocatorDescriptor new];
                        ad.label = [NSString stringWithFormat:@"CelestiaMetal.Allocator.%d", i];
                        id<MTL4CommandAllocator> ca = [dev newCommandAllocatorWithDescriptor:ad error:&err];
                        if (!ca) { allocOk = NO; break; }
                        [allocs addObject:ca];
                    }

                    MTL4ArgumentTableDescriptor *atDesc = [MTL4ArgumentTableDescriptor new];
                    atDesc.maxBufferBindCount = 31;
                    atDesc.maxTextureBindCount = 32;
                    atDesc.maxSamplerStateBindCount = 16;
                    atDesc.initializeBindings = YES;
                    atDesc.supportAttributeStrides = NO;
                    atDesc.label = @"CelestiaMetal.VertexArgs";
                    id<MTL4ArgumentTable> vArgs = [dev newArgumentTableWithDescriptor:atDesc error:&err];
                    atDesc.label = @"CelestiaMetal.FragmentArgs";
                    atDesc.supportAttributeStrides = NO;
                    id<MTL4ArgumentTable> fArgs = [dev newArgumentTableWithDescriptor:atDesc error:&err];

                    if (allocOk && vArgs && fArgs) {
                        [m4q addResidencySet:rs];
                        [rs addAllocation:ctx.pushRingBuffer];
                        [rs commit];

                        ctx.m4Queue = m4q;
                        ctx.m4Compiler = m4c;
                        ctx.residencySet = rs;
                        ctx.m4Allocators = allocs;
                        ctx.m4VertexArgTable = vArgs;
                        ctx.m4FragmentArgTable = fArgs;
                        ctx.metal4Active = YES;
                    }
                }
            }
        }

        return (int64_t)(__bridge_retained void *)ctx;
    }
}

void cm_device_destroy(int64_t ctxPtr) {
    if (!ctxPtr) return;
    @autoreleasepool {
        CMContext *ctx = (__bridge_transfer CMContext *)(void *)ctxPtr;
        cm_device_wait_idle((int64_t)(__bridge void *)ctx);
        if (ctx.binaryArchive && ctx.archivePath) {
            NSString *dir = [ctx.archivePath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSError *err = nil;
            [ctx.binaryArchive serializeToURL:[NSURL fileURLWithPath:ctx.archivePath] error:&err];
        }
        cm_drain_retired(ctx);
        [ctx.retired removeAllObjects];
        [ctx.depthStateCache removeAllObjects];
        if (ctx.metal4Active && ctx.m4Queue && ctx.residencySet) {
            if (@available(macOS 26.0, *)) {
                [(id<MTL4CommandQueue>)ctx.m4Queue removeResidencySet:(id<MTLResidencySet>)ctx.residencySet];
            }
        }
        ctx.residencySet = nil;
        ctx.fanIndexBuffer = nil;
        ctx.fanIndexCapacity = 0;
        ctx.m4Allocators = nil;
        ctx.m4Compiler = nil;
        ctx.m4Queue = nil;
        ctx.m3Queue = nil;
        ctx.device = nil;
    }
}

int32_t cm_device_is_metal4(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return ctx.metal4Active ? 1 : 0;
}

int32_t cm_device_is_lost(int64_t ctxPtr) {
    if (!ctxPtr) return 1;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return atomic_load(&ctx->_deviceLost);
}

uint64_t cm_device_completed_submit(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return atomic_load(&ctx->_completedSubmitSerial);
}

uint64_t cm_device_next_submit(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return atomic_load(&ctx->_nextSubmitSerial);
}

uint64_t cm_device_last_gpu_ns(int64_t ctxPtr) {
    if (!ctxPtr) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    return atomic_load(&ctx->_lastGpuFrameNs);
}

int32_t cm_device_drain_errors(int64_t ctxPtr, char *buf, int32_t bufSize) {
    if (!ctxPtr || !buf || bufSize <= 0) return 0;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    NSMutableString *joined = [NSMutableString string];
    int32_t count = 0;
    @synchronized(ctx.errors) {
        count = (int32_t)ctx.errors.count;
        for (NSUInteger i = 0; i < ctx.errors.count; i++) {
            if (i > 0) [joined appendString:@"\n"];
            [joined appendString:ctx.errors[i]];
        }
        [ctx.errors removeAllObjects];
    }
    strlcpy(buf, joined.UTF8String ?: "", (size_t)bufSize);
    return count;
}

void cm_device_wait_idle(int64_t ctxPtr) {
    if (!ctxPtr) return;
    CMContext *ctx = (__bridge CMContext *)(void *)ctxPtr;
    uint64_t target = atomic_load(&ctx->_nextSubmitSerial);
    if (target > 0) {
        cm_wait_submit(ctxPtr, target, 5000000000ULL);
    }
}
