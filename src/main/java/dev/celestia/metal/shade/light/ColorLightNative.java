// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/light/DynLightNative.java (cl*)
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
 * Downcalls into native/cm_colorlight.m. Every GPU call takes the device context ({@code CelestiaMetalDevice.handle()}) and
 * encodes on the frame's recording command buffer; binding is automatic (cm_shade_bind_render_encoder).
 */
final class ColorLightNative {
    private static final MethodHandle NEW = MetalNative.shadeDowncall("cm_cl_new", FunctionDescriptor.of(JAVA_LONG,
        JAVA_LONG, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_LONG, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));
    private static final MethodHandle FREE = MetalNative.shadeDowncall("cm_cl_free", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG));
    private static final MethodHandle FALLBACK = MetalNative.shadeDowncall("cm_cl_fallback", FunctionDescriptor.of(JAVA_INT, JAVA_LONG));
    private static final MethodHandle IDS = MetalNative.shadeDowncall("cm_cl_ids", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG));
    private static final MethodHandle LIST = MetalNative.shadeDowncall("cm_cl_list", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG, JAVA_INT));
    private static final MethodHandle HEADER = MetalNative.shadeDowncall("cm_cl_header", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_INT, ADDRESS));
    private static final MethodHandle FRAME = MetalNative.shadeDowncall("cm_cl_frame", FunctionDescriptor.ofVoid(JAVA_LONG, JAVA_LONG,
        JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT));
    private static final MethodHandle LEVELS = MetalNative.shadeDowncall("cm_cl_levels", FunctionDescriptor.of(JAVA_LONG, JAVA_LONG));

    private ColorLightNative() {
    }

    private static RuntimeException rethrow(Throwable t) {
        if (t instanceof RuntimeException r) return r;
        if (t instanceof Error e) throw e;
        return new IllegalStateException(t);
    }

    private static MemorySegment addr(long address) {
        return address == 0L ? MemorySegment.NULL : MemorySegment.ofAddress(address);
    }

    static long create(long ctx, long source, int fw, int fh, int fd, int cw, int ch, int cd, long cells, int listCap, int ring,
                       long err, int errCap) {
        try {
            return (long) NEW.invokeExact(ctx, addr(source), fw, fh, fd, cw, ch, cd, cells, listCap, ring, addr(err), errCap);
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

    /** 1-texel volumes and a zeroed header for the module's slots (module off or failed); false when even those failed. */
    static boolean fallback(long ctx) {
        try {
            return (int) FALLBACK.invokeExact(ctx) != 0;
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** The shared block-id buffer (the CPU writes a section's 4096 bytes in place). */
    static long ids(long state) {
        try {
            return (long) IDS.invokeExact(state);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** Ring slot {@code slot}'s list buffer (clears first, then the fine and coarse slots to spread). */
    static long list(long state, int slot) {
        try {
            return (long) LIST.invokeExact(state, slot);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** This frame's 80-byte ShadeColorLights header into ring slot {@code slot}, bound from now on. */
    static void header(long state, int slot, long bytes) {
        try {
            HEADER.invokeExact(state, slot, addr(bytes));
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    /** The shared smooth-block-light buffer: 2 bytes a fine cell, a fine slot's 4096 cells at slot x 8192. */
    static long levels(long state) {
        try {
            return (long) LEVELS.invokeExact(state);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }

    static void frame(long ctx, long state, int slot, int clears, int fine, int coarse, int fineSteps, int uploadOffset, int uploads) {
        try {
            FRAME.invokeExact(ctx, state, slot, clears, fine, coarse, fineSteps, uploadOffset, uploads);
        } catch (Throwable t) {
            throw rethrow(t);
        }
    }
}
