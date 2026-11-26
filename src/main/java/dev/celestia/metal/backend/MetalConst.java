package dev.celestia.metal.backend;

import com.mojang.renderpearl.api.GpuFormat;
import com.mojang.renderpearl.api.pipeline.BlendFactor;
import com.mojang.renderpearl.api.pipeline.BlendOp;
import com.mojang.renderpearl.api.pipeline.CompareOp;
import com.mojang.renderpearl.api.pipeline.PrimitiveTopology;

/**
 * Numeric ABI constants matching {@code src/main/native/celestia_metal.h}.
 */
public final class MetalConst {
    public static final int ABI_VERSION = 8;

    // Global shader-suite slot reservations (matches celestia_metal.h & shade_slots.metal)
    public static final int SHADE_BUF_FRAME = 24;
    public static final int SHADE_BUF_LOOK = 25;
    public static final int SHADE_BUF_GPU = 26;
    public static final int SHADE_BUF_RESOURCES = 27;
    public static final int SHADE_BUF_WATER = 28;
    public static final int SHADE_BUF_BLOOM = 29;
    public static final int SHADE_TEX_SHADOW = 16;
    public static final int SHADE_TEX_SKY_LUT = 17;
    public static final int SHADE_TEX_WATER_SCENE = 18;
    public static final int SHADE_TEX_WATER_DEPTH = 19;
    public static final int SHADE_TEX_WATER_WAVES = 20;
    public static final int SHADE_TEX_WATER_PYR = 21;
    public static final int SHADE_TEX_WATER_DETAIL = 22;
    public static final int SHADE_BUF_DYNLIGHTS = 29;
    public static final int SHADE_TEX_DL_VIS = 23;
    public static final int SHADE_TEX_DL_IRR = 24;
    public static final int SHADE_TEX_DL_DIR = 25;
    public static final int SHADE_SAMP_SHADOW = 12;
    public static final int SHADE_SAMP_LINEAR = 13;
    public static final int SHADE_MAX_RES_TEX = 16;

    // cm_device_set_option ids (CMDeviceOption)
    public static final int OPT_PASS_MERGE = 0;
    public static final int OPT_DEFER_CLEARS = 1;

    // cm_device_stats indices (CMStatIndex)
    public static final int STAT_PASSES_BEGUN = 0;
    public static final int STAT_RENDER_ENCODERS = 1;
    public static final int STAT_PASSES_MERGED = 2;
    public static final int STAT_CLEARS_FOLDED = 3;
    public static final int STAT_CLEARS_FLUSHED = 4;
    public static final int STAT_DRAWS = 5;
    public static final int STAT_BLIT_ENCODERS = 6;
    public static final int STAT_FRAMES_SUBMITTED = 7;
    public static final int STAT_PRESENTS_SHOWN = 8;
    public static final int STAT_FRAMES_DROPPED = 9;
    public static final int STAT_WAIT_THROTTLE_US = 10;
    public static final int STAT_WAIT_FENCE_US = 11;
    public static final int STAT_WAIT_SLOT_US = 12;
    public static final int STAT_COUNT = 13;

    // CMFormat
    public static final int FMT_R8_UNORM = 0;
    public static final int FMT_R8_SNORM = 1;
    public static final int FMT_RG8_UNORM = 2;
    public static final int FMT_RG8_SNORM = 3;
    public static final int FMT_RGBA8_UNORM = 4;
    public static final int FMT_RGBA8_SNORM = 5;
    public static final int FMT_R16_UNORM = 6;
    public static final int FMT_R16_SNORM = 7;
    public static final int FMT_RG16_UNORM = 8;
    public static final int FMT_RG16_SNORM = 9;
    public static final int FMT_RGBA16_UNORM = 10;
    public static final int FMT_RGBA16_SNORM = 11;
    public static final int FMT_R8_UINT = 12;
    public static final int FMT_R8_SINT = 13;
    public static final int FMT_RG8_UINT = 14;
    public static final int FMT_RG8_SINT = 15;
    public static final int FMT_RGBA8_UINT = 16;
    public static final int FMT_RGBA8_SINT = 17;
    public static final int FMT_R16_UINT = 18;
    public static final int FMT_R16_SINT = 19;
    public static final int FMT_RG16_UINT = 20;
    public static final int FMT_RG16_SINT = 21;
    public static final int FMT_RGBA16_UINT = 22;
    public static final int FMT_RGBA16_SINT = 23;
    public static final int FMT_R32_UINT = 24;
    public static final int FMT_R32_SINT = 25;
    public static final int FMT_RG32_UINT = 26;
    public static final int FMT_RG32_SINT = 27;
    public static final int FMT_RGBA32_UINT = 28;
    public static final int FMT_RGBA32_SINT = 29;
    public static final int FMT_R16_FLOAT = 30;
    public static final int FMT_RG16_FLOAT = 31;
    public static final int FMT_RGBA16_FLOAT = 32;
    public static final int FMT_R32_FLOAT = 33;
    public static final int FMT_RG32_FLOAT = 34;
    public static final int FMT_RGBA32_FLOAT = 35;
    public static final int FMT_RGB10A2_UNORM = 36;
    public static final int FMT_RGB10A2_UINT = 37;
    public static final int FMT_RG11B10_FLOAT = 38;
    public static final int FMT_D32_FLOAT = 39;
    public static final int FMT_D32_FLOAT_S8_UINT = 40;
    public static final int FMT_D16_UNORM = 41;
    public static final int FMT_S8_UINT = 42;
    public static final int FMT_BGRA8_UNORM = 43;
    public static final int FMT_BGRA8_UNORM_SRGB = 44;
    public static final int FMT_RGBA8_UNORM_SRGB = 45;
    public static final int FMT_RGB8_UNORM = 46;
    public static final int FMT_RGB8_SNORM = 47;
    public static final int FMT_RGB16_UNORM = 48;
    public static final int FMT_RGB16_SNORM = 49;
    public static final int FMT_RGB8_UINT = 50;
    public static final int FMT_RGB8_SINT = 51;
    public static final int FMT_RGB16_UINT = 52;
    public static final int FMT_RGB16_SINT = 53;
    public static final int FMT_RGB32_UINT = 54;
    public static final int FMT_RGB32_SINT = 55;
    public static final int FMT_RGB16_FLOAT = 56;
    public static final int FMT_RGB32_FLOAT = 57;

    public static final int TOPO_POINTS = 0;
    public static final int TOPO_LINES = 1;
    public static final int TOPO_LINE_STRIP = 2;
    public static final int TOPO_TRIANGLES = 3;
    public static final int TOPO_TRIANGLE_STRIP = 4;
    public static final int TOPO_TRIANGLE_FAN = 5;

    private MetalConst() {}

    public static int toNativeFormat(GpuFormat format) {
        if (format == null) return -1;
        return switch (format) {
            case R8_UNORM -> FMT_R8_UNORM;
            case R8_SNORM -> FMT_R8_SNORM;
            case RG8_UNORM -> FMT_RG8_UNORM;
            case RG8_SNORM -> FMT_RG8_SNORM;
            case RGBA8_UNORM -> FMT_RGBA8_UNORM;
            case RGBA8_SNORM -> FMT_RGBA8_SNORM;
            case R16_UNORM -> FMT_R16_UNORM;
            case R16_SNORM -> FMT_R16_SNORM;
            case RG16_UNORM -> FMT_RG16_UNORM;
            case RG16_SNORM -> FMT_RG16_SNORM;
            case RGBA16_UNORM -> FMT_RGBA16_UNORM;
            case RGBA16_SNORM -> FMT_RGBA16_SNORM;
            case R8_UINT -> FMT_R8_UINT;
            case R8_SINT -> FMT_R8_SINT;
            case RG8_UINT -> FMT_RG8_UINT;
            case RG8_SINT -> FMT_RG8_SINT;
            case RGBA8_UINT -> FMT_RGBA8_UINT;
            case RGBA8_SINT -> FMT_RGBA8_SINT;
            case R16_UINT -> FMT_R16_UINT;
            case R16_SINT -> FMT_R16_SINT;
            case RG16_UINT -> FMT_RG16_UINT;
            case RG16_SINT -> FMT_RG16_SINT;
            case RGBA16_UINT -> FMT_RGBA16_UINT;
            case RGBA16_SINT -> FMT_RGBA16_SINT;
            case R32_UINT -> FMT_R32_UINT;
            case R32_SINT -> FMT_R32_SINT;
            case RG32_UINT -> FMT_RG32_UINT;
            case RG32_SINT -> FMT_RG32_SINT;
            case RGBA32_UINT -> FMT_RGBA32_UINT;
            case RGBA32_SINT -> FMT_RGBA32_SINT;
            case R16_FLOAT -> FMT_R16_FLOAT;
            case RG16_FLOAT -> FMT_RG16_FLOAT;
            case RGBA16_FLOAT -> FMT_RGBA16_FLOAT;
            case R32_FLOAT -> FMT_R32_FLOAT;
            case RG32_FLOAT -> FMT_RG32_FLOAT;
            case RGBA32_FLOAT -> FMT_RGBA32_FLOAT;
            case RGB10A2_UNORM -> FMT_RGB10A2_UNORM;
            case RGB10A2_UINT -> FMT_RGB10A2_UINT;
            case RG11B10_FLOAT -> FMT_RG11B10_FLOAT;
            case D32_FLOAT -> FMT_D32_FLOAT;
            case D32_FLOAT_S8_UINT -> FMT_D32_FLOAT_S8_UINT;
            case D16_UNORM -> FMT_D16_UNORM;
            case S8_UINT -> FMT_S8_UINT;
            case RGB8_UNORM, RGB8_SNORM, RGB16_UNORM, RGB16_SNORM,
                 RGB8_UINT, RGB8_SINT, RGB16_UINT, RGB16_SINT,
                 RGB32_UINT, RGB32_SINT, RGB16_FLOAT, RGB32_FLOAT,
                 D24_UNORM_S8_UINT -> {
                if (format == GpuFormat.D24_UNORM_S8_UINT) yield FMT_D32_FLOAT_S8_UINT;
                throw new IllegalArgumentException("Unsupported 3-component Metal texture format: " + format);
            }
        };
    }

    public static int toNativeVertexFormat(GpuFormat format) {
        return switch (format) {
            case R8_UNORM -> FMT_R8_UNORM;
            case R8_SNORM -> FMT_R8_SNORM;
            case RG8_UNORM -> FMT_RG8_UNORM;
            case RG8_SNORM -> FMT_RG8_SNORM;
            case RGB8_UNORM -> FMT_RGB8_UNORM;
            case RGB8_SNORM -> FMT_RGB8_SNORM;
            case RGBA8_UNORM -> FMT_RGBA8_UNORM;
            case RGBA8_SNORM -> FMT_RGBA8_SNORM;
            case R16_UNORM -> FMT_R16_UNORM;
            case R16_SNORM -> FMT_R16_SNORM;
            case RG16_UNORM -> FMT_RG16_UNORM;
            case RG16_SNORM -> FMT_RG16_SNORM;
            case RGB16_UNORM -> FMT_RGB16_UNORM;
            case RGB16_SNORM -> FMT_RGB16_SNORM;
            case RGBA16_UNORM -> FMT_RGBA16_UNORM;
            case RGBA16_SNORM -> FMT_RGBA16_SNORM;
            case R8_UINT -> FMT_R8_UINT;
            case R8_SINT -> FMT_R8_SINT;
            case RG8_UINT -> FMT_RG8_UINT;
            case RG8_SINT -> FMT_RG8_SINT;
            case RGB8_UINT -> FMT_RGB8_UINT;
            case RGB8_SINT -> FMT_RGB8_SINT;
            case RGBA8_UINT -> FMT_RGBA8_UINT;
            case RGBA8_SINT -> FMT_RGBA8_SINT;
            case R16_UINT -> FMT_R16_UINT;
            case R16_SINT -> FMT_R16_SINT;
            case RG16_UINT -> FMT_RG16_UINT;
            case RG16_SINT -> FMT_RG16_SINT;
            case RGB16_UINT -> FMT_RGB16_UINT;
            case RGB16_SINT -> FMT_RGB16_SINT;
            case RGBA16_UINT -> FMT_RGBA16_UINT;
            case RGBA16_SINT -> FMT_RGBA16_SINT;
            case R32_UINT -> FMT_R32_UINT;
            case R32_SINT -> FMT_R32_SINT;
            case RG32_UINT -> FMT_RG32_UINT;
            case RG32_SINT -> FMT_RG32_SINT;
            case RGB32_UINT -> FMT_RGB32_UINT;
            case RGB32_SINT -> FMT_RGB32_SINT;
            case RGBA32_UINT -> FMT_RGBA32_UINT;
            case RGBA32_SINT -> FMT_RGBA32_SINT;
            case R16_FLOAT -> FMT_R16_FLOAT;
            case RG16_FLOAT -> FMT_RG16_FLOAT;
            case RGB16_FLOAT -> FMT_RGB16_FLOAT;
            case RGBA16_FLOAT -> FMT_RGBA16_FLOAT;
            case R32_FLOAT -> FMT_R32_FLOAT;
            case RG32_FLOAT -> FMT_RG32_FLOAT;
            case RGB32_FLOAT -> FMT_RGB32_FLOAT;
            case RGBA32_FLOAT -> FMT_RGBA32_FLOAT;
            case RGB10A2_UNORM -> FMT_RGB10A2_UNORM;
            default -> throw new IllegalArgumentException("Unsupported vertex attribute format: " + format);
        };
    }

    public static int toNativeCompare(CompareOp op) {
        return switch (op) {
            case ALWAYS_PASS -> 0;
            case LESS_THAN -> 1;
            case LESS_THAN_OR_EQUAL -> 2;
            case EQUAL -> 3;
            case NOT_EQUAL -> 4;
            case GREATER_THAN_OR_EQUAL -> 5;
            case GREATER_THAN -> 6;
            case NEVER_PASS -> 7;
        };
    }

    public static int toNativeBlendFactor(BlendFactor f) {
        return switch (f) {
            case ZERO -> 0;
            case ONE -> 1;
            case SRC_COLOR -> 2;
            case ONE_MINUS_SRC_COLOR -> 3;
            case DST_COLOR -> 4;
            case ONE_MINUS_DST_COLOR -> 5;
            case SRC_ALPHA -> 6;
            case ONE_MINUS_SRC_ALPHA -> 7;
            case DST_ALPHA -> 8;
            case ONE_MINUS_DST_ALPHA -> 9;
            case CONSTANT_COLOR -> 10;
            case ONE_MINUS_CONSTANT_COLOR -> 11;
            case CONSTANT_ALPHA -> 12;
            case ONE_MINUS_CONSTANT_ALPHA -> 13;
            case SRC_ALPHA_SATURATE -> 14;
        };
    }

    public static int toNativeBlendOp(BlendOp op) {
        return switch (op) {
            case ADD -> 0;
            case SUBTRACT -> 1;
            case REVERSE_SUBTRACT -> 2;
            case MIN -> 3;
            case MAX -> 4;
        };
    }

    public static int toNativeTopology(PrimitiveTopology topo) {
        return switch (topo) {
            case POINTS -> TOPO_POINTS;
            case LINES, DEBUG_LINES -> TOPO_LINES;
            case DEBUG_LINE_STRIP -> TOPO_LINE_STRIP;
            case TRIANGLES, QUADS -> TOPO_TRIANGLES;
            case TRIANGLE_STRIP -> TOPO_TRIANGLE_STRIP;
            case TRIANGLE_FAN -> TOPO_TRIANGLE_FAN;
        };
    }
}
