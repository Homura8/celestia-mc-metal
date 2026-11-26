package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.pipeline.BindGroupLayout;
import com.mojang.renderpearl.api.pipeline.ShaderType;
import com.mojang.renderpearl.api.pipeline.UniformType;
import com.mojang.renderpearl.backend.api.BackendRenderPipeline;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.util.List;
import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.util.spvc.Spvc;
import org.lwjgl.util.spvc.SpvcMslResourceBinding;

/**
 * Translates RenderPearl SPIR-V shader modules to Metal Shading Language (MSL 3.1) via LWJGL SPIRV-Cross.
 */
public final class MetalShaderTranslator {
    private static final int MSL_VERSION_3_1 = 30100;
    private static final int EXEC_VERTEX = 0;
    private static final int EXEC_FRAGMENT = 4;
    public static final int PUSH_CONSTANT_SLOT = 15;

    public record Result(String source, String entryPoint) {}

    public record SlotBinding(int bindingIndex, int bufferSlot, int textureSlot, int samplerSlot) {}

    private MetalShaderTranslator() {}

    public static List<SlotBinding> buildBindings(List<BindGroupLayout.UniformDescription> uniforms) {
        int nextBuf = 0;
        int nextTex = 0;
        int nextSamp = 0;
        SlotBinding[] out = new SlotBinding[uniforms.size()];
        for (int i = 0; i < uniforms.size(); i++) {
            UniformType type = uniforms.get(i).type();
            switch (type) {
                case UNIFORM_BUFFER -> {
                    out[i] = new SlotBinding(i, nextBuf++, -1, -1);
                }
                case COMBINED_IMAGE_SAMPLER -> {
                    out[i] = new SlotBinding(i, -1, nextTex++, nextSamp++);
                }
                case TEXEL_BUFFER -> {
                    out[i] = new SlotBinding(i, -1, nextTex++, -1);
                }
            }
        }
        return List.of(out);
    }

    public static Result translate(BackendRenderPipeline.CreateInfo.Shader shader,
                                   List<SlotBinding> bindings,
                                   boolean pointsTopology) {
        int model = shader.module().type() == ShaderType.VERTEX ? EXEC_VERTEX : EXEC_FRAGMENT;
        ByteBuffer rawSpv = shader.module().spv();
        IntBuffer spirv = rawSpv.duplicate().order(java.nio.ByteOrder.nativeOrder()).asIntBuffer();
        long context = 0L;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            PointerBuffer ptr = stack.callocPointer(1);
            check(Spvc.spvc_context_create(ptr), "spvc_context_create");
            context = ptr.get(0);

            check(Spvc.spvc_context_parse_spirv(context, spirv, spirv.remaining(), ptr), "spvc_context_parse_spirv");
            long ir = ptr.get(0);
            check(Spvc.spvc_context_create_compiler(context, Spvc.SPVC_BACKEND_MSL, ir,
                Spvc.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, ptr), "spvc_context_create_compiler");
            long compiler = ptr.get(0);

            check(Spvc.spvc_compiler_create_compiler_options(compiler, ptr), "spvc_compiler_create_compiler_options");
            long options = ptr.get(0);
            Spvc.spvc_compiler_options_set_uint(options, Spvc.SPVC_COMPILER_OPTION_MSL_VERSION, MSL_VERSION_3_1);
            Spvc.spvc_compiler_options_set_uint(options, Spvc.SPVC_COMPILER_OPTION_MSL_PLATFORM, Spvc.SPVC_MSL_PLATFORM_MACOS);
            Spvc.spvc_compiler_options_set_bool(options, Spvc.SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, true);
            Spvc.spvc_compiler_options_set_bool(options, Spvc.SPVC_COMPILER_OPTION_MSL_ENABLE_POINT_SIZE_BUILTIN, pointsTopology);
            Spvc.spvc_compiler_options_set_bool(options, Spvc.SPVC_COMPILER_OPTION_MSL_ENABLE_POINT_SIZE_DEFAULT, pointsTopology);
            Spvc.spvc_compiler_options_set_bool(options, Spvc.SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, false);
            if (model == EXEC_VERTEX) {
                Spvc.spvc_compiler_options_set_bool(options, Spvc.SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, true);
            }
            check(Spvc.spvc_compiler_install_compiler_options(compiler, options), "spvc_compiler_install_compiler_options");

            SpvcMslResourceBinding rb = SpvcMslResourceBinding.calloc(stack);
            for (SlotBinding sb : bindings) {
                Spvc.spvc_msl_resource_binding_init(rb);
                rb.stage(model)
                    .desc_set(0)
                    .binding(sb.bindingIndex())
                    .msl_buffer(sb.bufferSlot() >= 0 ? sb.bufferSlot() : 0)
                    .msl_texture(sb.textureSlot() >= 0 ? sb.textureSlot() : 0)
                    .msl_sampler(sb.samplerSlot() >= 0 ? sb.samplerSlot() : 0);
                check(Spvc.spvc_compiler_msl_add_resource_binding(compiler, rb), "spvc_compiler_msl_add_resource_binding");
            }

            Spvc.spvc_msl_resource_binding_init(rb);
            rb.stage(model)
                .desc_set(Spvc.SPVC_MSL_PUSH_CONSTANT_DESC_SET)
                .binding(Spvc.SPVC_MSL_PUSH_CONSTANT_BINDING)
                .msl_buffer(PUSH_CONSTANT_SLOT);
            check(Spvc.spvc_compiler_msl_add_resource_binding(compiler, rb), "spvc_compiler_msl_add_resource_binding(push)");

            check(Spvc.spvc_compiler_set_entry_point(compiler, shader.entryPoint(), model), "spvc_compiler_set_entry_point");
            check(Spvc.spvc_compiler_compile(compiler, ptr), "spvc_compiler_compile");
            String source = MemoryUtil.memUTF8(ptr.get(0));
            String entry = Spvc.spvc_compiler_get_cleansed_entry_point_name(compiler, shader.entryPoint(), model);
            return new Result(source, entry);
        } finally {
            if (context != 0L) {
                Spvc.spvc_context_destroy(context);
            }
        }
    }

    /**
     * Terrain pipelines benefit measurably from relaxed IEEE math on Apple Silicon without affecting
     * sky/fog/UI accuracy.
     */
    public static boolean isRelaxedMathCandidate(String pipelineName) {
        if (pipelineName == null) return false;
        String lower = pipelineName.toLowerCase(java.util.Locale.ROOT);
        return lower.contains("terrain") || lower.contains("chunk") || lower.contains("sodium");
    }

    private static void check(int code, String step) {
        if (code != Spvc.SPVC_SUCCESS) {
            throw new IllegalStateException("SPIRV-Cross failed at " + step + " (code " + code + ")");
        }
    }
}
