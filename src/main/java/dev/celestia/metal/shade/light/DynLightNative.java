// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/light/DynLightNative.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.light;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

import dev.celestia.metal.backend.MetalNative;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;

/**
 * Downcalls into native/cm_dynlight.m. Upstream passed an encoder handle; here every GPU call takes the device context
 * ({@code CelestiaMetalDevice.handle()}) and encodes on the frame's recording command buffer. Binding is automatic
 * (cm_shade_bind_render_encoder), so upstream's {@code mc_dl_bind} has no counterpart.
 */
final class DynLightNative {
    private static final MethodHandle NEW = MetalNative.shadeDowncall("cm_dl_new", FunctionDescriptor.of(JAVA_LONG,
        JAVA_LONG, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));
    private static final MethodHandle FREE = MetalNative.shadeDowncall("cm_dl_free", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG));
    private static final MethodHandle CONTENTS = MetalNative.shadeDowncall("cm_dl_contents", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG, JAVA_INT));
    private static final MethodHandle OCCUPANCY = MetalNative.shadeDowncall("cm_dl_occupancy", FunctionDescriptor.ofVoid(JAVA_LONG, ADDRESS));
    private static final MethodHandle FALLBACK = MetalNative.shadeDowncall("cm_dl_fallback", FunctionDescriptor.of(JAVA_INT, JAVA_LONG, JAVA_INT));
    private static final MethodHandle SLOT = MetalNative.shadeDowncall("cm_dl_slot", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_INT));
    private static final MethodHandle HAS_FLOOD = MetalNative.shadeDowncall("cm_dl_has_flood", FunctionDescriptor.of(JAVA_INT, JAVA_LONG));
    private static final MethodHandle VIS = MetalNative.shadeDowncall("cm_dl_vis", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG, ADDRESS, JAVA_INT, JAVA_INT));
    private static final MethodHandle IRR = MetalNative.shadeDowncall("cm_dl_irr", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG,
        JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT));

    private DynLightNative() {
    }

    private static RuntimeException rethrow(Throwable t) {
        if (t instanceof RuntimeException r) return r;
        if (t instanceof Error e) throw e;
        return new IllegalStateException(t);
    }

    private static MemorySegment addr(long address) {
        return address == 0L ? MemorySegment.NULL : MemorySegment.ofAddress(address);
    }

    static long create(long ctx, long source, int bytes, int ring, int slabs, int occBytes, int irrW, int irrH, int irrD, long err, int errCap) {
        try {
            return (long) NEW.invokeExact(ctx, addr(source), bytes, ring, slabs, occBytes, irrW, irrH, irrD, addr(err), errCap);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static void free(long ctx, long state) {
        try {
            FREE.invokeExact(ctx, state);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** The CPU's block occupancy (Occupancy.BYTES at address) into the next occupancy slot, read by the next vis pass. */
    static void occupancy(long state, long address) {
        try {
            OCCUPANCY.invokeExact(state, addr(address));
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** Zeroed fallback bindings for the module's slots (module off or failed); false when even those failed. */
    static boolean fallback(long ctx, int bytes) {
        try {
            return (int) FALLBACK.invokeExact(ctx, bytes) != 0;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** Ring slot i's CPU address. */
    static long contents(long state, int i) {
        try {
            return (long) CONTENTS.invokeExact(state, i);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static void slot(long state, int slot) {
        try {
            SLOT.invokeExact(state, slot);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static boolean hasFlood(long state) {
        try {
            return (int) HAS_FLOOD.invokeExact(state) != 0;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static void vis(long ctx, long state, long params, int length, int volumes) {
        try {
            VIS.invokeExact(ctx, state, addr(params), length, volumes);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static void irr(long ctx, long state, int x0, int y0, int z0, int w, int h, int d) {
        try {
            IRR.invokeExact(ctx, state, x0, y0, z0, w, h, d);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }
}
