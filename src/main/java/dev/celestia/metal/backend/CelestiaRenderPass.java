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
import java.lang.foreign.Arena;
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
            try (Arena arena = Arena.ofConfined()) {
                byte[] tmp = new byte[size];
                data.duplicate().get(tmp);
                MemorySegment seg = arena.allocate(size);
                MemorySegment.copy(tmp, 0, seg, ValueLayout.JAVA_BYTE, 0, size);
                MetalNative.passPushConstants(device.handle(), MetalShaderTranslator.PUSH_CONSTANT_SLOT, seg, size);
            }
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
        if (closed || drawCount <= 0 || drawCommands == null) return;
        flushUniforms();
        // VkMultiDrawInfoEXT interleaved layout: { uint32 firstVertex, uint32 vertexCount }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment firsts = arena.allocate(4L * drawCount, 4);
            MemorySegment counts = arena.allocate(4L * drawCount, 4);
            int basePos = drawCommands.position();
            for (int i = 0; i < drawCount; i++) {
                firsts.set(ValueLayout.JAVA_INT, i * 4L, drawCommands.get(basePos + i * 2));
                counts.set(ValueLayout.JAVA_INT, i * 4L, drawCommands.get(basePos + i * 2 + 1));
            }
            MetalNative.passMultiDraw(device.handle(), nativeTopology(), firsts, counts, drawCount, instanceCount, firstInstance);
        }
    }

    @Override
    public void multiDraw(IntBuffer firsts, IntBuffer counts, int drawCount) {
        if (closed || drawCount <= 0 || firsts == null || counts == null) return;
        flushUniforms();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment firstSeg = copyInts(arena, firsts, drawCount);
            MemorySegment countSeg = copyInts(arena, counts, drawCount);
            MetalNative.passMultiDraw(device.handle(), nativeTopology(), firstSeg, countSeg, drawCount, 1, 0);
        }
    }

    @Override
    public void multiDrawIndexed(IntBuffer drawCommands, int instanceCount, int firstInstance, int drawCount) {
        if (closed || drawCount <= 0 || drawCommands == null) return;
        flushUniforms();
        // VkMultiDrawIndexedInfoEXT interleaved layout: { uint32 firstIndex, uint32 indexCount, int32 vertexOffset }
        int idxBytes = indexType == IndexType.INT ? 4 : 2;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment offsets = arena.allocate(8L * drawCount, 8);
            MemorySegment counts = arena.allocate(4L * drawCount, 4);
            MemorySegment bases = arena.allocate(4L * drawCount, 4);
            int basePos = drawCommands.position();
            for (int i = 0; i < drawCount; i++) {
                long firstIdx = Integer.toUnsignedLong(drawCommands.get(basePos + i * 3));
                offsets.set(ValueLayout.JAVA_LONG, i * 8L, indexBaseOffset + firstIdx * idxBytes);
                counts.set(ValueLayout.JAVA_INT, i * 4L, drawCommands.get(basePos + i * 3 + 1));
                bases.set(ValueLayout.JAVA_INT, i * 4L, drawCommands.get(basePos + i * 3 + 2));
            }
            MetalNative.passMultiDrawIndexed(device.handle(), nativeTopology(),
                offsets, counts, bases, drawCount, instanceCount, firstInstance);
        }
    }

    @Override
    public void multiDrawIndexed(PointerBuffer indices, IntBuffer counts, IntBuffer baseVertices, int drawCount) {
        if (closed || drawCount <= 0 || indices == null || counts == null) return;
        flushUniforms();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment offsets = arena.allocate(8L * drawCount, 8);
            int pPos = indices.position();
            for (int i = 0; i < drawCount; i++) {
                offsets.set(ValueLayout.JAVA_LONG, i * 8L, indices.get(pPos + i));
            }
            MemorySegment countSeg = copyInts(arena, counts, drawCount);
            MemorySegment baseSeg = baseVertices != null ? copyInts(arena, baseVertices, drawCount) : null;
            MetalNative.passMultiDrawIndexed(device.handle(), nativeTopology(),
                offsets, countSeg, baseSeg, drawCount, 1, 0);
        }
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

    private static MemorySegment copyInts(Arena arena, IntBuffer buf, int count) {
        if (buf.isDirect()) {
            long addr = MemoryUtil.memAddress(buf, buf.position());
            return MemorySegment.ofAddress(addr).reinterpret(4L * count);
        }
        MemorySegment seg = arena.allocate(4L * count, 4);
        int pos = buf.position();
        for (int i = 0; i < count; i++) {
            seg.set(ValueLayout.JAVA_INT, i * 4L, buf.get(pos + i));
        }
        return seg;
    }
}
