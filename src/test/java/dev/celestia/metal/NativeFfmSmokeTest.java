package dev.celestia.metal;

import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
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

    @Test
    void exercisesRenderPipelinePassDrawAndComputeViaFfm() {
        long ctx = MetalNative.deviceCreate(true, true, "");
        assertNotEquals(0L, ctx);
        long ctex = 0, cview = 0, dtex = 0, dview = 0, dstTex = 0;
        long srcBuf = 0, dstBuf = 0, vbo = 0, ibo = 0, ubo = 0, tbView = 0, samp = 0;
        long lib = 0, vs = 0, vsDepth = 0, fs = 0, cs = 0, psoFull = 0, psoEmpty = 0, cpso = 0, upscaler = 0;
        try (Arena arena = Arena.ofConfined()) {
            ctex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA8_UNORM, 32, 32, 1, 1,
                false, true, true, false, "FfmColor");
            dstTex = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA8_UNORM, 32, 32, 1, 1,
                false, true, true, true, "FfmDst");
            dtex = MetalNative.textureCreate(ctx, MetalConst.FMT_D32_FLOAT, 32, 32, 1, 1,
                false, true, true, false, "FfmDepth");
            cview = MetalNative.textureViewCreate(ctx, ctex, 0, 1);
            dview = MetalNative.textureViewCreate(ctx, dtex, 0, 1);
            assertTrue(ctex != 0 && dstTex != 0 && dtex != 0 && cview != 0 && dview != 0);

            srcBuf = MetalNative.bufferCreate(ctx, 256, arena.allocate(256), "FfmSrcBuf");
            dstBuf = MetalNative.bufferCreate(ctx, 4096, null, "FfmDstBuf");
            vbo = MetalNative.bufferCreate(ctx, 64, null, "FfmVbo");
            ibo = MetalNative.bufferCreate(ctx, 64, null, "FfmIbo");
            ubo = MetalNative.bufferCreate(ctx, 256, null, "FfmUbo");
            MemorySegment vtxMem = MemorySegment.ofAddress(MetalNative.bufferContents(vbo)).reinterpret(64);
            // 3 triangles' worth of packed float3 positions
            float[] verts = {-1f, -1f, 0.5f, 3f, -1f, 0.5f, -1f, 3f, 0.5f};
            for (int i = 0; i < verts.length; i++) vtxMem.set(ValueLayout.JAVA_FLOAT, i * 4L, verts[i]);
            MemorySegment idxMem = MemorySegment.ofAddress(MetalNative.bufferContents(ibo)).reinterpret(64);
            idxMem.set(ValueLayout.JAVA_INT, 0, 0);
            idxMem.set(ValueLayout.JAVA_INT, 4, 1);
            idxMem.set(ValueLayout.JAVA_INT, 8, 2);

            tbView = MetalNative.textureBufferCreate(ctx, srcBuf, 0, 16, MetalConst.FMT_RGBA8_UNORM);
            samp = MetalNative.samplerCreate(ctx, 1, 1, 1, 1, 0, 1, false, 0);
            assertTrue(srcBuf != 0 && dstBuf != 0 && vbo != 0 && ibo != 0 && ubo != 0 && tbView != 0 && samp != 0);

            StringBuilder err = new StringBuilder();
            lib = MetalNative.compileMslLibrary(ctx, """
                #include <metal_stdlib>
                using namespace metal;
                struct VIn { float3 pos [[attribute(0)]]; };
                struct VOut { float4 pos [[position]]; };
                vertex VOut vs_ffm(VIn in [[stage_in]], constant float4 *u [[buffer(0)]], constant float4 *pc [[buffer(15)]]) {
                    VOut o; o.pos = float4(in.pos, 1.0f) + (u[0] + pc[0]) * 0.0f; return o;
                }
                vertex VOut vs_depth(uint vid [[vertex_id]]) {
                    VOut o; float2 p = float2((vid==1)?3.0f:-1.0f, (vid==2)?3.0f:-1.0f); o.pos = float4(p, 0.5f, 1.0f); return o;
                }
                fragment half4 fs_ffm(texture_buffer<float, access::read> tb [[texture(0)]], sampler s [[sampler(0)]]) {
                    float4 t = tb.read(0u);
                    return half4(half(t.r + 0.5f), 0.75h, 0.25h, 1.0h);
                }
                kernel void cs_ffm(texture2d<half, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
                    if (gid.x < out.get_width() && gid.y < out.get_height()) out.write(half4(0.25h, 0.5h, 0.75h, 1.0h), gid);
                }
                """, "ffm_full", true, err);
            assertNotEquals(0L, lib, "MSL compile error: " + err);
            vs = MetalNative.compileFunction(lib, "vs_ffm", false, 0, 0, err);
            vsDepth = MetalNative.compileFunction(lib, "vs_depth", false, 0, 0, err);
            fs = MetalNative.compileFunction(lib, "fs_ffm", false, 0, 0, err);
            cs = MetalNative.compileFunction(lib, "cs_ffm", false, 0, 0, err);
            assertTrue(vs != 0 && vsDepth != 0 && fs != 0 && cs != 0);

            MemorySegment vbSeg = arena.allocate(12, 4);
            vbSeg.set(ValueLayout.JAVA_INT, 0, 0);
            vbSeg.set(ValueLayout.JAVA_INT, 4, 12);
            vbSeg.set(ValueLayout.JAVA_INT, 8, 0);

            MemorySegment attrSeg = arena.allocate(16, 4);
            attrSeg.set(ValueLayout.JAVA_INT, 0, 0);
            attrSeg.set(ValueLayout.JAVA_INT, 4, 0);
            attrSeg.set(ValueLayout.JAVA_INT, 8, 0);
            attrSeg.set(ValueLayout.JAVA_INT, 12, MetalConst.FMT_RGB32_FLOAT);

            MemorySegment colorSeg = arena.allocate(36, 4);
            colorSeg.set(ValueLayout.JAVA_INT, 0, MetalConst.FMT_RGBA8_UNORM);
            colorSeg.set(ValueLayout.JAVA_INT, 32, 15);

            psoFull = MetalNative.renderPipelineCreate(ctx, vs, fs, vbSeg, 1, attrSeg, 1, colorSeg, 1,
                MetalConst.FMT_D32_FLOAT, MetalConst.toNativeTopology(com.mojang.renderpearl.api.pipeline.PrimitiveTopology.TRIANGLES),
                0, false, true, 0, false, 0f, 0f, "FfmFullPso", err);
            // Also exercise nullable optional segments path (empty vertex/attrib/color)
            psoEmpty = MetalNative.renderPipelineCreate(ctx, vsDepth, 0L, null, 0, null, 0, null, 0,
                MetalConst.FMT_D32_FLOAT, 3, 0, false, true, 0, false, 0f, 0f, null, err);
            cpso = MetalNative.computePipelineCreate(ctx, cs, "FfmCompute", err);
            assertTrue(psoFull != 0 && psoEmpty != 0 && cpso != 0, "Pipeline create error: " + err);

            MemorySegment clrViews = arena.allocate(8, 8);
            clrViews.set(ValueLayout.JAVA_LONG, 0, cview);
            MemorySegment clrFlags = arena.allocate(4, 4);
            clrFlags.set(ValueLayout.JAVA_INT, 0, 1);
            MemorySegment clrRgba = arena.allocate(16, 4);
            clrRgba.set(ValueLayout.JAVA_FLOAT, 12, 1f);

            MemorySegment firsts = arena.allocate(4, 4);
            firsts.set(ValueLayout.JAVA_INT, 0, 0);
            MemorySegment counts = arena.allocate(4, 4);
            counts.set(ValueLayout.JAVA_INT, 0, 3);
            MemorySegment idxOffs = arena.allocate(8, 8);
            idxOffs.set(ValueLayout.JAVA_LONG, 0, 0L);

            MemorySegment texs = arena.allocate(8, 8);
            texs.set(ValueLayout.JAVA_LONG, 0, dstTex);

            MetalNative.cmdBegin(ctx);
            assertTrue(MetalNative.cmdHasActive(ctx));
            MetalNative.blitClearColor(ctx, ctex, 0f, 0f, 0f, 1f);
            MetalNative.blitClearDepth(ctx, dtex, 0.0);
            MetalNative.blitClearColorDepth(ctx, ctex, 0f, 0f, 0f, 1f, dtex, 0.0);
            MetalNative.blitCopyBuffer(ctx, srcBuf, 0, dstBuf, 0, 64);
            MetalNative.blitWriteTexture(ctx, ctex, arena.allocate(32 * 32 * 4), 32L * 32 * 4, 32 * 4, 0, 0, 0, 0, 32, 32);
            MetalNative.blitCopyBufferToTexture(ctx, srcBuf, 0, 32, dstTex, 0, 0, 0, 0, 8, 8);
            MetalNative.blitCopyTexture(ctx, ctex, 0, 0, 0, 0, dstTex, 0, 0, 0, 0, 32, 32);

            assertTrue(MetalNative.passBegin(ctx, clrViews, clrFlags, clrRgba, 1, dview, true, 0.0, 0, 0, 32, 32, "FfmPass"));
            MetalNative.passSetPipeline(ctx, psoFull);
            MetalNative.passSetScissor(ctx, true, 0, 0, 32, 32);
            MetalNative.passSetScissor(ctx, false, 0, 0, 0, 0);
            MetalNative.passSetUniformBuffer(ctx, 0, ubo, 0);
            MetalNative.passSetTextureSampler(ctx, 0, tbView, 0, samp);
            MetalNative.passPushConstants(ctx, MetalConst.FMT_R8_UNORM + 15, arena.allocate(16), 16);
            MetalNative.passSetVertexBuffer(ctx, 0, vbo, 0, 12);
            MetalNative.passSetIndexBuffer(ctx, ibo, true);
            MetalNative.passDraw(ctx, 3, 3, 1, 0, 0);
            MetalNative.passDraw(ctx, MetalConst.TOPO_TRIANGLE_FAN, 3, 1, 0, 0);
            MetalNative.passDrawIndexed(ctx, 3, 0, 3, 1, 0, 0, 0);
            MetalNative.passMultiDraw(ctx, 3, firsts, counts, 1, 1, 0);
            MetalNative.passMultiDrawIndexed(ctx, 3, idxOffs, counts, null, 1, 1, 0);
            // Packed (interleaved RenderPearl command) multi-draws read natively without Java copies
            MemorySegment packed = arena.allocate(12, 4);
            packed.setAtIndex(ValueLayout.JAVA_INT, 0, 0);
            packed.setAtIndex(ValueLayout.JAVA_INT, 1, 3);
            packed.setAtIndex(ValueLayout.JAVA_INT, 2, 0);
            MetalNative.passMultiDrawPacked(ctx, 3, packed, 1, 1, 0);
            MetalNative.passMultiDrawIndexedPacked(ctx, 3, packed, 1, 0L, 1, 0);
            MetalNative.passFinish(ctx);

            // A following load-only pass on identical attachments merges into the still-open encoder
            MemorySegment stats0 = arena.allocate(8L * MetalConst.STAT_COUNT, 8);
            MemorySegment stats1 = arena.allocate(8L * MetalConst.STAT_COUNT, 8);
            MetalNative.deviceStats(ctx, stats0, MetalConst.STAT_COUNT);
            MemorySegment noClear = arena.allocate(4, 4);
            assertTrue(MetalNative.passBegin(ctx, clrViews, noClear, clrRgba, 1, dview, false, 0.0, 0, 0, 32, 32, null));
            MetalNative.passSetPipeline(ctx, psoFull);
            MetalNative.passDraw(ctx, 3, 3, 1, 0, 0);
            MetalNative.passFinish(ctx);
            MetalNative.deviceStats(ctx, stats1, MetalConst.STAT_COUNT);
            long merged = stats1.getAtIndex(ValueLayout.JAVA_LONG, MetalConst.STAT_PASSES_MERGED)
                - stats0.getAtIndex(ValueLayout.JAVA_LONG, MetalConst.STAT_PASSES_MERGED);
            assertEquals(1L, merged);
            MetalNative.deviceSetOption(ctx, MetalConst.OPT_PASS_MERGE, 1);
            MetalNative.passEnd(ctx);

            // Also cover passBegin with null color arrays (depth-only pass)
            assertTrue(MetalNative.passBegin(ctx, null, null, null, 0, dview, false, 0.0, 0, 0, 32, 32, null));
            MetalNative.passSetPipeline(ctx, psoEmpty);
            MetalNative.passEnd(ctx);

            MetalNative.computeDispatch(ctx, cpso, null, null, 0, texs, 1, null, 0, 4, 4, 1, 8, 8, 1);
            MetalNative.blitCopyTextureToBuffer(ctx, ctex, 0, 0, 0, 0, 32, 32, dstBuf, 0, 32 * 4);

            upscaler = MetalNative.upscalerCreate(ctx, false, MetalConst.FMT_RGBA8_UNORM, MetalConst.FMT_RGBA8_UNORM, 32, 32, 32, 32, false);
            if (upscaler != 0L) {
                MetalNative.upscalerEncode(ctx, upscaler, ctex, 0L, 0L, dstTex, 0f, 0f, false);
            }

            long serial = MetalNative.cmdSubmit(ctx, 2);
            assertFalse(MetalNative.cmdHasActive(ctx));
            assertTrue(MetalNative.waitSubmit(ctx, serial, 5_000_000_000L));
            assertEquals("", MetalNative.deviceDrainErrors(ctx));
            assertFalse(MetalNative.deviceIsLost(ctx));

            // Verify mapped Metal buffer ByteBuffer views use native little-endian byte order
            var mappedBb = MemorySegment.ofAddress(MetalNative.bufferContents(ubo)).reinterpret(64)
                .asByteBuffer().order(java.nio.ByteOrder.nativeOrder());
            mappedBb.putFloat(0, 1.0f);
            MemorySegment uboSeg = MemorySegment.ofAddress(MetalNative.bufferContents(ubo)).reinterpret(64);
            assertEquals(Float.floatToRawIntBits(1.0f), uboSeg.get(ValueLayout.JAVA_INT_UNALIGNED, 0));
        } finally {
            if (upscaler != 0) MetalNative.upscalerDestroy(ctx, upscaler);
            if (cpso != 0) MetalNative.computePipelineDestroy(ctx, cpso);
            if (psoEmpty != 0) MetalNative.pipelineDestroy(ctx, psoEmpty);
            if (psoFull != 0) MetalNative.pipelineDestroy(ctx, psoFull);
            if (cs != 0) MetalNative.functionDestroy(cs);
            if (fs != 0) MetalNative.functionDestroy(fs);
            if (vsDepth != 0) MetalNative.functionDestroy(vsDepth);
            if (vs != 0) MetalNative.functionDestroy(vs);
            if (lib != 0) MetalNative.libraryDestroy(lib);
            if (samp != 0) MetalNative.samplerDestroy(ctx, samp);
            if (tbView != 0) MetalNative.textureViewDestroy(ctx, tbView);
            if (ubo != 0) MetalNative.bufferDestroy(ctx, ubo);
            if (ibo != 0) MetalNative.bufferDestroy(ctx, ibo);
            if (vbo != 0) MetalNative.bufferDestroy(ctx, vbo);
            if (dstBuf != 0) MetalNative.bufferDestroy(ctx, dstBuf);
            if (srcBuf != 0) MetalNative.bufferDestroy(ctx, srcBuf);
            if (dview != 0) MetalNative.textureViewDestroy(ctx, dview);
            if (cview != 0) MetalNative.textureViewDestroy(ctx, cview);
            if (dtex != 0) MetalNative.textureDestroy(ctx, dtex);
            if (dstTex != 0) MetalNative.textureDestroy(ctx, dstTex);
            if (ctex != 0) MetalNative.textureDestroy(ctx, ctex);
            MetalNative.deviceDestroy(ctx);
        }
    }
}
