package dev.celestia.metal.backend;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.BlendEquation;
import com.mojang.renderpearl.api.pipeline.BlendFactor;
import com.mojang.renderpearl.api.pipeline.BlendFunction;
import com.mojang.renderpearl.api.pipeline.BlendOp;
import com.mojang.renderpearl.api.pipeline.ColorTargetState;
import com.mojang.renderpearl.api.pipeline.DepthStencilState;
import com.mojang.renderpearl.api.pipeline.PolygonMode;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;
import com.mojang.renderpearl.api.pipeline.ShaderType;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;

/**
 * Compiled RenderPearl pipeline backed by Metal render pipeline states.
 * Metal bakes the depth attachment format into {@code MTLRenderPipelineState}, so variants are cached
 * lazily by depth format (none, D32_FLOAT, D32_FLOAT_S8_UINT, D16_UNORM).
 */
public final class CelestiaPipeline implements BackendRenderPipeline {
    private static final Logger LOGGER = LogUtils.getLogger();
    public static final int NO_DEPTH = -1;

    private final CelestiaMetalDevice device;
    private final BackendRenderPipeline.CreateInfo info;
    private final List<MetalShaderTranslator.SlotBinding> bindings;
    private final long vsFunction;
    private final long fsFunction;
    private final long vsLibrary;
    private final long fsLibrary;
    private final Map<Integer, Long> psoByDepthFormat = new ConcurrentHashMap<>();
    private volatile boolean closed;

    private CelestiaPipeline(CelestiaMetalDevice device, BackendRenderPipeline.CreateInfo info,
                             List<MetalShaderTranslator.SlotBinding> bindings,
                             long vsLib, long fsLib, long vsFn, long fsFn) {
        this.device = device;
        this.info = info;
        this.bindings = bindings;
        this.vsLibrary = vsLib;
        this.fsLibrary = fsLib;
        this.vsFunction = vsFn;
        this.fsFunction = fsFn;
    }

    public static Pending compileAsync(CelestiaMetalDevice device, BackendRenderPipeline.CreateInfo info) {
        boolean points = info.primitiveTopology() == PrimitiveTopology.POINTS;
        List<MetalShaderTranslator.SlotBinding> bindings = MetalShaderTranslator.buildBindings(info.uniforms());
        boolean fastMath = MetalShaderTranslator.isRelaxedMathCandidate(info.name());

        BackendRenderPipeline.CreateInfo.Shader vsShader = null;
        BackendRenderPipeline.CreateInfo.Shader fsShader = null;
        for (BackendRenderPipeline.CreateInfo.Shader s : info.shaders()) {
            if (s.module().type() == ShaderType.VERTEX) vsShader = s;
            else if (s.module().type() == ShaderType.FRAGMENT) fsShader = s;
        }
        if (vsShader == null) {
            throw new IllegalStateException("Pipeline " + info.name() + " has no vertex shader");
        }

        MetalShaderTranslator.Result vsMsl = MetalShaderTranslator.translate(vsShader, bindings, points);
        MetalShaderTranslator.Result fsMsl = fsShader != null
            ? MetalShaderTranslator.translate(fsShader, bindings, points) : null;

        StringBuilder err = new StringBuilder();
        long vsLib = MetalNative.compileMslLibrary(device.handle(), vsMsl.source(), info.name() + ".vs", fastMath, err);
        if (vsLib == 0L) {
            LOGGER.error("Vertex MSL compilation failed for {}: {}\n{}", info.name(), err, vsMsl.source());
            throw new IllegalStateException("Failed to compile vertex MSL for " + info.name() + ": " + err);
        }
        long vsFn = MetalNative.compileFunction(vsLib, vsMsl.entryPoint(), false, 0, 0, err);
        if (vsFn == 0L) {
            MetalNative.libraryDestroy(vsLib);
            throw new IllegalStateException("Failed to find vertex entry point for " + info.name() + ": " + err);
        }

        long fsLib = 0L;
        long fsFn = 0L;
        if (fsMsl != null) {
            fsLib = MetalNative.compileMslLibrary(device.handle(), fsMsl.source(), info.name() + ".fs", fastMath, err);
            if (fsLib == 0L) {
                MetalNative.functionDestroy(vsFn);
                MetalNative.libraryDestroy(vsLib);
                LOGGER.error("Fragment MSL compilation failed for {}: {}\n{}", info.name(), err, fsMsl.source());
                throw new IllegalStateException("Failed to compile fragment MSL for " + info.name() + ": " + err);
            }
            fsFn = MetalNative.compileFunction(fsLib, fsMsl.entryPoint(), false, 0, 0, err);
            if (fsFn == 0L) {
                MetalNative.functionDestroy(vsFn);
                MetalNative.libraryDestroy(vsLib);
                MetalNative.libraryDestroy(fsLib);
                throw new IllegalStateException("Failed to find fragment entry point for " + info.name() + ": " + err);
            }
        }

        CelestiaPipeline pipeline = new CelestiaPipeline(device, info, bindings, vsLib, fsLib, vsFn, fsFn);
        // Pre-warm common depth configurations up front off the render thread
        if (!info.colorTargetStates().isEmpty()) {
            pipeline.getOrCreatePso(NO_DEPTH);
        }
        if (info.depthStencilState() != null || info.colorTargetStates().isEmpty()) {
            pipeline.getOrCreatePso(MetalConst.FMT_D32_FLOAT);
        }
        return () -> pipeline;
    }

    public List<MetalShaderTranslator.SlotBinding> bindings() {
        return bindings;
    }

    public List<BindGroupLayout.UniformDescription> uniforms() {
        return info.uniforms();
    }

    public List<BackendRenderPipeline.CreateInfo.VertexBuffer> vertexBuffers() {
        return info.vertexBuffers();
    }

    public PrimitiveTopology topology() {
        return info.primitiveTopology();
    }

    public long getOrCreatePso(int nativeDepthFormat) {
        if (closed) return 0L;
        return psoByDepthFormat.computeIfAbsent(nativeDepthFormat, this::buildPso);
    }

    private long buildPso(int nativeDepthFormat) {
        try (Arena arena = Arena.ofConfined()) {
            List<BackendRenderPipeline.CreateInfo.VertexBuffer> vbs = info.vertexBuffers();
            MemorySegment vbSeg = MemorySegment.NULL;
            if (!vbs.isEmpty()) {
                vbSeg = arena.allocate(12L * vbs.size(), 4);
                for (int i = 0; i < vbs.size(); i++) {
                    var vb = vbs.get(i);
                    long base = i * 12L;
                    vbSeg.set(ValueLayout.JAVA_INT, base, vb.bufferSlot());
                    vbSeg.set(ValueLayout.JAVA_INT, base + 4, vb.stride());
                    vbSeg.set(ValueLayout.JAVA_INT, base + 8, vb.stepRate());
                }
            }

            List<BackendRenderPipeline.CreateInfo.AttribBinding> attrs = info.attribBindings();
            MemorySegment attrSeg = MemorySegment.NULL;
            if (!attrs.isEmpty()) {
                attrSeg = arena.allocate(16L * attrs.size(), 4);
                for (int i = 0; i < attrs.size(); i++) {
                    var ab = attrs.get(i);
                    long base = i * 16L;
                    attrSeg.set(ValueLayout.JAVA_INT, base, ab.bufferSlot());
                    attrSeg.set(ValueLayout.JAVA_INT, base + 4, ab.location());
                    attrSeg.set(ValueLayout.JAVA_INT, base + 8, ab.offset());
                    attrSeg.set(ValueLayout.JAVA_INT, base + 12, MetalConst.toNativeVertexFormat(ab.format()));
                }
            }

            List<ColorTargetState> cts = info.colorTargetStates();
            MemorySegment colorSeg = MemorySegment.NULL;
            if (!cts.isEmpty()) {
                colorSeg = arena.allocate(36L * cts.size(), 4);
                for (int i = 0; i < cts.size(); i++) {
                    ColorTargetState ct = cts.get(i);
                    long base = i * 36L;
                    colorSeg.set(ValueLayout.JAVA_INT, base, MetalConst.toNativeFormat(ct.format()));
                    if (ct.blendFunction().isPresent()) {
                        BlendFunction bf = ct.blendFunction().get();
                        BlendEquation col = bf.color();
                        BlendEquation alp = bf.alpha();
                        colorSeg.set(ValueLayout.JAVA_INT, base + 4, 1);
                        colorSeg.set(ValueLayout.JAVA_INT, base + 8, MetalConst.toNativeBlendFactor(col.sourceFactor()));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 12, MetalConst.toNativeBlendFactor(col.destFactor()));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 16, MetalConst.toNativeBlendOp(col.op()));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 20, MetalConst.toNativeBlendFactor(alp.sourceFactor()));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 24, MetalConst.toNativeBlendFactor(alp.destFactor()));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 28, MetalConst.toNativeBlendOp(alp.op()));
                    } else {
                        colorSeg.set(ValueLayout.JAVA_INT, base + 4, 0);
                        colorSeg.set(ValueLayout.JAVA_INT, base + 8, MetalConst.toNativeBlendFactor(BlendFactor.ONE));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 12, MetalConst.toNativeBlendFactor(BlendFactor.ZERO));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 16, MetalConst.toNativeBlendOp(BlendOp.ADD));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 20, MetalConst.toNativeBlendFactor(BlendFactor.ONE));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 24, MetalConst.toNativeBlendFactor(BlendFactor.ZERO));
                        colorSeg.set(ValueLayout.JAVA_INT, base + 28, MetalConst.toNativeBlendOp(BlendOp.ADD));
                    }
                    int wm = (ct.writeRed() ? 1 : 0) | (ct.writeGreen() ? 2 : 0) | (ct.writeBlue() ? 4 : 0) | (ct.writeAlpha() ? 8 : 0);
                    colorSeg.set(ValueLayout.JAVA_INT, base + 32, wm);
                }
            }

            DepthStencilState ds = info.depthStencilState();
            boolean depthEnabled = nativeDepthFormat != NO_DEPTH && ds != null;
            int depthCmp = ds != null ? MetalConst.toNativeCompare(ds.depthTest()) : 0;
            boolean depthWrite = depthEnabled && ds.writeDepth();
            float biasSlope = ds != null ? ds.depthBiasScaleFactor() : 0.0f;
            float biasConst = ds != null ? ds.depthBiasConstant() : 0.0f;

            StringBuilder err = new StringBuilder();
            long pso = MetalNative.renderPipelineCreate(
                device.handle(), vsFunction, fsFunction,
                vbSeg, vbs.size(),
                attrSeg, attrs.size(),
                colorSeg, cts.size(),
                nativeDepthFormat,
                MetalConst.toNativeTopology(info.primitiveTopology()),
                info.polygonMode() == PolygonMode.WIREFRAME ? 1 : 0,
                info.cull(),
                depthEnabled, depthCmp, depthWrite,
                biasSlope, biasConst,
                info.name(), err);
            if (pso == 0L) {
                throw new IllegalStateException("Failed to create Metal PSO for " + info.name() + " (depth=" + nativeDepthFormat + "): " + err);
            }
            return pso;
        }
    }

    @Override
    public boolean isClosed() {
        return closed;
    }

    @Override
    public void close() {
        if (closed) return;
        closed = true;
        for (Long pso : psoByDepthFormat.values()) {
            if (pso != null && pso != 0L) MetalNative.pipelineDestroy(device.handle(), pso);
        }
        psoByDepthFormat.clear();
        if (vsFunction != 0L) MetalNative.functionDestroy(vsFunction);
        if (fsFunction != 0L) MetalNative.functionDestroy(fsFunction);
        if (vsLibrary != 0L) MetalNative.libraryDestroy(vsLibrary);
        if (fsLibrary != 0L) MetalNative.libraryDestroy(fsLibrary);
    }
}
