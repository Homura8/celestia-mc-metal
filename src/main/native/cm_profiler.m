// Opt-in Metal 4 GPU pass profiler (CELESTIA_GPU_PROFILE=1 in the environment; off otherwise, with no code path changed).
//
// Every encoder a Metal 4 command buffer opens is preceded by a command-buffer timestamp (writeTimestampIntoHeap: "after all
// prior work completes"), and cm_cmd_submit writes a last one before endCommandBuffer, so consecutive timestamps bracket each
// encoder. The encoder creation methods are swizzled on the concrete MTL4CommandBuffer class the first time a profiled command
// buffer begins (no call site changes). Each submit's heap slot is resolved in its commit feedback handler (the GPU is done
// then), durations are summed per encoder label, and every CELESTIA_GPU_PROFILE_EVERY submits (240) the averages are printed:
//   [GPU] 12.34 ms/frame | 4.10 Celestia.Water | 2.00 minecraft:main ...
// Labels need ctx.debugLabels (forced on while profiling). Merged render passes (cm_pass_finish soft end) count as one encoder:
// set -Dcelestiametal.noPassMerge=true for a per-pass split. Metal 3 is not profiled.
#import "celestia_metal.h"
#import <objc/runtime.h>
#include <stdlib.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

#define PROF_SLOTS 8
#define PROF_MAX 1024

typedef struct {
    __unsafe_unretained id cb;     // the command buffer this slot belongs to (identity only)
    uint32_t count;                // timestamps written
    BOOL busy;
} ProfSlot;

static BOOL profOn;
static id profHeaps[PROF_SLOTS];
static ProfSlot profSlots[PROF_SLOTS];
static NSMutableArray *profEncoders[PROF_SLOTS]; // per slot: the encoder each interval belongs to (index i: timestamps i..i+1)
static int profNext;
static double profTicksToMs;
static NSMutableDictionary<NSString *, NSNumber *> *profSums;
static double profFrameSum;
static int profFrames, profEvery;
static NSLock *profLock;
static IMP profOrigRender, profOrigRenderOpts, profOrigCompute;

static int prof_slot_of(id cb) {
    for (int i = 0; i < PROF_SLOTS; i++) if (profSlots[i].busy && profSlots[i].cb == cb) return i;
    return -1;
}

static void prof_stamp(id cb, id encoderOrNil) {
    int s = prof_slot_of(cb);
    if (s < 0 || profSlots[s].count >= PROF_MAX) return;
    [(id<MTL4CommandBuffer>)cb writeTimestampIntoHeap:(id<MTL4CounterHeap>)profHeaps[s] atIndex:profSlots[s].count];
    profSlots[s].count++;
    [profEncoders[s] addObject:encoderOrNil ?: [NSNull null]];
}

static id prof_render(id self, SEL _cmd, id desc) {
    prof_stamp(self, nil);
    id enc = ((id (*)(id, SEL, id))profOrigRender)(self, _cmd, desc);
    int s = prof_slot_of(self);
    if (s >= 0 && profEncoders[s].count) profEncoders[s][profEncoders[s].count - 1] = enc ?: [NSNull null];
    return enc;
}

static id prof_render_opts(id self, SEL _cmd, id desc, NSUInteger opts) {
    prof_stamp(self, nil);
    id enc = ((id (*)(id, SEL, id, NSUInteger))profOrigRenderOpts)(self, _cmd, desc, opts);
    int s = prof_slot_of(self);
    if (s >= 0 && profEncoders[s].count) profEncoders[s][profEncoders[s].count - 1] = enc ?: [NSNull null];
    return enc;
}

static id prof_compute(id self, SEL _cmd) {
    prof_stamp(self, nil);
    id enc = ((id (*)(id, SEL))profOrigCompute)(self, _cmd);
    int s = prof_slot_of(self);
    if (s >= 0 && profEncoders[s].count) profEncoders[s][profEncoders[s].count - 1] = enc ?: [NSNull null];
    return enc;
}

static void prof_swizzle(Class c) {
    Method m = class_getInstanceMethod(c, @selector(renderCommandEncoderWithDescriptor:));
    if (m) profOrigRender = method_setImplementation(m, (IMP)prof_render);
    m = class_getInstanceMethod(c, @selector(renderCommandEncoderWithDescriptor:options:));
    if (m) profOrigRenderOpts = method_setImplementation(m, (IMP)prof_render_opts);
    m = class_getInstanceMethod(c, @selector(computeCommandEncoder));
    if (m) profOrigCompute = method_setImplementation(m, (IMP)prof_compute);
}

void cm_prof_init(CMContext *ctx) {
    const char *on = getenv("CELESTIA_GPU_PROFILE");
    if (!on || on[0] != '1' || !ctx.metal4Active) return;
    if (@available(macOS 26.0, *)) {
        MTL4CounterHeapDescriptor *d = [MTL4CounterHeapDescriptor new];
        d.type = MTL4CounterHeapTypeTimestamp;
        d.count = PROF_MAX;
        for (int i = 0; i < PROF_SLOTS; i++) {
            NSError *e = nil;
            profHeaps[i] = [ctx.device newCounterHeapWithDescriptor:d error:&e];
            if (!profHeaps[i]) {
                fprintf(stderr, "[GPU] profiler off: counter heap: %s\n", e.localizedDescription.UTF8String ?: "?");
                return;
            }
            profEncoders[i] = [NSMutableArray array];
        }
        uint64_t hz = [ctx.device queryTimestampFrequency];
        profTicksToMs = hz ? 1000.0 / (double)hz : 1e-6;
        profSums = [NSMutableDictionary dictionary];
        profLock = [NSLock new];
        const char *every = getenv("CELESTIA_GPU_PROFILE_EVERY");
        profEvery = every ? MAX(atoi(every), 10) : 240;
        ctx.debugLabels = YES;
        profOn = YES;
        fprintf(stderr, "[GPU] profiler on (%d submits per report, %.3f ns per tick)\n", profEvery, profTicksToMs * 1e6);
    }
}

// A profiled command buffer just began (cm_ensure_cmd_begun).
void cm_prof_begin(id cb) {
    if (!profOn || !cb) return;
    static BOOL swizzled;
    if (!swizzled) {
        prof_swizzle(object_getClass(cb));
        swizzled = YES;
    }
    [profLock lock];
    int s = profNext;
    profNext = (profNext + 1) % PROF_SLOTS;
    BOOL free = !profSlots[s].busy;
    [profLock unlock];
    if (!free) return; // (all slots in flight: this buffer goes unprofiled)
    profSlots[s].cb = cb;
    profSlots[s].count = 0;
    profSlots[s].busy = YES;
    [profEncoders[s] removeAllObjects];
}

// Before endCommandBuffer: the closing timestamp. Returns the slot (or -1) for cm_prof_done.
int cm_prof_end(id cb) {
    if (!profOn) return -1;
    prof_stamp(cb, nil);
    return prof_slot_of(cb);
}

// The command buffer completed (commit feedback handler): durations per encoder label.
void cm_prof_done(int s) {
    if (!profOn || s < 0 || s >= PROF_SLOTS) return;
    if (@available(macOS 26.0, *)) {
        uint32_t n = profSlots[s].count;
        NSData *data = n > 1 ? [(id<MTL4CounterHeap>)profHeaps[s] resolveCounterRange:NSMakeRange(0, n)] : nil;
        const uint64_t *ts = (const uint64_t *)data.bytes;
        [profLock lock];
        if (ts && data.length >= n * sizeof(uint64_t)) {
            double frame = 0.0;
            for (uint32_t i = 0; i + 1 < n; i++) {
                if (ts[i + 1] < ts[i] || ts[i] == 0) continue;
                double ms = (double)(ts[i + 1] - ts[i]) * profTicksToMs;
                id enc = profEncoders[s][i];
                NSString *label = (enc != [NSNull null] && [enc respondsToSelector:@selector(label)]) ? [enc label] : nil;
                // (unlabelled encoders: name the encoder class, render / compute / blit, so the time is at least placed)
                if (!label.length) label = i == 0 ? @"(start)"
                    : enc != [NSNull null] ? [NSString stringWithFormat:@"(unlabelled %@)", NSStringFromClass([enc class])] : @"(unlabelled)";
                profSums[label] = @(profSums[label].doubleValue + ms);
                frame += ms;
            }
            profFrameSum += frame;
            profFrames++;
        }
        profSlots[s].busy = NO;
        if (profFrames >= profEvery) {
            NSArray *keys = [profSums keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                return [b compare:a];
            }];
            NSMutableString *line = [NSMutableString stringWithFormat:@"[GPU] %.2f ms/submit over %d |", profFrameSum / profFrames, profFrames];
            for (NSString *k in keys) {
                double avg = profSums[k].doubleValue / profFrames;
                if (avg < 0.05) break;
                [line appendFormat:@" %.2f %@ |", avg, k];
            }
            fprintf(stderr, "%s\n", line.UTF8String);
            [profSums removeAllObjects];
            profFrameSum = 0.0;
            profFrames = 0;
        }
        [profLock unlock];
    }
}
