package dev.celestia.metal.shader.iris;

import dev.celestia.metal.shader.pack.ShaderOptionState;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import org.lwjgl.PointerBuffer;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.util.shaderc.Shaderc;
import org.lwjgl.util.spvc.Spvc;

/**
 * Translates OptiFine / Iris GLSL shaders to Metal Shading Language (MSL) on demand using
 * LWJGL Shaderc (GLSL -> SPIR-V) and SPIRV-Cross (SPIR-V -> MSL).
 * Never invoked when Off or a Native MSL shader pack is active.
 */
public final class IrisGlslBridge {
    private IrisGlslBridge() {}

    public enum Stage {
        VERTEX(Shaderc.shaderc_glsl_vertex_shader, 0),
        FRAGMENT(Shaderc.shaderc_glsl_fragment_shader, 4),
        COMPUTE(Shaderc.shaderc_glsl_compute_shader, 5);

        public final int shadercKind;
        public final int spvcModel;

        Stage(int shadercKind, int spvcModel) {
            this.shadercKind = shadercKind;
            this.spvcModel = spvcModel;
        }
    }

    public static String preprocessLegacyGlsl(String source, ShaderOptionState options, Stage stage) {
        StringBuilder sb = new StringBuilder();
        String trimmed = source.stripLeading();
        if (!trimmed.startsWith("#version")) {
            sb.append("#version 450 core\n");
        } else {
            int nl = source.indexOf('\n');
            if (nl > 0) {
                sb.append("#version 450 core\n");
                source = source.substring(nl + 1);
            }
        }
        sb.append("#define MC_GL_RENDERER_METAL 1\n");
        sb.append("#define CELESTIA_METAL 1\n");
        if (options != null) {
            sb.append(options.toGlslDefines());
        }
        if (stage == Stage.FRAGMENT) {
            // Minimal legacy compatibility helpers for simple OptiFine GLSL fragments
            sb.append("layout(location = 0) out vec4 celestiaFragColor0;\n");
        }
        sb.append(source);
        return sb.toString();
    }

    public static String translateGlslToMsl(String filename, String glslSource, Stage stage, ShaderOptionState options) {
        String prepared = preprocessLegacyGlsl(glslSource, options, stage);
        long compiler = Shaderc.shaderc_compiler_initialize();
        long opt = Shaderc.shaderc_compile_options_initialize();
        long result = 0L;
        try {
            Shaderc.shaderc_compile_options_set_source_language(opt, Shaderc.shaderc_source_language_glsl);
            Shaderc.shaderc_compile_options_set_target_env(opt, Shaderc.shaderc_target_env_vulkan, Shaderc.shaderc_env_version_vulkan_1_2);
            Shaderc.shaderc_compile_options_set_auto_bind_uniforms(opt, true);
            Shaderc.shaderc_compile_options_set_auto_combined_image_sampler(opt, true);
            Shaderc.shaderc_compile_options_set_auto_map_locations(opt, true);
            Shaderc.shaderc_compile_options_set_vulkan_rules_relaxed(opt, true);

            result = Shaderc.shaderc_compile_into_spv(compiler, prepared, stage.shadercKind, filename, "main", opt);
            int status = Shaderc.shaderc_result_get_compilation_status(result);
            if (status != Shaderc.shaderc_compilation_status_success) {
                String msg = Shaderc.shaderc_result_get_error_message(result);
                throw new IllegalStateException("Iris GLSL compile error (" + filename + "): " + msg);
            }
            ByteBuffer spv = Shaderc.shaderc_result_get_bytes(result);
            return spirvToMsl(spv, stage);
        } finally {
            if (result != 0L) Shaderc.shaderc_result_release(result);
            if (opt != 0L) Shaderc.shaderc_compile_options_release(opt);
            if (compiler != 0L) Shaderc.shaderc_compiler_release(compiler);
        }
    }

    private static String spirvToMsl(ByteBuffer spv, Stage stage) {
        IntBuffer irBuf = spv.asIntBuffer();
        long ctx = 0L;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            PointerBuffer ptr = stack.callocPointer(1);
            if (Spvc.spvc_context_create(ptr) != Spvc.SPVC_SUCCESS) {
                throw new IllegalStateException("spvc_context_create failed");
            }
            ctx = ptr.get(0);
            if (Spvc.spvc_context_parse_spirv(ctx, irBuf, irBuf.remaining(), ptr) != Spvc.SPVC_SUCCESS) {
                throw new IllegalStateException("spvc_context_parse_spirv failed");
            }
            long ir = ptr.get(0);
            if (Spvc.spvc_context_create_compiler(ctx, Spvc.SPVC_BACKEND_MSL, ir,
                Spvc.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, ptr) != Spvc.SPVC_SUCCESS) {
                throw new IllegalStateException("spvc_context_create_compiler failed");
            }
            long compiler = ptr.get(0);
            Spvc.spvc_compiler_create_compiler_options(compiler, ptr);
            long opts = ptr.get(0);
            Spvc.spvc_compiler_options_set_uint(opts, Spvc.SPVC_COMPILER_OPTION_MSL_VERSION, 30100);
            Spvc.spvc_compiler_options_set_uint(opts, Spvc.SPVC_COMPILER_OPTION_MSL_PLATFORM, Spvc.SPVC_MSL_PLATFORM_MACOS);
            if (stage == Stage.VERTEX) {
                Spvc.spvc_compiler_options_set_bool(opts, Spvc.SPVC_COMPILER_OPTION_FLIP_VERTEX_Y, true);
            }
            Spvc.spvc_compiler_install_compiler_options(compiler, opts);
            if (Spvc.spvc_compiler_compile(compiler, ptr) != Spvc.SPVC_SUCCESS) {
                throw new IllegalStateException("SPIRV-Cross MSL compile failed");
            }
            return MemoryUtil.memUTF8(ptr.get(0));
        } finally {
            if (ctx != 0L) Spvc.spvc_context_destroy(ctx);
        }
    }
}
