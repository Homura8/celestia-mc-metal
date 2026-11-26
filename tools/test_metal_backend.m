#import "celestia_metal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>

typedef struct CelestiaFrameUniformsC {
    float viewProj[16];
    float invViewProj[16];
    float prevViewProj[16];
    float shadowViewProjNear[16];
    float shadowViewProjFar[16];
    float cameraPosTime[4];
    float sunDirDaylight[4];
    float weatherState[4];
    float skyColorFrame[4];
    float fogColorElevation[4];
    float fogRanges[4];
    float resolutionParams[4];
    float qualityFlags[4];
} CelestiaFrameUniformsC;

static void set_identity(float m[16]) {
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static NSString *read_file_str(NSString *path) {
    NSError *err = nil;
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!s) {
        fprintf(stderr, "FAIL: could not read %s: %s\n", path.UTF8String, err.localizedDescription.UTF8String);
        exit(1);
    }
    return s;
}

static void verify_backend_ops(int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 1, "");
    assert(ctx != 0);
    int isM4 = cm_device_is_metal4(ctx);
    printf("[Backend %s] initialized (metal4=%d)\n", preferMetal4 ? "Metal 4" : "Metal 3", isM4);

    // 1. Buffer write & blit copy verification
    uint32_t srcPattern[16];
    for (int i = 0; i < 16; i++) srcPattern[i] = 0xCAFE0000u + (uint32_t)i;
    int64_t srcBuf = cm_buffer_create(ctx, sizeof(srcPattern), srcPattern, "SrcBuf");
    int64_t dstBuf = cm_buffer_create(ctx, sizeof(srcPattern), NULL, "DstBuf");
    assert(srcBuf && dstBuf);

    cm_cmd_begin(ctx);
    cm_blit_copy_buffer(ctx, srcBuf, 0, dstBuf, 0, sizeof(srcPattern));
    uint64_t s1 = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s1, 5000000000ULL) == 1);

    uint32_t *dstPtr = (uint32_t *)(uintptr_t)cm_buffer_contents(dstBuf);
    for (int i = 0; i < 16; i++) {
        assert(dstPtr[i] == srcPattern[i]);
    }

    // 2. Render pass + depth reversed-Z + readback verification
    int64_t ctex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 64, 64, 1, 1, 0, 1, 1, 0, "TestRT");
    int64_t cview = cm_texture_view_create(ctx, ctex, 0, 1);
    int64_t dtex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 64, 64, 1, 1, 0, 1, 1, 0, "TestDepth");
    int64_t dview = cm_texture_view_create(ctx, dtex, 0, 1);
    int64_t readBuf = cm_buffer_create(ctx, 64 * 64 * 4, NULL, "ReadbackBuf");

    const char *simpleMsl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VOut { float4 pos [[position]]; };\n"
        "vertex VOut vs_main(uint vid [[vertex_id]]) {\n"
        "  VOut o; float2 p = float2((vid==1)?3.0f:-1.0f, (vid==2)?3.0f:-1.0f);\n"
        "  o.pos = float4(p, 0.5f, 1.0f); return o;\n"
        "}\n"
        "fragment half4 fs_main() { return half4(0.75h, 0.50h, 0.90h, 1.0h); }\n";
    char err[2048] = {0};
    int64_t lib = cm_compile_msl_library(ctx, simpleMsl, "smoke", 0, err, sizeof(err));
    assert(lib != 0);
    int64_t vs = cm_compile_function(lib, "vs_main", 0, 0, 0, err, sizeof(err));
    int64_t fs = cm_compile_function(lib, "fs_main", 0, 0, 0, err, sizeof(err));
    CMColorAttachmentDesc colDesc = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pso = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &colDesc, 1,
                                            CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                            CM_CMP_GREATER_EQUAL, 1, 0.0f, 0.0f, "SmokePSO", err, sizeof(err));
    assert(pso != 0);

    int32_t clearFlag = 1;
    float clearCol[4] = {0.0f, 0.0f, 0.0f, 1.0f};
    cm_cmd_begin(ctx);
    assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, dview, 1, 0.0, 0, 0, 64, 64, "SmokePass") == 1);
    cm_pass_set_pipeline(ctx, pso);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_end(ctx);
    cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
    uint64_t s2 = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2, 5000000000ULL) == 1);

    uint8_t *px = (uint8_t *)(uintptr_t)cm_buffer_contents(readBuf);
    assert(px[0] > 180 && px[1] > 120 && px[2] > 220 && px[3] == 255);

    // 2b. RGB32_FLOAT + RGB8_SNORM vertex attributes & texture_buffer (TEXEL_BUFFER) verification
    typedef struct __attribute__((packed)) TestVertex {
        float x, y, z;
        int8_t r, g, b;
        uint8_t pad;
    } TestVertex;
    TestVertex verts[3] = {
        { -1.0f, -1.0f, 0.5f, 0, 127, 0, 0 },
        {  3.0f, -1.0f, 0.5f, 0, 127, 0, 0 },
        { -1.0f,  3.0f, 0.5f, 0, 127, 0, 0 },
    };
    int64_t vbo = cm_buffer_create(ctx, sizeof(verts), verts, "TestRGBFloat3VBO");
    uint8_t tbBytes[64] = {0};
    tbBytes[4] = 204; tbBytes[5] = 0; tbBytes[6] = 153; tbBytes[7] = 255;
    int64_t tbBuf = cm_buffer_create(ctx, sizeof(tbBytes), tbBytes, "TestTexelBuf");
    int64_t tbView = cm_texture_buffer_create(ctx, tbBuf, 4, 4, CM_FMT_RGBA8_UNORM);
    assert(vbo != 0 && tbBuf != 0 && tbView != 0);

    const char *vtxTexelMsl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VIn {\n"
        "  float3 pos [[attribute(0)]];\n"
        "  float3 col [[attribute(1)]];\n"
        "};\n"
        "struct VOut { float4 pos [[position]]; float3 col; };\n"
        "vertex VOut vs_vtx(VIn in [[stage_in]]) {\n"
        "  VOut o; o.pos = float4(in.pos, 1.0f); o.col = in.col; return o;\n"
        "}\n"
        "fragment half4 fs_vtx(VOut in [[stage_in]], texture_buffer<float, access::read> tb [[texture(0)]]) {\n"
        "  float4 t = tb.read(0u);\n"
        "  return half4(half(t.r), half(in.col.g), half(t.b), half(t.a));\n"
        "}\n";
    int64_t libVtx = cm_compile_msl_library(ctx, vtxTexelMsl, "vtx_texel", 0, err, sizeof(err));
    if (!libVtx) fprintf(stderr, "vtxTexelMsl compile error: %s\n", err);
    assert(libVtx != 0);
    int64_t vsVtx = cm_compile_function(libVtx, "vs_vtx", 0, 0, 0, err, sizeof(err));
    int64_t fsVtx = cm_compile_function(libVtx, "fs_vtx", 0, 0, 0, err, sizeof(err));
    CMVertexBufferDesc vbDesc = { 0, (int32_t)sizeof(TestVertex), 0 };
    CMAttribBindingDesc attrDescs[2] = {
        { 0, 0, 0, CM_FMT_RGB32_FLOAT },
        { 0, 1, 12, CM_FMT_RGB8_SNORM }
    };
    int64_t psoVtx = cm_render_pipeline_create(ctx, vsVtx, fsVtx, &vbDesc, 1, attrDescs, 2, &colDesc, 1,
                                               -1, CM_TOPO_TRIANGLES, 0, 0, 0,
                                               CM_CMP_ALWAYS, 0, 0.0f, 0.0f, "VtxTexelPSO", err, sizeof(err));
    if (!psoVtx) fprintf(stderr, "VtxTexelPSO error: %s\n", err);
    assert(psoVtx != 0);

    cm_cmd_begin(ctx);
    assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, 0, 0, 0.0, 0, 0, 64, 64, "VtxTexelPass") == 1);
    cm_pass_set_pipeline(ctx, psoVtx);
    cm_pass_set_vertex_buffer(ctx, 0, vbo, 0, (int32_t)sizeof(TestVertex));
    cm_pass_set_texture_sampler(ctx, 0, tbView, -1, 0);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_end(ctx);
    cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
    uint64_t s2b = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2b, 5000000000ULL) == 1);
    assert(abs((int)px[0] - 204) <= 2 && px[1] >= 253 && abs((int)px[2] - 153) <= 2 && px[3] == 255);

    cm_pipeline_destroy(ctx, psoVtx);
    cm_function_destroy(fsVtx);
    cm_function_destroy(vsVtx);
    cm_library_destroy(libVtx);
    cm_texture_view_destroy(ctx, tbView);
    cm_buffer_destroy(ctx, tbBuf);
    cm_buffer_destroy(ctx, vbo);

    // 2c. Depth-writing fragment shader with D32_FLOAT and combined Depth32Float_Stencil8
    int64_t dsTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT_S8_UINT, 64, 64, 1, 1, 0, 1, 1, 0, "TestDepthStencil");
    int64_t dsView = cm_texture_view_create(ctx, dsTex, 0, 1);
    assert(dsTex && dsView);
    const char *depthWriteMsl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VOut { float4 pos [[position]]; };\n"
        "struct FOut { half4 col [[color(0)]]; float depth [[depth(any)]]; };\n"
        "vertex VOut vs_dw(uint vid [[vertex_id]]) {\n"
        "  VOut o; float2 p = float2((vid==1)?3.0f:-1.0f, (vid==2)?3.0f:-1.0f); o.pos = float4(p, 0.5f, 1.0f); return o;\n"
        "}\n"
        "fragment FOut fs_dw() {\n"
        "  FOut o; o.col = half4(0.25h, 0.75h, 0.50h, 1.0h); o.depth = 0.25f; return o;\n"
        "}\n";
    int64_t libDw = cm_compile_msl_library(ctx, depthWriteMsl, "depth_write", 0, err, sizeof(err));
    assert(libDw != 0);
    int64_t vsDw = cm_compile_function(libDw, "vs_dw", 0, 0, 0, err, sizeof(err));
    int64_t fsDw = cm_compile_function(libDw, "fs_dw", 0, 0, 0, err, sizeof(err));
    int64_t psoDwD32 = cm_render_pipeline_create(ctx, vsDw, fsDw, NULL, 0, NULL, 0, &colDesc, 1,
                                                 CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                                 CM_CMP_ALWAYS, 1, 0.0f, 0.0f, "DepthWriteD32", err, sizeof(err));
    int64_t psoDwDS = cm_render_pipeline_create(ctx, vsDw, fsDw, NULL, 0, NULL, 0, &colDesc, 1,
                                                CM_FMT_D32_FLOAT_S8_UINT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                                CM_CMP_ALWAYS, 1, 0.0f, 0.0f, "DepthWriteDS", err, sizeof(err));
    assert(psoDwD32 != 0 && psoDwDS != 0);

    cm_cmd_begin(ctx);
    assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, dview, 1, 0.0, 0, 0, 64, 64, "DwD32Pass") == 1);
    cm_pass_set_pipeline(ctx, psoDwD32);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_end(ctx);
    assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, dsView, 1, 0.0, 0, 0, 64, 64, "DwDSPass") == 1);
    cm_pass_set_pipeline(ctx, psoDwDS);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_end(ctx);
    uint64_t s2c = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2c, 5000000000ULL) == 1);

    cm_pipeline_destroy(ctx, psoDwDS);
    cm_pipeline_destroy(ctx, psoDwD32);
    cm_function_destroy(fsDw);
    cm_function_destroy(vsDw);
    cm_library_destroy(libDw);
    cm_texture_view_destroy(ctx, dsView);
    cm_texture_destroy(ctx, dsTex);

    // 2d. Sub-rect R8_UNORM glyph upload & cubemap 6-slice upload verification
    int64_t r8Tex = cm_texture_create(ctx, CM_FMT_R8_UNORM, 16, 16, 1, 1, 0, 0, 1, 0, "FontAtlasR8");
    int64_t cubeTex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 8, 8, 6, 1, 1, 0, 1, 0, "PanoramaCube");
    uint8_t r8Src[256];
    for (int i = 0; i < 256; i++) r8Src[i] = (uint8_t)i;
    uint8_t cubeSrc[8 * 8 * 4];
    memset(cubeSrc, 0xAB, sizeof(cubeSrc));
    int64_t r8Stage = cm_buffer_create(ctx, sizeof(r8Src), r8Src, "R8Stage");
    int64_t cubeStage = cm_buffer_create(ctx, sizeof(cubeSrc), cubeSrc, "CubeStage");
    int64_t r8Out = cm_buffer_create(ctx, 16, NULL, "R8Out");
    assert(r8Tex && cubeTex && r8Stage && cubeStage && r8Out);

    cm_cmd_begin(ctx);
    cm_blit_copy_buffer_to_texture(ctx, r8Stage, 8 * 16 + 8, 16, r8Tex, 0, 0, 4, 4, 4, 4);
    for (int f = 0; f < 6; f++) {
        cm_blit_copy_buffer_to_texture(ctx, cubeStage, 0, 8 * 4, cubeTex, 0, f, 0, 0, 8, 8);
    }
    cm_blit_copy_texture_to_buffer(ctx, r8Tex, 0, 0, 4, 4, 4, 4, r8Out, 0, 4);
    uint64_t s2d = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2d, 5000000000ULL) == 1);
    uint8_t *r8Read = (uint8_t *)(uintptr_t)cm_buffer_contents(r8Out);
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            assert(r8Read[row * 4 + col] == (uint8_t)((8 + row) * 16 + (8 + col)));
        }
    }
    cm_buffer_destroy(ctx, r8Out);
    cm_buffer_destroy(ctx, cubeStage);
    cm_buffer_destroy(ctx, r8Stage);
    cm_texture_destroy(ctx, cubeTex);
    cm_texture_destroy(ctx, r8Tex);

    // 2e. Metal 4 clear->load barrier, cmd_has_active, and persistent TRIANGLE_FAN index buffer preservation
    assert(cm_cmd_has_active(ctx) == 0);
    cm_cmd_begin(ctx);
    assert(cm_cmd_has_active(ctx) == 1);
    uint64_t s2eIdle = cm_cmd_submit(ctx, 2);
    assert(cm_cmd_has_active(ctx) == 0);
    assert(cm_wait_submit(ctx, s2eIdle, 5000000000ULL) == 1);

    const char *fanMsl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VIn { float4 pos [[attribute(0)]]; };\n"
        "struct VOut { float4 pos [[position]]; };\n"
        "vertex VOut vs_fan(VIn in [[stage_in]]) { VOut o; o.pos = in.pos; return o; }\n"
        "fragment half4 fs_sky() { return half4(0.40h, 0.70h, 1.00h, 1.00h); }\n"
        "fragment half4 fs_mark() { return half4(0.00h, 1.00h, 0.25h, 1.00h); }\n";
    int64_t libFan = cm_compile_msl_library(ctx, fanMsl, "fan_test", 0, err, sizeof(err));
    assert(libFan != 0);
    int64_t vsFan = cm_compile_function(libFan, "vs_fan", 0, 0, 0, err, sizeof(err));
    int64_t fsSky = cm_compile_function(libFan, "fs_sky", 0, 0, 0, err, sizeof(err));
    int64_t fsMark = cm_compile_function(libFan, "fs_mark", 0, 0, 0, err, sizeof(err));
    CMVertexBufferDesc fanVbDesc = { 0, 16, 0 };
    CMAttribBindingDesc fanAttr = { 0, 0, 0, CM_FMT_RGBA32_FLOAT };
    int64_t psoFanSky = cm_render_pipeline_create(ctx, vsFan, fsSky, &fanVbDesc, 1, &fanAttr, 1, &colDesc, 1,
                                                  CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLE_FAN, 0, 0, 1,
                                                  CM_CMP_GREATER_EQUAL, 0, 0.0f, 0.0f, "FanSkyPSO", err, sizeof(err));
    int64_t psoAfterFan = cm_render_pipeline_create(ctx, vsFan, fsMark, &fanVbDesc, 1, &fanAttr, 1, &colDesc, 1,
                                                    CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                                    CM_CMP_GREATER_EQUAL, 0, 0.0f, 0.0f, "AfterFanPSO", err, sizeof(err));
    assert(psoFanSky && psoAfterFan);

    // Offset slot 0 unused so firstVertex = 1 is also verified for TRIANGLE_FAN
    float fanVerts[5 * 4] = {
        9.0f,  9.0f, 0.5f, 1.0f,
       -1.0f, -1.0f, 0.5f, 1.0f,
       -1.0f,  1.0f, 0.5f, 1.0f,
        1.0f,  1.0f, 0.5f, 1.0f,
        1.0f, -1.0f, 0.5f, 1.0f,
    };
    float markVerts[3 * 4] = {
       -1.0f, 1.0f, 0.5f, 1.0f,
       -0.5f, 1.0f, 0.5f, 1.0f,
       -1.0f, 0.5f, 0.5f, 1.0f,
    };
    uint32_t markIdx[3] = { 0, 1, 2 };
    int64_t fanVbo = cm_buffer_create(ctx, sizeof(fanVerts), fanVerts, "FanVbo");
    int64_t markVbo = cm_buffer_create(ctx, sizeof(markVerts), markVerts, "MarkVbo");
    int64_t markIbo = cm_buffer_create(ctx, sizeof(markIdx), markIdx, "MarkIbo");
    assert(fanVbo && markVbo && markIbo);

    int32_t loadFlag = 0;
    for (int iter = 0; iter < 16; iter++) {
        cm_cmd_begin(ctx);
        if ((iter & 1) == 0) {
            cm_blit_clear_color_depth(ctx, ctex, 1.0f, 0.0f, 0.0f, 1.0f, dtex, 0.0);
        } else {
            cm_blit_clear_color(ctx, ctex, 1.0f, 0.0f, 0.0f, 1.0f);
            cm_blit_clear_depth(ctx, dtex, 0.0);
        }
        assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "SkyLoadPass") == 1);
        cm_pass_set_index_buffer(ctx, markIbo, 1);
        cm_pass_set_pipeline(ctx, psoFanSky);
        cm_pass_set_vertex_buffer(ctx, 0, fanVbo, 0, 16);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLE_FAN, 4, 1, 1, 0);
        cm_pass_set_pipeline(ctx, psoAfterFan);
        cm_pass_set_vertex_buffer(ctx, 0, markVbo, 0, 16);
        cm_pass_draw_indexed(ctx, CM_TOPO_TRIANGLES, 0, 3, 1, 0, 0, 0);
        cm_pass_end(ctx);
        cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
        uint64_t s2e = cm_cmd_submit(ctx, 2);
        assert(cm_wait_submit(ctx, s2e, 5000000000ULL) == 1);

        // Center pixel (32, 32) must be sky-blue, never red from a racing clear
        size_t center = ((size_t)32 * 64u + 32u) * 4u;
        assert(abs((int)px[center + 0] - 102) <= 3 && abs((int)px[center + 1] - 179) <= 3 && px[center + 2] >= 252);
        // Top-left pixel (0, 0) must be green mark from markIbo, proving TRIANGLE_FAN didn't clobber boundIndexBuffer
        assert(px[0] <= 3 && px[1] >= 252 && abs((int)px[2] - 64) <= 3);
    }

    cm_buffer_destroy(ctx, markIbo);
    cm_buffer_destroy(ctx, markVbo);
    cm_buffer_destroy(ctx, fanVbo);
    cm_pipeline_destroy(ctx, psoAfterFan);
    cm_pipeline_destroy(ctx, psoFanSky);
    cm_function_destroy(fsMark);
    cm_function_destroy(fsSky);
    cm_function_destroy(vsFan);
    cm_library_destroy(libFan);

    // 2f. Chained BufferArena upload->resize blits and overlapping memmove-safe buffer copies
    const uint32_t arenaCount = 4096;
    const size_t arenaBytes = arenaCount * sizeof(uint32_t);
    int64_t blitStage = cm_buffer_create(ctx, arenaBytes, NULL, "BlitStage");
    int64_t blitArenaA = cm_buffer_create(ctx, arenaBytes, NULL, "BlitArenaA");
    int64_t blitArenaB = cm_buffer_create(ctx, arenaBytes, NULL, "BlitArenaB");
    assert(blitStage && blitArenaA && blitArenaB);
    uint32_t *stageU32 = (uint32_t *)(uintptr_t)cm_buffer_contents(blitStage);
    uint32_t *arenaBU32 = (uint32_t *)(uintptr_t)cm_buffer_contents(blitArenaB);
    for (int iter = 0; iter < 8; iter++) {
        uint32_t seed = (uint32_t)(0x10000000u + (uint32_t)iter * 0x01000000u);
        for (uint32_t i = 0; i < arenaCount; i++) {
            stageU32[i] = seed + i;
            arenaBU32[i] = 0xDEAD0000u;
        }
        cm_cmd_begin(ctx);
        cm_blit_copy_buffer(ctx, blitStage, 0, blitArenaA, 0, arenaBytes);
        cm_blit_copy_buffer(ctx, blitArenaA, 0, blitArenaB, 0, arenaBytes);
        uint64_t s2f = cm_cmd_submit(ctx, 2);
        assert(cm_wait_submit(ctx, s2f, 5000000000ULL) == 1);
        for (uint32_t i = 0; i < arenaCount; i++) {
            assert(arenaBU32[i] == seed + i);
        }
    }

    int64_t overlapBuf = cm_buffer_create(ctx, 512, NULL, "OverlapBuf");
    assert(overlapBuf != 0);
    uint8_t *ov = (uint8_t *)(uintptr_t)cm_buffer_contents(overlapBuf);
    for (int i = 0; i < 512; i++) ov[i] = (uint8_t)(i & 0xFF);
    // Shift left: [64, 320) -> [32, 288)
    cm_cmd_begin(ctx);
    cm_blit_copy_buffer(ctx, overlapBuf, 64, overlapBuf, 32, 256);
    uint64_t s2fL = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2fL, 5000000000ULL) == 1);
    for (int i = 0; i < 256; i++) {
        assert(ov[32 + i] == (uint8_t)((64 + i) & 0xFF));
    }
    // Reset & shift right: [32, 288) -> [64, 320)
    for (int i = 0; i < 512; i++) ov[i] = (uint8_t)(i & 0xFF);
    cm_cmd_begin(ctx);
    cm_blit_copy_buffer(ctx, overlapBuf, 32, overlapBuf, 64, 256);
    uint64_t s2fR = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s2fR, 5000000000ULL) == 1);
    for (int i = 0; i < 256; i++) {
        assert(ov[64 + i] == (uint8_t)((32 + i) & 0xFF));
    }
    cm_buffer_destroy(ctx, overlapBuf);
    cm_buffer_destroy(ctx, blitArenaB);
    cm_buffer_destroy(ctx, blitArenaA);
    cm_buffer_destroy(ctx, blitStage);

    // 3. MetalFX Spatial & Temporal scaler creation + execution
    int64_t mfxOut = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 128, 128, 1, 1, 0, 1, 1, 1, "MFXOut");
    int64_t mfxIn = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 64, 64, 1, 1, 0, 1, 1, 0, "MFXIn");
    int64_t mfxMotion = cm_texture_create(ctx, CM_FMT_RG16_FLOAT, 64, 64, 1, 1, 0, 1, 1, 0, "MFXMotion");
    int64_t spatial = cm_upscaler_create(ctx, 0, CM_FMT_RGBA16_FLOAT, CM_FMT_RGBA16_FLOAT, 64, 64, 128, 128, 0);
    int64_t temporal = cm_upscaler_create(ctx, 1, CM_FMT_RGBA16_FLOAT, CM_FMT_RGBA16_FLOAT, 64, 64, 128, 128, 0);
    assert(spatial != 0);
    assert(temporal != 0);
    cm_cmd_begin(ctx);
    cm_upscaler_encode(ctx, spatial, mfxIn, 0, 0, mfxOut, 0.0f, 0.0f, 0);
    cm_upscaler_encode(ctx, temporal, mfxIn, dtex, mfxMotion, mfxOut, 0.25f, -0.25f, 1);
    uint64_t s3 = cm_cmd_submit(ctx, 2);
    assert(cm_wait_submit(ctx, s3, 5000000000ULL) == 1);

    char drained[1024] = {0};
    int errCnt = cm_device_drain_errors(ctx, drained, sizeof(drained));
    if (errCnt > 0) {
        fprintf(stderr, "FAIL: GPU reported errors: %s\n", drained);
        exit(1);
    }

    cm_upscaler_destroy(ctx, spatial);
    cm_upscaler_destroy(ctx, temporal);
    cm_texture_destroy(ctx, mfxOut);
    cm_texture_destroy(ctx, mfxIn);
    cm_texture_destroy(ctx, mfxMotion);
    cm_pipeline_destroy(ctx, pso);
    cm_function_destroy(fs);
    cm_function_destroy(vs);
    cm_library_destroy(lib);
    cm_buffer_destroy(ctx, readBuf);
    cm_texture_view_destroy(ctx, dview);
    cm_texture_destroy(ctx, dtex);
    cm_texture_view_destroy(ctx, cview);
    cm_texture_destroy(ctx, ctex);
    cm_buffer_destroy(ctx, dstBuf);
    cm_buffer_destroy(ctx, srcBuf);
    cm_device_destroy(ctx);
    printf("[Backend %s] ALL CHECKS PASSED\n", preferMetal4 ? "Metal 4" : "Metal 3");
}

static int64_t compile_pack_shader(int64_t ctx, NSString *commonSrc, NSString *defines, NSString *path) {
    NSString *body = read_file_str(path);
    NSString *full = [NSString stringWithFormat:@"%@\n%@\n%@", defines, commonSrc, body];
    char err[4096] = {0};
    int64_t lib = cm_compile_msl_library(ctx, full.UTF8String, path.lastPathComponent.UTF8String, 1, err, sizeof(err));
    if (!lib) {
        fprintf(stderr, "FAIL compiling %s:\n%s\n", path.UTF8String, err);
        exit(1);
    }
    return lib;
}

static void benchmark_native_pipelines(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    const char *apiLabel = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *common = read_file_str([assetsDir stringByAppendingPathComponent:@"shaders/celestia_common.metal"]);
    NSString *nativeDir = [assetsDir stringByAppendingPathComponent:@"shaderpacks/celestia-native"];
    NSString *minimalDir = [assetsDir stringByAppendingPathComponent:@"shaderpacks/celestia-minimal"];

    // Verify compilation across all Celestia Native presets (only print once on Metal 4 pass)
    const char *presetDefines[] = {
        "#define SHADOWS_ENABLED 1\n#define SHADOW_RES 1024\n#define SHADOW_PCF_TAPS 4\n#define SSAO_ENABLED 0\n#define DYNAMIC_LIGHTS 1\n#define SKY_SCATTERING_STEPS 4\n#define STARFIELD_ENABLED 1\n#define AERIAL_FOG 1\n#define WATER_WAVES 1\n#define WATER_REFLECTIONS 1\n#define WATER_CAUSTICS 0\n#define CLOUDS_ENABLED 1\n#define CLOUD_STEPS 8\n#define GOD_RAYS 0\n#define BLOOM_ENABLED 1\n#define BLOOM_STRENGTH 0.18f\n#define TONEMAP_CURVE 2\n#define EXPOSURE 1.0f\n#define SATURATION 1.06f\n#define HDR_EDR_BOOST 1.2f\n",
        "#define SHADOWS_ENABLED 1\n#define SHADOW_RES 2048\n#define SHADOW_PCF_TAPS 9\n#define SSAO_ENABLED 1\n#define DYNAMIC_LIGHTS 1\n#define SKY_SCATTERING_STEPS 8\n#define STARFIELD_ENABLED 1\n#define AERIAL_FOG 1\n#define WATER_WAVES 1\n#define WATER_REFLECTIONS 2\n#define WATER_CAUSTICS 1\n#define CLOUDS_ENABLED 1\n#define CLOUD_STEPS 14\n#define GOD_RAYS 1\n#define BLOOM_ENABLED 1\n#define BLOOM_STRENGTH 0.24f\n#define TONEMAP_CURVE 0\n#define EXPOSURE 1.05f\n#define SATURATION 1.08f\n#define HDR_EDR_BOOST 1.35f\n",
        "#define SHADOWS_ENABLED 1\n#define SHADOW_RES 4096\n#define SHADOW_PCF_TAPS 16\n#define SSAO_ENABLED 1\n#define DYNAMIC_LIGHTS 1\n#define SKY_SCATTERING_STEPS 16\n#define STARFIELD_ENABLED 1\n#define AERIAL_FOG 1\n#define WATER_WAVES 1\n#define WATER_REFLECTIONS 2\n#define WATER_CAUSTICS 1\n#define CLOUDS_ENABLED 1\n#define CLOUD_STEPS 28\n#define GOD_RAYS 1\n#define BLOOM_ENABLED 1\n#define BLOOM_STRENGTH 0.32f\n#define TONEMAP_CURVE 1\n#define EXPOSURE 1.10f\n#define SATURATION 1.12f\n#define HDR_EDR_BOOST 1.60f\n"
    };
    NSArray<NSString *> *nativeFiles = @[@"sky_lut.metal", @"shadow_pass.metal", @"deferred_lighting.metal",
                                         @"water_surface.metal", @"volumetric_clouds.metal", @"bloom.metal", @"tonemap_composite.metal"];
    if (preferMetal4) {
        for (int p = 0; p < 3; p++) {
            for (NSString *fn in nativeFiles) {
                int64_t l = compile_pack_shader(ctx, common, [NSString stringWithUTF8String:presetDefines[p]],
                                                [nativeDir stringByAppendingPathComponent:fn]);
                cm_library_destroy(l);
            }
        }
    }

    NSString *minDefines = @"#define WARM_TORCHLIGHT 1\n#define AERIAL_FOG 1\n#define WATER_SPECULAR 1\n#define EXPOSURE 1.05f\n#define SATURATION 1.08f\n";
    if (preferMetal4) {
        for (NSString *fn in @[@"sky_lut.metal", @"fast_lighting.metal", @"water_minimal.metal", @"tonemap_minimal.metal"]) {
            int64_t l = compile_pack_shader(ctx, common, minDefines, [minimalDir stringByAppendingPathComponent:fn]);
            cm_library_destroy(l);
        }
        printf("[Shaders] Compiled ALL Celestia Native (3 presets) and Celestia Minimal shaders on M1 Pro GPU with 0 errors!\n");
    }

    // End-to-end 3024x1752 Balanced pipeline GPU benchmark
    const int W = 3024, H = 1752;
    NSString *balDef = [NSString stringWithUTF8String:presetDefines[1]];
    int64_t lSky = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"sky_lut.metal"]);
    int64_t lDef = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"deferred_lighting.metal"]);
    int64_t lWat = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"water_surface.metal"]);
    int64_t lCld = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"volumetric_clouds.metal"]);
    int64_t lBlm = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"bloom.metal"]);
    int64_t lTon = compile_pack_shader(ctx, common, balDef, [nativeDir stringByAppendingPathComponent:@"tonemap_composite.metal"]);

    char err[2048] = {0};
    int64_t fnSky = cm_compile_function(lSky, "celestia_sky_lut_cs", 0, 0, 0, err, sizeof(err));
    int64_t fnCld = cm_compile_function(lCld, "celestia_clouds_cs", 0, 0, 0, err, sizeof(err));
    int64_t fnBlm = cm_compile_function(lBlm, "celestia_bloom_down_cs", 0, 0, 0, err, sizeof(err));
    int64_t pSky = cm_compute_pipeline_create(ctx, fnSky, "sky_lut", err, sizeof(err));
    int64_t pCld = cm_compute_pipeline_create(ctx, fnCld, "clouds", err, sizeof(err));
    int64_t pBlm = cm_compute_pipeline_create(ctx, fnBlm, "bloom", err, sizeof(err));

    CMColorAttachmentDesc f16Desc = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t vsDef = cm_compile_function(lDef, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsDef = cm_compile_function(lDef, "celestia_deferred_fs", 0, 0, 0, err, sizeof(err));
    int64_t pDef = cm_render_pipeline_create(ctx, vsDef, fsDef, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "def", err, sizeof(err));

    int64_t vsWat = cm_compile_function(lWat, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsWat = cm_compile_function(lWat, "celestia_water_fs", 0, 0, 0, err, sizeof(err));
    int64_t pWat = cm_render_pipeline_create(ctx, vsWat, fsWat, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "wat", err, sizeof(err));

    int64_t vsTon = cm_compile_function(lTon, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsTon = cm_compile_function(lTon, "celestia_tonemap_fs", 0, 0, 0, err, sizeof(err));
    int64_t pTon = cm_render_pipeline_create(ctx, vsTon, fsTon, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "ton", err, sizeof(err));

    assert(pSky && pCld && pBlm && pDef && pWat && pTon);

    int64_t skyLut = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 64, 32, 1, 1, 0, 0, 1, 1, "SkyLUT");
    int64_t gAlbedo = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "gAlbedo");
    int64_t gData = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "gData");
    int64_t depthTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "Depth");
    int64_t shadowTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 2048, 2048, 2, 1, 0, 1, 1, 0, "Shadow");
    int64_t waterMask = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "WaterMask");
    int64_t sceneA = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "SceneA");
    int64_t sceneB = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "SceneB");
    int64_t finalTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "Final");
    int64_t cloudTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W / 2, H / 2, 1, 1, 0, 0, 1, 1, "Clouds");
    int64_t bloomTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W / 2, H / 2, 1, 1, 0, 0, 1, 1, "Bloom");
    int64_t vSceneA = cm_texture_view_create(ctx, sceneA, 0, 1);
    int64_t vSceneB = cm_texture_view_create(ctx, sceneB, 0, 1);
    int64_t vFinal = cm_texture_view_create(ctx, finalTex, 0, 1);

    int64_t linSamp = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);
    int64_t shdSamp = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);

    CelestiaFrameUniformsC fu;
    memset(&fu, 0, sizeof(fu));
    set_identity(fu.viewProj);
    set_identity(fu.invViewProj);
    set_identity(fu.prevViewProj);
    set_identity(fu.shadowViewProjNear);
    set_identity(fu.shadowViewProjFar);
    fu.sunDirDaylight[0] = 0.4f; fu.sunDirDaylight[1] = 0.8f; fu.sunDirDaylight[2] = 0.4f; fu.sunDirDaylight[3] = 1.0f;
    fu.fogRanges[0] = 64.0f; fu.fogRanges[1] = 192.0f; fu.fogRanges[2] = 160.0f; fu.fogRanges[3] = 256.0f;
    fu.resolutionParams[0] = (float)W; fu.resolutionParams[1] = (float)H;
    fu.resolutionParams[2] = 1000.0f; fu.resolutionParams[3] = 1.2f;
    int64_t ubo = cm_buffer_create(ctx, 512, &fu, "BenchUBO");

    // Clear G-buffers once before timing loop (simulating terrain render result: non-zero sky depth 0, albedo 0.4,0.6,0.8)
    cm_cmd_begin(ctx);
    cm_blit_clear_color(ctx, gAlbedo, 0.35f, 0.55f, 0.25f, 1.0f);
    cm_blit_clear_color(ctx, gData, 0.5f, 0.5f, 0.2f, 1.0f);
    cm_blit_clear_depth(ctx, depthTex, 0.5);
    cm_blit_clear_depth(ctx, shadowTex, 0.0);
    cm_blit_clear_color(ctx, waterMask, 0.0f, 1.0f, 0.0f, 0.0f);
    uint64_t sInit = cm_cmd_submit(ctx, 2);
    cm_wait_submit(ctx, sInit, 5000000000ULL);

    const int WARMUP = 4;
    const int ITERS = 20;
    double totalGpuMs = 0.0;
    for (int it = 0; it < WARMUP + ITERS; it++) {
        cm_cmd_begin(ctx);
        int64_t bufs14[15] = {0};
        bufs14[14] = ubo;
        int64_t offs14[15] = {0};

        // 1. Sky LUT compute
        int64_t skyTexs[1] = { skyLut };
        cm_compute_dispatch(ctx, pSky, bufs14, offs14, 15, skyTexs, 1, NULL, 0, 8, 4, 1, 8, 8, 1);

        // 2. Deferred lighting pass
        int32_t noClear = 0; float clrZero[4] = {0};
        cm_pass_begin(ctx, &vSceneA, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "Deferred");
        cm_pass_set_pipeline(ctx, pDef);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, gAlbedo, 0, linSamp);
        cm_pass_set_texture_sampler(ctx, 1, gData, 1, shdSamp);
        cm_pass_set_texture_sampler(ctx, 2, depthTex, -1, 0);
        cm_pass_set_texture_sampler(ctx, 3, skyLut, -1, 0);
        cm_pass_set_texture_sampler(ctx, 4, shadowTex, -1, 0);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        // 3. Water pass
        cm_pass_begin(ctx, &vSceneB, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "Water");
        cm_pass_set_pipeline(ctx, pWat);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, sceneA, 0, linSamp);
        cm_pass_set_texture_sampler(ctx, 1, waterMask, -1, 0);
        cm_pass_set_texture_sampler(ctx, 2, depthTex, -1, 0);
        cm_pass_set_texture_sampler(ctx, 3, skyLut, -1, 0);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        // 4. Half-res Volumetric Clouds compute
        int64_t cldTexs[3] = { cloudTex, depthTex, skyLut };
        int64_t cldSamps[1] = { linSamp };
        cm_compute_dispatch(ctx, pCld, bufs14, offs14, 15, cldTexs, 3, cldSamps, 1,
                            ((W / 2) + 7) / 8, ((H / 2) + 7) / 8, 1, 8, 8, 1);

        // 5. Half-res Bloom compute
        int64_t blmTexs[2] = { bloomTex, sceneB };
        cm_compute_dispatch(ctx, pBlm, NULL, NULL, 0, blmTexs, 2, cldSamps, 1,
                            ((W / 2) + 7) / 8, ((H / 2) + 7) / 8, 1, 8, 8, 1);

        // 6. Final Composite & Tonemap
        cm_pass_begin(ctx, &vFinal, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "Tonemap");
        cm_pass_set_pipeline(ctx, pTon);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, sceneB, 0, linSamp);
        cm_pass_set_texture_sampler(ctx, 1, cloudTex, -1, 0);
        cm_pass_set_texture_sampler(ctx, 2, bloomTex, -1, 0);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        uint64_t serial = cm_cmd_submit(ctx, 2);
        cm_wait_submit(ctx, serial, 5000000000ULL);
        uint64_t ns = cm_device_last_gpu_ns(ctx);
        if (it >= WARMUP && ns > 0) {
            totalGpuMs += (double)ns / 1e6;
        }
    }

    double avgMs = totalGpuMs / ITERS;
    printf("[Benchmark M1 Pro %s @ %dx%d] Celestia Native (Balanced) post+lighting GPU avg: %.3f ms (%.1f FPS ceiling)\n",
           apiLabel, W, H, avgMs, avgMs > 0.0 ? (1000.0 / avgMs) : 0.0);

    // Benchmark Celestia Minimal (Crisp) on the same context
    int64_t lMinSky = compile_pack_shader(ctx, common, minDefines, [minimalDir stringByAppendingPathComponent:@"sky_lut.metal"]);
    int64_t lMinLit = compile_pack_shader(ctx, common, minDefines, [minimalDir stringByAppendingPathComponent:@"fast_lighting.metal"]);
    int64_t lMinWat = compile_pack_shader(ctx, common, minDefines, [minimalDir stringByAppendingPathComponent:@"water_minimal.metal"]);
    int64_t lMinTon = compile_pack_shader(ctx, common, minDefines, [minimalDir stringByAppendingPathComponent:@"tonemap_minimal.metal"]);

    int64_t fnMinSky = cm_compile_function(lMinSky, "celestia_min_sky_lut_cs", 0, 0, 0, err, sizeof(err));
    int64_t pMinSky = cm_compute_pipeline_create(ctx, fnMinSky, "min_sky", err, sizeof(err));
    int64_t vsMinLit = cm_compile_function(lMinLit, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsMinLit = cm_compile_function(lMinLit, "celestia_min_lighting_fs", 0, 0, 0, err, sizeof(err));
    int64_t pMinLit = cm_render_pipeline_create(ctx, vsMinLit, fsMinLit, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "min_lit", err, sizeof(err));
    int64_t vsMinWat = cm_compile_function(lMinWat, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsMinWat = cm_compile_function(lMinWat, "celestia_min_water_fs", 0, 0, 0, err, sizeof(err));
    int64_t pMinWat = cm_render_pipeline_create(ctx, vsMinWat, fsMinWat, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "min_wat", err, sizeof(err));
    int64_t vsMinTon = cm_compile_function(lMinTon, "celestia_fullscreen_vs", 0, 0, 0, err, sizeof(err));
    int64_t fsMinTon = cm_compile_function(lMinTon, "celestia_min_tonemap_fs", 0, 0, 0, err, sizeof(err));
    int64_t pMinTon = cm_render_pipeline_create(ctx, vsMinTon, fsMinTon, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "min_ton", err, sizeof(err));

    double minGpuMs = 0.0;
    for (int it = 0; it < WARMUP + ITERS; it++) {
        cm_cmd_begin(ctx);
        int64_t bufs14[15] = {0}; bufs14[14] = ubo;
        int64_t offs14[15] = {0};
        int64_t skyTexs[1] = { skyLut };
        cm_compute_dispatch(ctx, pMinSky, bufs14, offs14, 15, skyTexs, 1, NULL, 0, 8, 4, 1, 8, 8, 1);

        int32_t noClear = 0; float clrZero[4] = {0};
        cm_pass_begin(ctx, &vSceneA, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "MinLit");
        cm_pass_set_pipeline(ctx, pMinLit);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, gAlbedo, 0, linSamp);
        cm_pass_set_texture_sampler(ctx, 1, gData, -1, 0);
        cm_pass_set_texture_sampler(ctx, 2, depthTex, -1, 0);
        cm_pass_set_texture_sampler(ctx, 3, skyLut, -1, 0);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        cm_pass_begin(ctx, &vSceneB, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "MinWat");
        cm_pass_set_pipeline(ctx, pMinWat);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, sceneA, 0, linSamp);
        cm_pass_set_texture_sampler(ctx, 1, waterMask, -1, 0);
        cm_pass_set_texture_sampler(ctx, 2, depthTex, -1, 0);
        cm_pass_set_texture_sampler(ctx, 3, skyLut, -1, 0);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        cm_pass_begin(ctx, &vFinal, &noClear, clrZero, 1, 0, 0, 0.0, 0, 0, W, H, "MinTon");
        cm_pass_set_pipeline(ctx, pMinTon);
        cm_pass_set_uniform_buffer(ctx, 14, ubo, 0);
        cm_pass_set_texture_sampler(ctx, 0, sceneB, 0, linSamp);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);

        uint64_t serial = cm_cmd_submit(ctx, 2);
        cm_wait_submit(ctx, serial, 5000000000ULL);
        uint64_t ns = cm_device_last_gpu_ns(ctx);
        if (it >= WARMUP && ns > 0) minGpuMs += (double)ns / 1e6;
    }
    double avgMinMs = minGpuMs / ITERS;
    printf("[Benchmark M1 Pro %s @ %dx%d] Celestia Minimal (Crisp) post+lighting GPU avg: %.3f ms (%.1f FPS ceiling)\n",
           apiLabel, W, H, avgMinMs, avgMinMs > 0.0 ? (1000.0 / avgMinMs) : 0.0);

    cm_pipeline_destroy(ctx, pMinTon); cm_pipeline_destroy(ctx, pMinWat); cm_pipeline_destroy(ctx, pMinLit);
    cm_compute_pipeline_destroy(ctx, pMinSky);
    cm_function_destroy(vsMinTon); cm_function_destroy(fsMinTon);
    cm_function_destroy(vsMinWat); cm_function_destroy(fsMinWat);
    cm_function_destroy(vsMinLit); cm_function_destroy(fsMinLit);
    cm_function_destroy(fnMinSky);
    cm_library_destroy(lMinTon); cm_library_destroy(lMinWat); cm_library_destroy(lMinLit); cm_library_destroy(lMinSky);

    // Readback check: verify output pixels are valid finite numbers > 0
    int64_t rb = cm_buffer_create(ctx, 16 * 8, NULL, "FinalReadback");
    cm_cmd_begin(ctx);
    cm_blit_copy_texture_to_buffer(ctx, finalTex, 0, 0, 0, 0, 4, 4, rb, 0, 4 * 8);
    uint64_t sRb = cm_cmd_submit(ctx, 2);
    cm_wait_submit(ctx, sRb, 5000000000ULL);
    uint16_t *halfPx = (uint16_t *)(uintptr_t)cm_buffer_contents(rb);
    // Verify alpha == 1.0h (0x3C00 in IEEE 754 binary16)
    assert(halfPx[3] == 0x3C00);

    cm_buffer_destroy(ctx, rb);
    cm_buffer_destroy(ctx, ubo);
    cm_sampler_destroy(ctx, shdSamp);
    cm_sampler_destroy(ctx, linSamp);
    cm_texture_view_destroy(ctx, vFinal);
    cm_texture_view_destroy(ctx, vSceneB);
    cm_texture_view_destroy(ctx, vSceneA);
    cm_texture_destroy(ctx, bloomTex);
    cm_texture_destroy(ctx, cloudTex);
    cm_texture_destroy(ctx, finalTex);
    cm_texture_destroy(ctx, sceneB);
    cm_texture_destroy(ctx, sceneA);
    cm_texture_destroy(ctx, waterMask);
    cm_texture_destroy(ctx, shadowTex);
    cm_texture_destroy(ctx, depthTex);
    cm_texture_destroy(ctx, gData);
    cm_texture_destroy(ctx, gAlbedo);
    cm_texture_destroy(ctx, skyLut);

    cm_pipeline_destroy(ctx, pTon);
    cm_pipeline_destroy(ctx, pWat);
    cm_pipeline_destroy(ctx, pDef);
    cm_compute_pipeline_destroy(ctx, pBlm);
    cm_compute_pipeline_destroy(ctx, pCld);
    cm_compute_pipeline_destroy(ctx, pSky);
    cm_function_destroy(vsTon); cm_function_destroy(fsTon);
    cm_function_destroy(vsWat); cm_function_destroy(fsWat);
    cm_function_destroy(vsDef); cm_function_destroy(fsDef);
    cm_function_destroy(fnBlm); cm_function_destroy(fnCld); cm_function_destroy(fnSky);
    cm_library_destroy(lTon); cm_library_destroy(lBlm); cm_library_destroy(lCld);
    cm_library_destroy(lWat); cm_library_destroy(lDef); cm_library_destroy(lSky);
    cm_device_destroy(ctx);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <assetsDir>\n", argv[0]);
        return 2;
    }
    CMProbeInfo probe;
    cm_probe_device(&probe);
    printf("Probed GPU: %s | Apple%d | Metal 4=%d | %d Hz | EDR=%.2fx | WorkingSet=%.2f GB\n",
           probe.gpuName, probe.appleGpuFamily, probe.metal4Supported,
           probe.maxRefreshRateHz, probe.edrHeadroom,
           (double)probe.recommendedMaxWorkingSetBytes / (1024.0 * 1024.0 * 1024.0));
    assert(probe.supported == 1);

    verify_backend_ops(1);
    verify_backend_ops(0);
    benchmark_native_pipelines([NSString stringWithUTF8String:argv[1]], 1);
    benchmark_native_pipelines([NSString stringWithUTF8String:argv[1]], 0);
    printf("ALL CELESTIA METAL NATIVE GPU TESTS PASSED.\n");
    return 0;
}
