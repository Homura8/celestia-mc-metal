package dev.celestia.metal;

import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import static org.junit.jupiter.api.Assertions.*;

@EnabledOnOs(OS.MAC)
class NativeFfmSmokeTest {

    @Test
    void probesAppleSiliconMetal4AndCompilesShaderViaFfm() {
        MetalNative.ProbeInfo probe = MetalNative.probeDevice();
        assertTrue(probe.supported(), "Expected Apple Silicon GPU support: " + probe.unsupportedReason());
        assertTrue(probe.appleGpuFamily() >= 7);
        assertFalse(probe.gpuName().isEmpty());

        long ctx = MetalNative.deviceCreate(true, true, "");
        assertNotEquals(0L, ctx);
        try {
            if (probe.metal4Supported()) {
                assertTrue(MetalNative.deviceIsMetal4(ctx));
            }
            long buf = MetalNative.bufferCreate(ctx, 1024, null, "TestBuf");
            assertNotEquals(0L, buf);
            assertNotEquals(0L, MetalNative.bufferContents(buf));
            MetalNative.bufferDestroy(ctx, buf);

            long tex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA16_FLOAT, 64, 64, 1, 1,
                false, true, true, true, "TestTex");
            assertNotEquals(0L, tex);
            MetalNative.textureDestroy(ctx, tex);

            StringBuilder err = new StringBuilder();
            long lib = MetalNative.compileMslLibrary(ctx, """
                #include <metal_stdlib>
                using namespace metal;
                kernel void test_k(texture2d<half, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
                    if (gid.x < out.get_width() && gid.y < out.get_height()) out.write(half4(1.0h, 0.5h, 0.25h, 1.0h), gid);
                }
                """, "test_k", true, err);
            assertNotEquals(0L, lib, "MSL compile error: " + err);
            long fn = MetalNative.compileFunction(lib, "test_k", false, 0, 0, err);
            assertNotEquals(0L, fn);
            long pipe = MetalNative.computePipelineCreate(ctx, fn, "test_k_pso", err);
            assertNotEquals(0L, pipe);

            MetalNative.computePipelineDestroy(ctx, pipe);
            MetalNative.functionDestroy(fn);
            MetalNative.libraryDestroy(lib);
        } finally {
            MetalNative.deviceDestroy(ctx);
        }
    }
}
