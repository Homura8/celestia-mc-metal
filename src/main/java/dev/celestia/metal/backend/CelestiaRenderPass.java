package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.buffers.GpuBuffer;
import com.mojang.renderpearl.api.buffers.GpuBufferSlice;
import com.mojang.renderpearl.api.commands.GpuQueryPool;
import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.IndexType;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;
import com.mojang.renderpearl.api.pipeline.UniformType;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import com.mojang.renderpearl.backend.api.RenderPassBackend;
import com.mojang.renderpearl.util.TextureViewAndSampler;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryUtil;

public final class CelestiaRenderPass implements RenderPassBackend {
    private record TexelKey(long bufHandle, long offset, long length, int format) {}

    private final CelestiaMetalDevice device;
    private final CelestiaCommandEncoder encoder;
    private final int depthFormat;
    private final int[] vtxStrides = new int[8];
    private final Map<TexelKey, Long> texelBufferViews = new HashMap<>();
    private Object[] pendingUniforms = new Object[16];
    private boolean uniformsDirty;
    private CelestiaPipeline pipeline;
    private IndexType indexType = IndexType.INT;
    private long indexBaseOffset;
    private boolean closed;

    CelestiaRenderPass(CelestiaMetalDevice device, CelestiaCommandEncoder encoder, GpuFormat depthFormat) {
        this.device = device;
        this.encoder = encoder;
        this.depthFormat = depthFormat != null ? MetalConst.toNativeFormat(depthFormat) : CelestiaPipeline.NO_DEPTH;
    }

    void closePass() {
        closed = true;
        if (!texelBufferViews.isEmpty()) {
            long[] handles = new long[texelBufferViews.size()];
            int i = 0;
            for (Long h : texelBufferViews.values()) {
                handles[i++] = h != null ? h : 0L;
            }
            texelBufferViews.clear();
            long devHandle = device.handle();
            encoder.runWhenSubmitDone(() -> {
                for (long h : handles) {
                    if (h != 0L) MetalNative.textureViewDestroy(devHandle, h);
                }
            });
        }
    }

    @Override
    public void pushDebugGroup(Supplier<String> name) {
        // Optional debug markers
    }

    @Override
    public void popDebugGroup() {
    }

    @Override
    public void setPipeline(BackendRenderPipeline backendPipeline) {
        if (closed) return;
        this.pipeline = (CelestiaPipeline) backendPipeline;
        for (var vb : this.pipeline.vertexBuffers()) {
            if (vb.bufferSlot() >= 0 && vb.bufferSlot() < vtxStrides.length) {
                vtxStrides[vb.bufferSlot()] = vb.stride();
            }
        }
        long pso = this.pipeline.getOrCreatePso(depthFormat);
        MetalNative.passSetPipeline(device.handle(), pso);
        Arrays.fill(pendingUniforms, null);
        this.uniformsDirty = true;
    }

    @Override
    public void setUniform(int index, Object value) {
        if (closed || index < 0) return;
        if (index >= pendingUniforms.length) {
            pendingUniforms = Arrays.copyOf(pendingUniforms, Math.max(pendingUniforms.length * 2, index + 1));
        }
        pendingUniforms[index] = value;
        uniformsDirty = true;
    }

    private void flushUniforms() {
        if (!uniformsDirty || pipeline == null) return;
        uniformsDirty = false;
        List<BindGroupLayout.UniformDescription> uniforms = pipeline.uniforms();
        List<MetalShaderTranslator.SlotBinding> bindings = pipeline.bindings();
        int count = Math.min(bindings.size(), pendingUniforms.length);
        for (int index = 0; index < count; index++) {
            Object value = pendingUniforms[index];
            if (value == null) continue;
            BindGroupLayout.UniformDescription desc = uniforms.get(index);
            UniformType type = desc.type();
            MetalShaderTranslator.SlotBinding sb = bindings.get(index);

            switch (type) {
                case UNIFORM_BUFFER -> {
                    if (value instanceof GpuBufferSlice slice && slice.buffer() instanceof CelestiaBuffer cb) {
                        MetalNative.passSetUniformBuffer(device.handle(), sb.bufferSlot(), cb.handle(), slice.offset());
                    } else if (value instanceof CelestiaBuffer cb) {
                        MetalNative.passSetUniformBuffer(device.handle(), sb.bufferSlot(), cb.handle(), 0L);
                    }
                }
                case COMBINED_IMAGE_SAMPLER -> {
                    if (value instanceof TextureViewAndSampler tvs
                        && tvs.view() instanceof CelestiaTextureView tv
                        && tvs.sampler() instanceof CelestiaSampler samp) {
                        MetalNative.passSetTextureSampler(device.handle(), sb.textureSlot(), tv.handle(), sb.samplerSlot(), samp.handle());
                    }
                }
                case TEXEL_BUFFER -> {
                    if (value instanceof GpuBufferSlice slice && slice.buffer() instanceof CelestiaBuffer cb) {
                        int nativeFmt = MetalConst.toNativeFormat(desc.gpuFormat());
                        TexelKey key = new TexelKey(cb.handle(), slice.offset(), slice.length(), nativeFmt);
                        long viewHandle = texelBufferViews.computeIfAbsent(key, k ->
                            MetalNative.textureBufferCreate(device.handle(), k.bufHandle(), k.offset(), k.length(), k.format()));
                        if (viewHandle != 0L) {
                            MetalNative.passSetTextureSampler(device.handle(), sb.textureSlot(), viewHandle, -1, 0L);
                        }
                    } else if (value instanceof CelestiaBuffer cb) {
                        int nativeFmt = MetalConst.toNativeFormat(desc.gpuFormat());
                        TexelKey key = new TexelKey(cb.handle(), 0L, cb.size(), nativeFmt);
                        long viewHandle = texelBufferViews.computeIfAbsent(key, k ->
                            MetalNative.textureBufferCreate(device.handle(), k.bufHandle(), k.offset(), k.length(), k.format()));
                        if (viewHandle != 0L) {
                            MetalNative.passSetTextureSampler(device.handle(), sb.textureSlot(), viewHandle, -1, 0L);
                        }
                    } else if (value instanceof CelestiaTextureView tv) {
                        MetalNative.passSetTextureSampler(device.handle(), sb.textureSlot(), tv.handle(), -1, 0L);
                    }
                }
            }
        }
    }

    @Override
    public void pushConstants(ByteBuffer data) {
        if (closed || data == null || !data.hasRemaining()) return;
        int size = data.remaining();
        if (data.isDirect()) {
            MemorySegment seg = MemorySegment.ofBuffer(data);
            MetalNative.passPushConstants(device.handle(), MetalShaderTranslator.PUSH_CONSTANT_SLOT, seg, size);
        } else {
            MemorySegment seg = encoder.drawScratch().get(size);
            MemorySegment.copy(MemorySegment.ofBuffer(data), 0L, seg, 0L, size);
            MetalNative.passPushConstants(device.handle(), MetalShaderTranslator.PUSH_CONSTANT_SLOT, seg, size);
        }
    }

    @Override
    public void enableScissor(int x, int y, int width, int height) {
        if (closed) return;
        MetalNative.passSetScissor(device.handle(), true, x, y, width, height);
    }

    @Override
    public void disableScissor() {
        if (closed) return;
        MetalNative.passSetScissor(device.handle(), false, 0, 0, 0, 0);
    }

    @Override
    public void setVertexBuffer(int slot, GpuBufferSlice slice) {
        if (closed || slice == null || !(slice.buffer() instanceof CelestiaBuffer cb)) return;
        int stride = (slot >= 0 && slot < vtxStrides.length) ? vtxStrides[slot] : 0;
        MetalNative.passSetVertexBuffer(device.handle(), slot, cb.handle(), slice.offset(), stride);
    }

    @Override
    public void setIndexBuffer(GpuBuffer buffer, IndexType type) {
        if (closed || !(buffer instanceof CelestiaBuffer cb)) return;
        this.indexType = type;
        this.indexBaseOffset = 0L;
        MetalNative.passSetIndexBuffer(device.handle(), cb.handle(), type == IndexType.INT);
    }

    private int nativeTopology() {
        PrimitiveTopology t = pipeline != null ? pipeline.topology() : PrimitiveTopology.TRIANGLES;
        return MetalConst.toNativeTopology(t);
    }

    @Override
    public void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) {
        if (closed || vertexCount <= 0 || instanceCount <= 0) return;
        flushUniforms();
        MetalNative.passDraw(device.handle(), nativeTopology(), vertexCount, instanceCount, firstVertex, firstInstance);
    }

    @Override
    public void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance) {
        if (closed || indexCount <= 0 || instanceCount <= 0) return;
        flushUniforms();
        MetalNative.passDrawIndexed(device.handle(), nativeTopology(), indexBaseOffset,
            indexCount, instanceCount, baseVertex, firstIndex, firstInstance);
    }

    @Override
    public void multiDraw(IntBuffer drawCommands, int instanceCount, int firstInstance, int drawCount) {
        if (closed || drawCount <= 0 || drawCommands == null || instanceCount <= 0) return;
        flushUniforms();
        // VkMultiDrawInfoEXT interleaved layout { uint32 firstVertex, uint32 vertexCount } read natively
        MemorySegment cmds = intView(drawCommands, 2L * drawCount);
        MetalNative.passMultiDrawPacked(device.handle(), nativeTopology(), cmds, drawCount, instanceCount, firstInstance);
    }

    @Override
    public void multiDraw(IntBuffer firsts, IntBuffer counts, int drawCount) {
        if (closed || drawCount <= 0 || firsts == null || counts == null) return;
        flushUniforms();
        MemorySegment firstSeg;
        MemorySegment countSeg;
        if (firsts.isDirect() && counts.isDirect()) {
            firstSeg = directInts(firsts, drawCount);
            countSeg = directInts(counts, drawCount);
        } else {
            long bytes = 4L * drawCount;
            MemorySegment scratch = encoder.drawScratch().get(2L * bytes);
            firstSeg = copyInts(scratch.asSlice(0L, bytes), firsts, drawCount);
            countSeg = copyInts(scratch.asSlice(bytes, bytes), counts, drawCount);
        }
        MetalNative.passMultiDraw(device.handle(), nativeTopology(), firstSeg, countSeg, drawCount, 1, 0);
    }

    @Override
    public void multiDrawIndexed(IntBuffer drawCommands, int instanceCount, int firstInstance, int drawCount) {
        if (closed || drawCount <= 0 || drawCommands == null || instanceCount <= 0) return;
        flushUniforms();
        // VkMultiDrawIndexedInfoEXT interleaved layout { uint32 firstIndex, uint32 indexCount, int32 vertexOffset }
        MemorySegment cmds = intView(drawCommands, 3L * drawCount);
        MetalNative.passMultiDrawIndexedPacked(device.handle(), nativeTopology(), cmds, drawCount,
            indexBaseOffset, instanceCount, firstInstance);
    }

    @Override
    public void multiDrawIndexed(PointerBuffer indices, IntBuffer counts, IntBuffer baseVertices, int drawCount) {
        if (closed || drawCount <= 0 || indices == null || counts == null) return;
        flushUniforms();
        // PointerBuffer is always direct and holds 64-bit byte offsets on arm64: pass it through unchanged.
        MemorySegment offsets = MemorySegment.ofAddress(indices.address()).reinterpret(8L * drawCount);
        MemorySegment countSeg;
        MemorySegment baseSeg = null;
        boolean direct = counts.isDirect() && (baseVertices == null || baseVertices.isDirect());
        if (direct) {
            countSeg = directInts(counts, drawCount);
            if (baseVertices != null) baseSeg = directInts(baseVertices, drawCount);
        } else {
            long bytes = 4L * drawCount;
            MemorySegment scratch = encoder.drawScratch().get(2L * bytes);
            countSeg = copyInts(scratch.asSlice(0L, bytes), counts, drawCount);
            if (baseVertices != null) baseSeg = copyInts(scratch.asSlice(bytes, bytes), baseVertices, drawCount);
        }
        MetalNative.passMultiDrawIndexed(device.handle(), nativeTopology(),
            offsets, countSeg, baseSeg, drawCount, 1, 0);
    }

    @Override
    public void drawIndexedIndirect(GpuBufferSlice indirectBuffer, int drawCount) {
        if (closed || drawCount <= 0 || !(indirectBuffer.buffer() instanceof CelestiaBuffer cb)) return;
        flushUniforms();
        MetalNative.passDrawIndirect(device.handle(), nativeTopology(), cb.handle(), indirectBuffer.offset(),
            drawCount, 20, true);
    }

    @Override
    public void drawIndirect(GpuBufferSlice indirectBuffer, int drawCount) {
        if (closed || drawCount <= 0 || !(indirectBuffer.buffer() instanceof CelestiaBuffer cb)) return;
        flushUniforms();
        MetalNative.passDrawIndirect(device.handle(), nativeTopology(), cb.handle(), indirectBuffer.offset(),
            drawCount, 16, false);
    }

    @Override
    public void writeTimestamp(GpuQueryPool pool, int index) {
        if (closed) return;
        if (pool instanceof CelestiaQueryPool cqp) {
            long gpuNs = MetalNative.deviceLastGpuNs(device.handle());
            if (gpuNs > 0L) {
                cqp.record(index, gpuNs);
            }
        }
    }

    /** Zero-copy view of a direct buffer, or a copy into draw scratch memory for heap buffers. */
    private MemorySegment intView(IntBuffer buf, long intCount) {
        if (buf.isDirect()) {
            return MemorySegment.ofAddress(MemoryUtil.memAddress(buf, buf.position())).reinterpret(4L * intCount);
        }
        MemorySegment seg = encoder.drawScratch().get(4L * intCount);
        int pos = buf.position();
        for (long i = 0; i < intCount; i++) {
            seg.setAtIndex(ValueLayout.JAVA_INT, i, buf.get(pos + (int) i));
        }
        return seg;
    }

    private static MemorySegment directInts(IntBuffer buf, int count) {
        return MemorySegment.ofAddress(MemoryUtil.memAddress(buf, buf.position())).reinterpret(4L * count);
    }

    private static MemorySegment copyInts(MemorySegment dst, IntBuffer buf, int count) {
        int pos = buf.position();
        for (int i = 0; i < count; i++) {
            dst.setAtIndex(ValueLayout.JAVA_INT, i, buf.get(pos + i));
        }
        return dst;
    }
}
