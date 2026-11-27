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
    // Zero-timeout fence polls must never block (Minecraft polls many fences per frame) and report correctly.
    {
        uint64_t future = cm_device_next_submit(ctx) + 5;
        CFTimeInterval p0 = CACurrentMediaTime();
        for (int i = 0; i < 1000; i++) assert(cm_wait_submit(ctx, future, 0) == 0);
        double pollUs = (CACurrentMediaTime() - p0) * 1e6 / 1000.0;
        assert(cm_wait_submit(ctx, s2eIdle, 0) == 1);
        if (pollUs > 20.0) { fprintf(stderr, "FAIL: zero-timeout fence poll costs %.2f us\n", pollUs); exit(1); }
        printf("[Backend %s] zero-timeout fence poll %.3f us\n", preferMetal4 ? "Metal 4" : "Metal 3", pollUs);
    }

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

    // 2g. Render pass merging + deferred clear folding (ordering, correctness, and statistics)
    {
        const char *mergeMsl =
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct VIn { float4 pos [[attribute(0)]]; };\n"
            "struct VOut { float4 pos [[position]]; };\n"
            "vertex VOut vs_m(VIn in [[stage_in]]) { VOut o; o.pos = in.pos; return o; }\n"
            "fragment half4 fs_red() { return half4(1.0h, 0.0h, 0.0h, 1.0h); }\n"
            "fragment half4 fs_green() { return half4(0.0h, 1.0h, 0.0h, 1.0h); }\n";
        int64_t libM = cm_compile_msl_library(ctx, mergeMsl, "merge_test", 0, err, sizeof(err));
        assert(libM != 0);
        int64_t vsM = cm_compile_function(libM, "vs_m", 0, 0, 0, err, sizeof(err));
        int64_t fsRed = cm_compile_function(libM, "fs_red", 0, 0, 0, err, sizeof(err));
        int64_t fsGreen = cm_compile_function(libM, "fs_green", 0, 0, 0, err, sizeof(err));
        CMVertexBufferDesc mVb = { 0, 16, 0 };
        CMAttribBindingDesc mAttr = { 0, 0, 0, CM_FMT_RGBA32_FLOAT };
        int64_t psoRed = cm_render_pipeline_create(ctx, vsM, fsRed, &mVb, 1, &mAttr, 1, &colDesc, 1,
                                                   CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                                   CM_CMP_ALWAYS, 0, 0.0f, 0.0f, "MergeRed", err, sizeof(err));
        int64_t psoGreen = cm_render_pipeline_create(ctx, vsM, fsGreen, &mVb, 1, &mAttr, 1, &colDesc, 1,
                                                     CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1,
                                                     CM_CMP_ALWAYS, 0, 0.0f, 0.0f, "MergeGreen", err, sizeof(err));
        assert(psoRed && psoGreen);
        // Left half [-1, 0] and right half [0, 1] quads (two triangles each), plus a full-screen quad
        float leftQ[6 * 4] = { -1,-1,0.5f,1,  0,-1,0.5f,1,  -1,1,0.5f,1,   0,-1,0.5f,1,  0,1,0.5f,1,  -1,1,0.5f,1 };
        float rightQ[6 * 4] = { 0,-1,0.5f,1,  1,-1,0.5f,1,   0,1,0.5f,1,   1,-1,0.5f,1,  1,1,0.5f,1,   0,1,0.5f,1 };
        float fullQ[6 * 4] = { -1,-1,0.5f,1, 1,-1,0.5f,1,   -1,1,0.5f,1,   1,-1,0.5f,1,  1,1,0.5f,1,  -1,1,0.5f,1 };
        int64_t leftVbo = cm_buffer_create(ctx, sizeof(leftQ), leftQ, "MergeLeft");
        int64_t rightVbo = cm_buffer_create(ctx, sizeof(rightQ), rightQ, "MergeRight");
        int64_t fullVbo = cm_buffer_create(ctx, sizeof(fullQ), fullQ, "MergeFull");
        int64_t ctex2 = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 64, 64, 1, 1, 0, 1, 1, 0, "MergeSideRT");
        int64_t readBuf2 = cm_buffer_create(ctx, 64 * 64 * 4, NULL, "MergeReadback2");
        assert(leftVbo && rightVbo && fullVbo && ctex2 && readBuf2);
        uint8_t *px2 = (uint8_t *)(uintptr_t)cm_buffer_contents(readBuf2);
        const size_t leftPx = ((size_t)32 * 64u + 8u) * 4u;
        const size_t rightPx = ((size_t)32 * 64u + 56u) * 4u;
#define PX_IS(p, R, G, B) (abs((int)(p)[0] - (R)) <= 3 && abs((int)(p)[1] - (G)) <= 3 && abs((int)(p)[2] - (B)) <= 3)

        for (int mode = 0; mode < 2; mode++) {
            int enabled = mode == 0;
            cm_device_set_option(ctx, CM_OPT_PASS_MERGE, enabled);
            cm_device_set_option(ctx, CM_OPT_DEFER_CLEARS, enabled);
            int64_t st0[CM_STAT_COUNT] = {0};
            int64_t st1[CM_STAT_COUNT] = {0};
            cm_device_stats(ctx, st0, CM_STAT_COUNT);

            // (a) deferred clear -> load pass (red, left) -> soft end -> merged load pass (green, right)
            cm_cmd_begin(ctx);
            cm_blit_clear_color_depth(ctx, ctex, 0.0f, 0.0f, 1.0f, 1.0f, dtex, 0.0);
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "MergeA") == 1);
            cm_pass_set_pipeline(ctx, psoRed);
            cm_pass_set_vertex_buffer(ctx, 0, leftVbo, 0, 16);
            cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 6, 1, 0, 0);
            cm_pass_finish(ctx);
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "MergeB") == 1);
            cm_pass_set_pipeline(ctx, psoGreen);
            cm_pass_set_vertex_buffer(ctx, 0, rightVbo, 0, 16);
            cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 6, 1, 0, 0);
            cm_pass_finish(ctx);
            // A deferred clear of an unrelated texture must be flushed before a blit reads it
            cm_blit_clear_color(ctx, ctex2, 1.0f, 1.0f, 0.0f, 1.0f);
            cm_blit_copy_texture_to_buffer(ctx, ctex2, 0, 0, 0, 0, 64, 64, readBuf2, 0, 64 * 4);
            cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
            uint64_t s2g = cm_cmd_submit(ctx, 2);
            assert(cm_wait_submit(ctx, s2g, 5000000000ULL) == 1);
            assert(PX_IS(&px[leftPx], 255, 0, 0));
            assert(PX_IS(&px[rightPx], 0, 255, 0));
            assert(PX_IS(&px2[leftPx], 255, 255, 0));
            cm_device_stats(ctx, st1, CM_STAT_COUNT);
            assert(st1[CM_STAT_PASSES_BEGUN] - st0[CM_STAT_PASSES_BEGUN] == 2);
            if (enabled) {
                assert(st1[CM_STAT_PASSES_MERGED] - st0[CM_STAT_PASSES_MERGED] == 1);
                assert(st1[CM_STAT_CLEARS_FOLDED] - st0[CM_STAT_CLEARS_FOLDED] == 2);
                assert(st1[CM_STAT_CLEARS_FLUSHED] - st0[CM_STAT_CLEARS_FLUSHED] == 1);
                // one merged pass encoder + one flushed side clear
                assert(st1[CM_STAT_RENDER_ENCODERS] - st0[CM_STAT_RENDER_ENCODERS] == 2);
            } else {
                assert(st1[CM_STAT_PASSES_MERGED] - st0[CM_STAT_PASSES_MERGED] == 0);
                assert(st1[CM_STAT_CLEARS_FOLDED] - st0[CM_STAT_CLEARS_FOLDED] == 0);
                // color+depth clear, two passes, side clear
                assert(st1[CM_STAT_RENDER_ENCODERS] - st0[CM_STAT_RENDER_ENCODERS] == 4);
            }

            // (b) pass (red full) -> clear same target (blue) -> load pass (green left):
            //     the clear must land after the red pass and before the green pass.
            cm_cmd_begin(ctx);
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "OrderA") == 1);
            cm_pass_set_pipeline(ctx, psoRed);
            cm_pass_set_vertex_buffer(ctx, 0, fullVbo, 0, 16);
            cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 6, 1, 0, 0);
            cm_pass_finish(ctx);
            cm_blit_clear_color(ctx, ctex, 0.0f, 0.0f, 1.0f, 1.0f);
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "OrderB") == 1);
            cm_pass_set_pipeline(ctx, psoGreen);
            cm_pass_set_vertex_buffer(ctx, 0, leftVbo, 0, 16);
            cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 6, 1, 0, 0);
            cm_pass_finish(ctx);
            cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
            uint64_t s2gb = cm_cmd_submit(ctx, 2);
            assert(cm_wait_submit(ctx, s2gb, 5000000000ULL) == 1);
            assert(PX_IS(&px[leftPx], 0, 255, 0));
            assert(PX_IS(&px[rightPx], 0, 0, 255));

            // (c) a following pass that requests its own clear must never merge into the open encoder
            cm_device_stats(ctx, st0, CM_STAT_COUNT);
            cm_cmd_begin(ctx);
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "ClearA") == 1);
            cm_pass_set_pipeline(ctx, psoRed);
            cm_pass_set_vertex_buffer(ctx, 0, fullVbo, 0, 16);
            cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 6, 1, 0, 0);
            cm_pass_finish(ctx);
            assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, dview, 0, 0.0, 0, 0, 64, 64, "ClearB") == 1);
            cm_pass_finish(ctx);
            // and submit must close a soft-ended pass on its own
            uint64_t s2gc = cm_cmd_submit(ctx, 2);
            assert(cm_wait_submit(ctx, s2gc, 5000000000ULL) == 1);
            cm_cmd_begin(ctx);
            cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
            uint64_t s2gd = cm_cmd_submit(ctx, 2);
            assert(cm_wait_submit(ctx, s2gd, 5000000000ULL) == 1);
            assert(PX_IS(&px[leftPx], 0, 0, 0) && PX_IS(&px[rightPx], 0, 0, 0));
            cm_device_stats(ctx, st1, CM_STAT_COUNT);
            assert(st1[CM_STAT_PASSES_MERGED] - st0[CM_STAT_PASSES_MERGED] == 0);
        }
#undef PX_IS
        cm_device_set_option(ctx, CM_OPT_PASS_MERGE, 1);
        cm_device_set_option(ctx, CM_OPT_DEFER_CLEARS, 1);
        printf("[Backend %s] Test 2g pass merging + clear folding OK\n", preferMetal4 ? "Metal 4" : "Metal 3");

        // 2h. Staging-buffer reuse across tile uploads inside one blit encoder (Xaero's World Map pattern):
        //     writeToBuffer-style copy (stage_k -> pbo) followed by copyBufferToTexture (pbo -> tile_k).
        //     Every buffer->texture copy must observe the preceding copy that filled the shared pbo.
        {
            enum { TILES = 8, TW = 512, TH = 512 };
            const size_t tileBytes = (size_t)TW * TH * 4u;
            int64_t pbo = cm_buffer_create(ctx, (int64_t)tileBytes, NULL, "TilePbo");
            int64_t stages[TILES], tiles[TILES], reads[TILES];
            for (int k = 0; k < TILES; k++) {
                stages[k] = cm_buffer_create(ctx, (int64_t)tileBytes, NULL, "TileStage");
                tiles[k] = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, TW, TH, 1, 1, 0, 0, 1, 0, "Tile");
                reads[k] = cm_buffer_create(ctx, (int64_t)tileBytes, NULL, "TileRead");
                assert(stages[k] && tiles[k] && reads[k]);
            }
            assert(pbo);
            for (int iter = 0; iter < 6; iter++) {
                for (int k = 0; k < TILES; k++) {
                    uint32_t *st = (uint32_t *)(uintptr_t)cm_buffer_contents(stages[k]);
                    uint32_t v = 0xFF000000u | ((uint32_t)(iter * TILES + k + 1) * 0x010307u);
                    for (size_t i = 0; i < (size_t)TW * TH; i++) st[i] = v;
                }
                cm_cmd_begin(ctx);
                for (int k = 0; k < TILES; k++) {
                    cm_blit_copy_buffer(ctx, stages[k], 0, pbo, 0, (int64_t)tileBytes);
                    cm_blit_copy_buffer_to_texture(ctx, pbo, 0, TW * 4, tiles[k], 0, 0, 0, 0, TW, TH);
                }
                for (int k = 0; k < TILES; k++) {
                    cm_blit_copy_texture_to_buffer(ctx, tiles[k], 0, 0, 0, 0, TW, TH, reads[k], 0, TW * 4);
                }
                uint64_t s2h = cm_cmd_submit(ctx, 2);
                assert(cm_wait_submit(ctx, s2h, 5000000000ULL) == 1);
                for (int k = 0; k < TILES; k++) {
                    const uint32_t *rd = (const uint32_t *)(uintptr_t)cm_buffer_contents(reads[k]);
                    uint32_t v = 0xFF000000u | ((uint32_t)(iter * TILES + k + 1) * 0x010307u);
                    for (size_t i = 0; i < (size_t)TW * TH; i += 4099) {
                        if (rd[i] != v) {
                            fprintf(stderr, "FAIL 2h: tile %d texel %zu = %08x, expected %08x (iter %d)\n", k, i, rd[i], v, iter);
                            exit(1);
                        }
                    }
                    if (rd[(size_t)TW * TH - 1] != v) {
                        fprintf(stderr, "FAIL 2h: tile %d last texel = %08x, expected %08x\n", k, rd[(size_t)TW * TH - 1], v);
                        exit(1);
                    }
                }
            }
            for (int k = 0; k < TILES; k++) {
                cm_buffer_destroy(ctx, reads[k]);
                cm_texture_destroy(ctx, tiles[k]);
                cm_buffer_destroy(ctx, stages[k]);
            }
            cm_buffer_destroy(ctx, pbo);
            printf("[Backend %s] Test 2h staging reuse buffer->texture ordering OK\n", preferMetal4 ? "Metal 4" : "Metal 3");
        }

        // 2j. Push-constant dedup: identical consecutive pushes reuse the bound bytes, changed ones take effect, and a
        //     new encoder never inherits a stale "already bound" assumption.
        {
            const char *pcMsl =
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct P { float4 color; float4 rect; };\n"
                "struct VOut { float4 pos [[position]]; };\n"
                "vertex VOut vs_pc(uint vid [[vertex_id]], constant P &p [[buffer(15)]]) {\n"
                "  float2 c = float2((vid & 1) ? p.rect.z : p.rect.x, (vid >> 1) ? p.rect.w : p.rect.y);\n"
                "  VOut o; o.pos = float4(c, 0.5f, 1.0f); return o;\n"
                "}\n"
                "fragment half4 fs_pc(constant P &p [[buffer(15)]]) { return half4(p.color); }\n";
            int64_t libPc = cm_compile_msl_library(ctx, pcMsl, "push_dedup", 0, err, sizeof(err));
            assert(libPc != 0);
            int64_t vsPc = cm_compile_function(libPc, "vs_pc", 0, 0, 0, err, sizeof(err));
            int64_t fsPc = cm_compile_function(libPc, "fs_pc", 0, 0, 0, err, sizeof(err));
            int64_t psoPc = cm_render_pipeline_create(ctx, vsPc, fsPc, NULL, 0, NULL, 0, &colDesc, 1, -1,
                                                      CM_TOPO_TRIANGLE_STRIP, 0, 0, 0, CM_CMP_ALWAYS, 0, 0.0f, 0.0f,
                                                      "PushDedupPSO", err, sizeof(err));
            assert(psoPc != 0);
            // Draw only the rect, so each third keeps whatever the previous draws left there
            float red[8]    = { 1, 0, 0, 1,  -1.0f, -1, -0.34f, 1 };
            float redMid[8] = { 1, 0, 0, 1,  -0.34f, -1, 0.34f, 1 };
            float green[8]  = { 0, 1, 0, 1,   0.34f, -1, 1.0f, 1 };
            cm_cmd_begin(ctx);
            assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, 0, 0, 0.0, 0, 0, 64, 64, "PushDedupA") == 1);
            cm_pass_set_pipeline(ctx, psoPc);
            cm_pass_push_constants(ctx, 15, red, sizeof(red));
            cm_pass_draw(ctx, CM_TOPO_TRIANGLE_STRIP, 4, 1, 0, 0);
            cm_pass_push_constants(ctx, 15, red, sizeof(red));      // identical: deduplicated
            cm_pass_draw(ctx, CM_TOPO_TRIANGLE_STRIP, 4, 1, 0, 0);
            cm_pass_push_constants(ctx, 15, redMid, sizeof(redMid)); // different rect
            cm_pass_draw(ctx, CM_TOPO_TRIANGLE_STRIP, 4, 1, 0, 0);
            cm_pass_push_constants(ctx, 15, green, sizeof(green));
            cm_pass_draw(ctx, CM_TOPO_TRIANGLE_STRIP, 4, 1, 0, 0);
            cm_pass_end(ctx);
            // New encoder: the same bytes as the last push of the previous encoder must still be bound again
            float greenFull[8] = { 0, 1, 0, 1,  -1.0f, -1, -0.34f, 0.0f };
            assert(cm_pass_begin(ctx, &cview, &loadFlag, clearCol, 1, 0, 0, 0.0, 0, 0, 64, 64, "PushDedupB") == 1);
            cm_pass_set_pipeline(ctx, psoPc);
            cm_pass_push_constants(ctx, 15, greenFull, sizeof(greenFull));
            cm_pass_draw(ctx, CM_TOPO_TRIANGLE_STRIP, 4, 1, 0, 0);
            cm_pass_end(ctx);
            cm_blit_copy_texture_to_buffer(ctx, ctex, 0, 0, 0, 0, 64, 64, readBuf, 0, 64 * 4);
            uint64_t s2j = cm_cmd_submit(ctx, 2);
            assert(cm_wait_submit(ctx, s2j, 5000000000ULL) == 1);
            // Rows are flipped relative to NDC y; sample row 16 (one half) and row 48 (other half).
            const uint8_t *left0 = &px[((size_t)16 * 64u + 8u) * 4u], *left1 = &px[((size_t)48 * 64u + 8u) * 4u];
            const uint8_t *mid = &px[((size_t)32 * 64u + 32u) * 4u], *right = &px[((size_t)32 * 64u + 56u) * 4u];
            int leftGreen = (left0[1] > 250 && left0[0] < 5) + (left1[1] > 250 && left1[0] < 5);
            int leftRed = (left0[0] > 250 && left0[1] < 5) + (left1[0] > 250 && left1[1] < 5);
            if (!(leftGreen == 1 && leftRed == 1 && mid[0] > 250 && mid[1] < 5 && right[1] > 250 && right[0] < 5)) {
                fprintf(stderr, "FAIL 2j: push-constant dedup L0=%d,%d L1=%d,%d M=%d,%d R=%d,%d\n",
                        left0[0], left0[1], left1[0], left1[1], mid[0], mid[1], right[0], right[1]);
                exit(1);
            }
            cm_pipeline_destroy(ctx, psoPc);
            cm_function_destroy(fsPc);
            cm_function_destroy(vsPc);
            cm_library_destroy(libPc);
            printf("[Backend %s] Test 2j push-constant dedup OK\n", preferMetal4 ? "Metal 4" : "Metal 3");
        }

        // 2k. World render-scale upscale (cm_upscale_to): bilinear and MetalFX Spatial, orientation and coverage.
        {
            const int SW = 48, SH = 32, DW = 96, DH = 64;
            int64_t srcT = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, SW, SH, 1, 1, 0, 1, 1, 0, "UpscaleSrc");
            int64_t srcV = cm_texture_view_create(ctx, srcT, 0, 1);
            int64_t dstT = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, DW, DH, 1, 1, 0, 1, 1, 0, "UpscaleDst");
            int64_t upRead = cm_buffer_create(ctx, DW * DH * 4, NULL, "UpscaleRead");
            assert(srcT && srcV && dstT && upRead);
            const char *halfMsl =
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct VOut { float4 pos [[position]]; };\n"
                "vertex VOut vs_h(uint vid [[vertex_id]]) { VOut o; float2 p = float2((vid==1)?3.0f:-1.0f, (vid==2)?3.0f:-1.0f); o.pos = float4(p,0.5f,1); return o; }\n"
                // left half red, right half green, top quarter blue marker (tests vertical orientation)
                "fragment half4 fs_h(VOut in [[stage_in]]) {\n"
                "  if (in.pos.y < 8.0f) return half4(0,0,1,1);\n"
                "  return in.pos.x < 24.0f ? half4(1,0,0,1) : half4(0,1,0,1);\n"
                "}\n";
            int64_t libH = cm_compile_msl_library(ctx, halfMsl, "upscale_src", 0, err, sizeof(err));
            assert(libH != 0);
            int64_t vsH = cm_compile_function(libH, "vs_h", 0, 0, 0, err, sizeof(err));
            int64_t fsH = cm_compile_function(libH, "fs_h", 0, 0, 0, err, sizeof(err));
            int64_t psoH = cm_render_pipeline_create(ctx, vsH, fsH, NULL, 0, NULL, 0, &colDesc, 1, -1, CM_TOPO_TRIANGLES,
                                                     0, 0, 0, CM_CMP_ALWAYS, 0, 0.0f, 0.0f, "UpscaleSrcPSO", err, sizeof(err));
            assert(psoH != 0);
            for (int mode = 0; mode < 2; mode++) {
                cm_cmd_begin(ctx);
                assert(cm_pass_begin(ctx, &srcV, &clearFlag, clearCol, 1, 0, 0, 0.0, 0, 0, SW, SH, "UpscaleSrcPass") == 1);
                cm_pass_set_pipeline(ctx, psoH);
                cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
                cm_pass_finish(ctx);
                int32_t used = cm_upscale_to(ctx, srcT, dstT, mode);
                assert(used == 0 || (mode == 1 && used == 1));
                cm_blit_copy_texture_to_buffer(ctx, dstT, 0, 0, 0, 0, DW, DH, upRead, 0, DW * 4);
                uint64_t s2k = cm_cmd_submit(ctx, 2);
                assert(cm_wait_submit(ctx, s2k, 5000000000ULL) == 1);
                const uint8_t *u = (const uint8_t *)(uintptr_t)cm_buffer_contents(upRead);
                const uint8_t *top = &u[((size_t)4 * DW + 48) * 4];
                const uint8_t *left = &u[((size_t)40 * DW + 16) * 4];
                const uint8_t *right = &u[((size_t)40 * DW + 80) * 4];
                if (!(top[2] > 200 && top[0] < 60 && left[0] > 200 && left[1] < 60 && right[1] > 200 && right[0] < 60)) {
                    fprintf(stderr, "FAIL 2k: upscale mode %d (used %d) top=%d,%d,%d left=%d,%d,%d right=%d,%d,%d\n", mode, used,
                            top[0], top[1], top[2], left[0], left[1], left[2], right[0], right[1], right[2]);
                    exit(1);
                }
                printf("[Backend %s] Test 2k upscale %s OK (path used: %s)\n", preferMetal4 ? "Metal 4" : "Metal 3",
                       mode ? "MetalFX Spatial" : "bilinear", used ? "MetalFX Spatial" : "bilinear");
            }
            cm_pipeline_destroy(ctx, psoH);
            cm_function_destroy(fsH); cm_function_destroy(vsH); cm_library_destroy(libH);
            cm_buffer_destroy(ctx, upRead);
            cm_texture_destroy(ctx, dstT);
            cm_texture_view_destroy(ctx, srcV);
            cm_texture_destroy(ctx, srcT);
        }

        // 2i. Non-blocking (MAILBOX-style) presentation with VSync off: acquire never blocks, frames keep flowing even
        //     when presented handlers never report "shown" (offscreen layer = worst case), and teardown is safe.
        {
            CAMetalLayer *layer = [CAMetalLayer layer];
            int64_t surf = cm_surface_create(ctx, (int64_t)(__bridge void *)layer, 0);
            assert(surf != 0);
            cm_surface_set_nonblocking(surf, 1);
            cm_surface_configure(surf, 256, 128, 0, 0);
            int64_t st0[CM_STAT_COUNT] = {0}, st1[CM_STAT_COUNT] = {0};
            cm_device_stats(ctx, st0, CM_STAT_COUNT);
            double worstAcquireMs = 0.0, worstFrameMs = 0.0;
            CFTimeInterval t0 = CACurrentMediaTime();
            const int FRAMES = 120;
            for (int f = 0; f < FRAMES; f++) {
                CFTimeInterval fs = CACurrentMediaTime();
                assert(cm_surface_acquire(surf) == 1);
                worstAcquireMs = MAX(worstAcquireMs, (CACurrentMediaTime() - fs) * 1000.0);
                cm_cmd_begin(ctx);
                assert(cm_pass_begin(ctx, &cview, &clearFlag, clearCol, 1, 0, 0, 0.0, 0, 0, 64, 64, "PresentSrc") == 1);
                cm_pass_end(ctx);
                cm_surface_blit_and_present(ctx, surf, cview, 2);
                worstFrameMs = MAX(worstFrameMs, (CACurrentMediaTime() - fs) * 1000.0);
            }
            double totalMs = (CACurrentMediaTime() - t0) * 1000.0;
            cm_device_wait_idle(ctx);
            cm_device_stats(ctx, st1, CM_STAT_COUNT);
            assert(st1[CM_STAT_FRAMES_SUBMITTED] - st0[CM_STAT_FRAMES_SUBMITTED] == FRAMES);
            // acquire must not touch drawables on this path
            assert(worstAcquireMs < 2.0);
            // The render thread may only wait on GPU in-flight throttling or a briefly busy slot, never ~1 s nextDrawable timeouts
            if (worstFrameMs > 120.0) {
                fprintf(stderr, "FAIL 2i: a frame blocked for %.1f ms\n", worstFrameMs);
                exit(1);
            }
            // Mode switches and reconfiguration while presents may be in flight
            cm_surface_configure(surf, 320, 160, 0, 0);
            for (int f = 0; f < 8; f++) {
                cm_cmd_begin(ctx);
                cm_surface_blit_and_present(ctx, surf, cview, 2);
            }
            // Stress: repeated resizes while frames are in flight or waiting. A leaked present slot would show up as 50 ms
            // slot-wait timeouts once the pool is exhausted. (Offscreen layers rarely park a waiting frame, so this does
            // not deterministically reproduce the configure-time leak fixed in alpha.13; it guards against regressions.)
            for (int r = 0; r < 6; r++) {
                for (int f = 0; f < 2; f++) {
                    cm_cmd_begin(ctx);
                    cm_surface_blit_and_present(ctx, surf, cview, 2);
                }
                cm_device_wait_idle(ctx);
                usleep(20000); // frames are finished; with no on-screen feedback the newest one is parked as waiting
                cm_surface_configure(surf, 200 + r * 16, 100 + r * 8, 0, 0);
            }
            cm_device_wait_idle(ctx);
            usleep(250000); // let the 100 ms no-feedback fallback present any waiting frame
            int64_t stR0[CM_STAT_COUNT] = {0}, stR1[CM_STAT_COUNT] = {0};
            cm_device_stats(ctx, stR0, CM_STAT_COUNT);
            double worstAfterResize = 0.0;
            for (int f = 0; f < 20; f++) {
                CFTimeInterval fs = CACurrentMediaTime();
                cm_cmd_begin(ctx);
                cm_surface_blit_and_present(ctx, surf, cview, 2);
                worstAfterResize = MAX(worstAfterResize, (CACurrentMediaTime() - fs) * 1000.0);
            }
            cm_device_stats(ctx, stR1, CM_STAT_COUNT);
            if (worstAfterResize > 45.0) {
                fprintf(stderr, "FAIL 2i: present slots leaked across resizes (worst frame %.1f ms)\n", worstAfterResize);
                exit(1);
            }
            cm_surface_set_nonblocking(surf, 0);
            cm_surface_set_nonblocking(surf, 1);
            // Tear down while frames are still in flight (must not trap in libdispatch / Metal callbacks)
            for (int f = 0; f < 3; f++) {
                cm_cmd_begin(ctx);
                cm_surface_blit_and_present(ctx, surf, cview, 2);
            }
            cm_surface_destroy(ctx, surf);
            cm_device_wait_idle(ctx);
            char drained2[512] = {0};
            if (cm_device_drain_errors(ctx, drained2, sizeof(drained2)) > 0) {
                fprintf(stderr, "FAIL 2i: GPU errors: %s\n", drained2);
                exit(1);
            }
            printf("[Backend %s] Test 2i non-blocking present OK (%d frames in %.1f ms, worst frame %.2f ms, worst acquire %.3f ms, shown %lld, dropped %lld)\n",
                   preferMetal4 ? "Metal 4" : "Metal 3", FRAMES, totalMs, worstFrameMs, worstAcquireMs,
                   (long long)(st1[CM_STAT_PRESENTS_SHOWN] - st0[CM_STAT_PRESENTS_SHOWN]),
                   (long long)(st1[CM_STAT_FRAMES_DROPPED] - st0[CM_STAT_FRAMES_DROPPED]));
        }

        cm_buffer_destroy(ctx, readBuf2);
        cm_texture_destroy(ctx, ctex2);
        cm_buffer_destroy(ctx, fullVbo);
        cm_buffer_destroy(ctx, rightVbo);
        cm_buffer_destroy(ctx, leftVbo);
        cm_pipeline_destroy(ctx, psoGreen);
        cm_pipeline_destroy(ctx, psoRed);
        cm_function_destroy(fsGreen);
        cm_function_destroy(fsRed);
        cm_function_destroy(vsM);
        cm_library_destroy(libM);
    }

    // 2l. CelestiaShade P1 globals, Sky LUT, 6-level bloom, auto-exposure, and Lottes shade_final
    {
        NSString *repoAssets = [NSString stringWithUTF8String:getenv("CELESTIA_TEST_ASSETS") ?: "src/main/resources/assets/celestiametal"];
        NSString *portedDir = [repoAssets stringByAppendingPathComponent:@"shaders/ported"];
        NSString *slots = read_file_str([portedDir stringByAppendingPathComponent:@"shade_slots.metal"]);
        NSString *lookSrc = read_file_str([portedDir stringByAppendingPathComponent:@"shade_look.metal"]);
        NSString *commonSrc = read_file_str([portedDir stringByAppendingPathComponent:@"shade_common.metal"]);
        NSString *m2Src = read_file_str([portedDir stringByAppendingPathComponent:@"shade_m2.metal"]);
        NSString *vuniSrc = read_file_str([portedDir stringByAppendingPathComponent:@"vanilla_uniforms.metal"]);
        NSString *prelude = [NSString stringWithFormat:@"#define MCOPT_SHADE 1\n#define MCOPT_HDR 1\n%@\n%@\n%@\n%@\n%@\n",
                             slots, lookSrc, commonSrc, m2Src, vuniSrc];

        // Compile-verify every ported P1 & P2 .metal file on both Metal 4 and Metal 3
        NSString *dummyDefines = @"#define CELESTIA_BUF_Fog 0\n#define CELESTIA_BUF_DynamicTransforms 1\n#define CELESTIA_BUF_Projection 2\n#define CELESTIA_BUF_CloudInfo 0\n#define CELESTIA_TEX_Sampler0 0\n#define CELESTIA_SAMP_Sampler0 0\n";
        NSArray<NSString *> *portedShaders = @[
            @"sky_lut.metal", @"sky.vs.metal", @"sky.fs.metal",
            @"celestial.vs.metal", @"celestial.fs.metal", @"stars.vs.metal",
            @"sunrise_sunset.vs.metal", @"clouds.fs.metal", @"shade_post.metal",
            @"shade_terrain.metal", @"shade_entity.metal"
        ];
        char serr[4096] = {0};
        for (NSString *fn in portedShaders) {
            NSString *body = read_file_str([portedDir stringByAppendingPathComponent:fn]);
            NSString *weather = [fn isEqualToString:@"shade_terrain.metal"]
                ? read_file_str([portedDir stringByAppendingPathComponent:@"weather_surface.metal"]) : @"";
            NSString *src = [NSString stringWithFormat:@"%@\n%@\n%@\n%@", dummyDefines, prelude, weather, body];
            int64_t l = cm_compile_msl_library(ctx, src.UTF8String, fn.UTF8String, 1, serr, sizeof(serr));
            if (!l) {
                fprintf(stderr, "FAIL 2l compiling ported shader %s:\n%s\n", fn.UTF8String, serr);
                exit(1);
            }
            cm_library_destroy(l);
        }
        for (NSString *fn in @[@"shadow_sodium.metal", @"shadow_vanilla.metal"]) {
            NSString *src = read_file_str([portedDir stringByAppendingPathComponent:fn]);
            int64_t l = cm_compile_msl_library(ctx, src.UTF8String, fn.UTF8String, 1, serr, sizeof(serr));
            if (!l) {
                fprintf(stderr, "FAIL 2l compiling ported shadow shader %s:\n%s\n", fn.UTF8String, serr);
                exit(1);
            }
            cm_library_destroy(l);
        }

        NSString *lutFull = [NSString stringWithFormat:@"%@\n%@", prelude, read_file_str([portedDir stringByAppendingPathComponent:@"sky_lut.metal"])];
        NSString *postFull = [NSString stringWithFormat:@"%@\n%@", prelude, read_file_str([portedDir stringByAppendingPathComponent:@"shade_post.metal"])];
        int64_t lLut = cm_compile_msl_library(ctx, lutFull.UTF8String, "Test2lSkyLut", 1, serr, sizeof(serr));
        int64_t lPost = cm_compile_msl_library(ctx, postFull.UTF8String, "Test2lPost", 1, serr, sizeof(serr));
        assert(lLut && lPost);

        int64_t fnLutVs = cm_compile_function(lLut, "shade_lut_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnLutFs = cm_compile_function(lLut, "shade_lut_fs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnFsVs = cm_compile_function(lPost, "shade_fs_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnMw = cm_compile_function(lPost, "shade_milkyway_bake", 0, 0, 0, serr, sizeof(serr));
        int64_t fnBd0 = cm_compile_function(lPost, "shade_bloom_down0", 0, 0, 0, serr, sizeof(serr));
        int64_t fnBd = cm_compile_function(lPost, "shade_bloom_down", 0, 0, 0, serr, sizeof(serr));
        int64_t fnBu = cm_compile_function(lPost, "shade_bloom_up", 0, 0, 0, serr, sizeof(serr));
        int64_t fnFin = cm_compile_function(lPost, "shade_final", 0, 0, 0, serr, sizeof(serr));
        int64_t fnHist = cm_compile_function(lPost, "shade_histogram", 0, 0, 0, serr, sizeof(serr));
        int64_t fnExp = cm_compile_function(lPost, "shade_exposure", 0, 0, 0, serr, sizeof(serr));
        assert(fnLutVs && fnLutFs && fnFsVs && fnMw && fnBd0 && fnBd && fnBu && fnFin && fnHist && fnExp);

        CMColorAttachmentDesc f16Desc = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
        CMColorAttachmentDesc bloomDesc = { CM_FMT_RG11B10_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
        CMColorAttachmentDesc u8Desc = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
        int64_t pLut = cm_render_pipeline_create(ctx, fnLutVs, fnLutFs, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_lut", serr, sizeof(serr));
        int64_t pMw = cm_render_pipeline_create(ctx, fnFsVs, fnMw, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_mw", serr, sizeof(serr));
        int64_t pBd0 = cm_render_pipeline_create(ctx, fnFsVs, fnBd0, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_bd0", serr, sizeof(serr));
        int64_t pBd = cm_render_pipeline_create(ctx, fnFsVs, fnBd, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_bd", serr, sizeof(serr));
        int64_t pBu = cm_render_pipeline_create(ctx, fnFsVs, fnBu, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_bu", serr, sizeof(serr));
        int64_t pFin = cm_render_pipeline_create(ctx, fnFsVs, fnFin, NULL, 0, NULL, 0, &u8Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2l_fin", serr, sizeof(serr));
        int64_t cHist = cm_compute_pipeline_create(ctx, fnHist, "2l_hist", serr, sizeof(serr));
        int64_t cExp = cm_compute_pipeline_create(ctx, fnExp, "2l_exp", serr, sizeof(serr));
        assert(pLut && pMw && pBd0 && pBd && pBu && pFin && cHist && cExp);

        uint8_t frameBytes[1024] = {0}, lookBytes[1136] = {0}, gpuBytes[512] = {0};
        float *ff = (float *)frameBytes;
        ff[0]=1; ff[5]=1; ff[10]=1; ff[15]=1; // view
        ff[16]=1; ff[21]=1; ff[26]=1; ff[31]=1; // proj
        ff[32]=1; ff[37]=1; ff[42]=1; ff[47]=1; // viewProj
        ff[48]=1; ff[53]=1; ff[58]=1; ff[63]=1; // invViewProj
        ff[120]=0.2f; ff[121]=0.8f; ff[122]=0.4f; ff[123]=0.8f; // sunDirWorld
        ff[132]=0.2f; ff[133]=0.8f; ff[134]=0.4f; ff[135]=1.0f; // lightDirWorld
        ff[136]=4.0f; ff[137]=3.8f; ff[138]=3.5f; ff[139]=3.8f; // sunColor
        ff[212]=128.0f; ff[213]=128.0f; ff[214]=1.0f/128.0f; ff[215]=1.0f/128.0f; // screen
        ff[218]=1.0f; // time.z exposure
        ff[228]=20.0f; ff[229]=0.2f; ff[230]=0.75f; ff[231]=3.4f; // atmosphere

        float *lf = (float *)lookBytes;
        lf[80]=0.0f; lf[81]=1.0f; lf[82]=0.1f; lf[83]=1.0f; // grade0 (byte 320)
        lf[84]=1.0f; lf[85]=1.0f; lf[86]=1.0f; lf[87]=0.55f; // grade1 (byte 336)
        lf[91]=0.0025f; // grade2.w (byte 352)
        lf[92]=1.0f; lf[93]=1.0f; lf[94]=1.0f; lf[95]=0.2f; // grade3 (byte 368)
        lf[96]=1.4f; lf[97]=0.92f; lf[98]=0.8f; lf[99]=0.05f; // tonemap (byte 384)
        lf[100]=1.0f; lf[101]=1.0f; lf[102]=1.0f; lf[103]=0.8f; // output (byte 400)
        lf[104]=0.08f; lf[105]=0.6f; lf[106]=0.06f; lf[107]=1.0f; // bloom (byte 416)
        lf[112]=1.0f; lf[113]=10.0f; lf[114]=67.0f; lf[115]=0.9f; // fogM (byte 448)
        lf[116]=79.0f; lf[117]=0.78f; lf[118]=0.0f; lf[119]=0.0f; // fogMisc (byte 464)
        lf[160]=1.0f; lf[161]=1.0f; lf[162]=1.0f; lf[163]=1.0f; // skyGoldH
        lf[164]=1.0f; lf[165]=1.0f; lf[166]=1.0f; lf[167]=0.0f; // skyGoldZ
        lf[184]=1.75f; lf[185]=1.75f; lf[186]=0.6f; lf[187]=2.2f; // exposureCfg
        lf[196]=0.016f; lf[197]=1.0f; // dt
        int32_t *li = (int32_t *)lookBytes;
        li[200]=1; li[201]=1|2|4|16|32|64; li[202]=0; li[203]=0; // tier
        for (int m = 0; m < 4; m++) {
            int base = (816 + m * 48) / 4;
            lf[base+0]=1; lf[base+5]=1; lf[base+10]=1;
        }
        lf[252]=0.5f; lf[253]=0.55f; lf[254]=0.30f; lf[255]=1.0f; // exposureRef (target=0.5, jump=1)
        lf[280]=1.0f; lf[281]=1.0f; lf[282]=1.0f; lf[283]=0.1f; // look2b

        float *gf = (float *)gpuBytes;
        gf[44]=1.0f; gf[45]=1.0f; gf[46]=1.0f; gf[47]=0.0f; // initial exposure = 1.0

        int64_t fBuf = cm_buffer_create(ctx, 1024, frameBytes, "2l_frame");
        int64_t lBuf = cm_buffer_create(ctx, 1136, lookBytes, "2l_look");
        int64_t gBuf = cm_buffer_create(ctx, 512, gpuBytes, "2l_gpu");
        int64_t rBuf = cm_buffer_create(ctx, 256, NULL, "2l_res");
        int64_t dumShd = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 1, 1, 2, 1, 0, 1, 1, 0, "2l_shd");
        int64_t lutTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 128, 80, 1, 1, 0, 1, 1, 0, "2l_lut");
        int64_t mwTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 64, 32, 1, 1, 0, 1, 1, 0, "2l_mw");
        int64_t hdrTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 128, 128, 1, 1, 0, 1, 1, 0, "2l_hdr");
        int64_t depTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 128, 128, 1, 1, 0, 1, 1, 0, "2l_dep");
        int64_t finTex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 128, 128, 1, 1, 0, 1, 1, 0, "2l_fin");
        int64_t bDown[6], bAcc[5];
        for (int i = 0; i < 6; i++) {
            int bw = MAX(1, 64 >> i), bh = MAX(1, 64 >> i);
            bDown[i] = cm_texture_create(ctx, CM_FMT_RG11B10_FLOAT, bw, bh, 1, 1, 0, 1, 1, 0, "2l_bd");
            bAcc[i < 5 ? i : 4] = (i >= 1 && i < 5)
                ? cm_texture_create(ctx, CM_FMT_RG11B10_FLOAT, bw, bh, 1, 1, 0, 1, 1, 0, "2l_ba") : 0;
        }
        int64_t cmpS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
        int64_t linS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);
        int64_t finRead = cm_buffer_create(ctx, 128 * 128 * 4, NULL, "2l_finRead");

        cm_cmd_begin(ctx);
        cm_shade_set_globals(ctx, fBuf, 0, lBuf, 0, gBuf, 0, rBuf, 0, dumShd, lutTex, cmpS, linS);
        cm_shade_set_enabled(ctx, 1);
        cm_shade_set_resource(ctx, 0, mwTex);
        cm_blit_clear_depth(ctx, dumShd, 1.0);
        cm_blit_clear_color_depth(ctx, hdrTex, 0.24f, 0.14f, 0.08f, 1.0f, depTex, 0.5);
        cm_shade_fullscreen_pass(ctx, pMw, mwTex, NULL, 0, NULL, 0, NULL, 0);
        cm_shade_fullscreen_pass(ctx, pLut, lutTex, NULL, 0, NULL, 0, NULL, 0);
        float dp[4] = {1.0f, 1.0f, 0.0f, 0.0f};
        cm_shade_fullscreen_pass(ctx, pBd0, bDown[0], &hdrTex, 1, NULL, 0, dp, sizeof(dp));
        for (int i = 1; i < 6; i++) {
            cm_shade_fullscreen_pass(ctx, pBd, bDown[i], &bDown[i - 1], 1, NULL, 0, NULL, 0);
        }
        for (int i = 4; i >= 1; i--) {
            int64_t pair[2] = { bDown[i], (i == 4) ? bDown[5] : bAcc[i + 1] };
            float up[4] = { (float)(i + 1), (i == 4) ? 6.0f : 1.0f, 0.0f, 0.0f };
            cm_shade_fullscreen_pass(ctx, pBu, bAcc[i], pair, 2, NULL, 0, up, sizeof(up));
        }
        float fp[24] = {0};
        fp[0]=0.05f; fp[1]=1.0f; fp[4]=1.0f; fp[5]=1.0f; fp[6]=1.6f; fp[7]=0.4f;
        fp[12]=128.0f; fp[13]=128.0f; fp[17]=1.0f; fp[18]=1.0f; fp[19]=1.0f;
        int64_t finTexs[4] = { hdrTex, bAcc[1], depTex, bDown[0] };
        cm_shade_fullscreen_pass(ctx, pFin, finTex, finTexs, 4, NULL, 0, fp, sizeof(fp));
        cm_shade_exposure_run(ctx, cHist, cExp, bDown[2], gBuf, 0, lBuf, 0, 1, 1);
        cm_shade_set_enabled(ctx, 0);
        cm_blit_copy_texture_to_buffer(ctx, finTex, 0, 0, 0, 0, 128, 128, finRead, 0, 128 * 4);
        uint64_t sv2l = cm_cmd_submit(ctx, 2);
        assert(cm_wait_submit(ctx, sv2l, 5000000000ULL) == 1);

        const uint8_t *px = (const uint8_t *)cm_buffer_contents(finRead);
        assert(px != NULL);
        const float *gpuOut = (const float *)cm_buffer_contents(gBuf);
        char err2l[512] = {0};
        cm_device_drain_errors(ctx, err2l, sizeof(err2l));
        // Tonemapped mid-tone clear (0.24, 0.14, 0.08) must produce ordered, finite non-clipped RGB output
        assert(px[0] > px[1] && px[1] > px[2] && px[2] > 10);
        if (!(px[0] > 40 && px[0] < 255) || !(px[1] > 20 && px[1] < 255) || px[3] != 255 || !isfinite(gpuOut[44])) {
            fprintf(stderr, "FAIL 2l [%s]: px=(%u,%u,%u,%u) exp=(%.4f, %.4f) gpuErr=%s\n",
                    preferMetal4 ? "Metal 4" : "Metal 3",
                    px[0], px[1], px[2], px[3], gpuOut[44], gpuOut[45], err2l);
            exit(1);
        }
        assert(isfinite(gpuOut[44]) && gpuOut[44] > 0.05f && gpuOut[44] < 10.0f);
        printf("[Backend %s] Test 2l P1 HDR+LUT+Bloom+Exposure+Final OK (rgb=%u,%u,%u, exp=%.3f)\n",
               preferMetal4 ? "Metal 4" : "Metal 3", px[0], px[1], px[2], gpuOut[44]);

        // Sample the same radial fade used by terrain, post haze and reflected hits.
        NSString *edgeSrc = [NSString stringWithFormat:
            @"%@\n"
             "kernel void chunk_edge_probe(constant ShadeFrame &f [[buffer(0)]], constant ShadeLook &l [[buffer(1)]],"
             "                             device float *out [[buffer(2)]]) {\n"
             "    out[0] = shadeChunkEdgeFade(float3(24.0, 100.0, 0.0), f, l);\n"
             "    out[1] = shadeChunkEdgeFade(float3(43.0, 0.0, 0.0), f, l);\n"
             "    out[2] = shadeChunkEdgeFade(float3(25.8, -80.0, 34.4), f, l);\n"
             "    out[3] = shadeChunkEdgeFade(float3(-48.0, 100.0, 0.0), f, l);\n"
             "    out[4] = shadeChunkEdgeDepthFade(out[1]);\n"
             "    out[5] = shadeChunkEdgeDepthFade(shadeChunkEdgeFade(float3(46.0, 0.0, 0.0), f, l));\n"
             "    out[6] = shadeChunkEdgeDiscard(out[3], float2(12.0, 18.0)) ? 1.0 : 0.0;\n"
             "}\n", prelude];
        int64_t edgeLib = cm_compile_msl_library(ctx, edgeSrc.UTF8String, "chunk edge probe", 1, serr, sizeof(serr));
        assert(edgeLib);
        int64_t edgeFn = cm_compile_function(edgeLib, "chunk_edge_probe", 0, 0, 0, serr, sizeof(serr));
        int64_t edgePso = cm_compute_pipeline_create(ctx, edgeFn, "chunk edge probe", serr, sizeof(serr));
        int64_t edgeRead = cm_buffer_create(ctx, 7 * sizeof(float), NULL, "chunk edge results");
        assert(edgeFn && edgePso && edgeRead);
        int64_t edgeBuffers[3] = { fBuf, lBuf, edgeRead };
        int64_t edgeOffsets[3] = {0};
        float *edgeLook = (float *)(void *)cm_buffer_contents(lBuf);
        int32_t *edgeFrame = (int32_t *)(void *)cm_buffer_contents(fBuf);
        edgeLook[118] = 56.0f; // 4-chunk render distance, minus the existing 8-block inset
        for (int test = 0; test < 3; test++) {
            edgeFrame[241] = test == 1 ? 1 : 0; // underwater
            ((float *)edgeFrame)[250] = test == 2 ? 32.0f : 0.0f; // legacy A/B switch
            cm_cmd_begin(ctx);
            cm_compute_dispatch(ctx, edgePso, edgeBuffers, edgeOffsets, 3, NULL, 0, NULL, 0, 1, 1, 1, 1, 1, 1);
            assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
            const float *out = (const float *)(void *)cm_buffer_contents(edgeRead);
            assert(out[0] == 0.0f && out[4] == 0.0f);
            if (test == 0) {
                assert(out[1] > 0.0f && out[1] < 1.0f && fabsf(out[1] - out[2]) < 1e-5f);
                assert(out[3] == 1.0f && out[5] > 0.0f && out[5] < 1.0f && out[6] == 1.0f);
            } else {
                assert(out[1] == 0.0f && out[3] == 0.0f && out[6] == 0.0f);
            }
        }
        assert(cm_device_drain_errors(ctx, serr, sizeof(serr)) == 0);
        cm_buffer_destroy(ctx, edgeRead);
        cm_compute_pipeline_destroy(ctx, edgePso);
        cm_function_destroy(edgeFn);
        cm_library_destroy(edgeLib);
        printf("[Backend %s] Chunk edge radial fade, depth coverage, and fog bypass OK\n",
               preferMetal4 ? "Metal 4" : "Metal 3");

        cm_shade_set_globals(ctx, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        cm_shade_set_resource(ctx, 0, 0);
        cm_buffer_destroy(ctx, finRead);
        cm_sampler_destroy(ctx, cmpS); cm_sampler_destroy(ctx, linS);
        for (int i = 0; i < 6; i++) {
            cm_texture_destroy(ctx, bDown[i]);
            if (i >= 1 && i < 5 && bAcc[i]) cm_texture_destroy(ctx, bAcc[i]);
        }
        cm_texture_destroy(ctx, finTex); cm_texture_destroy(ctx, depTex); cm_texture_destroy(ctx, hdrTex);
        cm_texture_destroy(ctx, mwTex); cm_texture_destroy(ctx, lutTex); cm_texture_destroy(ctx, dumShd);
        cm_buffer_destroy(ctx, rBuf); cm_buffer_destroy(ctx, gBuf); cm_buffer_destroy(ctx, lBuf); cm_buffer_destroy(ctx, fBuf);
        cm_compute_pipeline_destroy(ctx, cExp); cm_compute_pipeline_destroy(ctx, cHist);
        cm_pipeline_destroy(ctx, pFin); cm_pipeline_destroy(ctx, pBu); cm_pipeline_destroy(ctx, pBd);
        cm_pipeline_destroy(ctx, pBd0); cm_pipeline_destroy(ctx, pMw); cm_pipeline_destroy(ctx, pLut);
        cm_function_destroy(fnExp); cm_function_destroy(fnHist); cm_function_destroy(fnFin);
        cm_function_destroy(fnBu); cm_function_destroy(fnBd); cm_function_destroy(fnBd0);
        cm_function_destroy(fnMw); cm_function_destroy(fnFsVs); cm_function_destroy(fnLutFs); cm_function_destroy(fnLutVs);
        cm_library_destroy(lPost); cm_library_destroy(lLut);
    }

    // 2m. P2 Shadow depth array render (Vanilla + Sodium pulled-vertex) & compare_sampler verification
    {
        NSString *repoAssets = [NSString stringWithUTF8String:getenv("CELESTIA_TEST_ASSETS") ?: "src/main/resources/assets/celestiametal"];
        NSString *portedDir = [repoAssets stringByAppendingPathComponent:@"shaders/ported"];
        char serr[4096] = {0};

        int64_t lSod = cm_compile_msl_library(ctx, read_file_str([portedDir stringByAppendingPathComponent:@"shadow_sodium.metal"]).UTF8String, "2m_sod", 1, serr, sizeof(serr));
        int64_t lVan = cm_compile_msl_library(ctx, read_file_str([portedDir stringByAppendingPathComponent:@"shadow_vanilla.metal"]).UTF8String, "2m_van", 1, serr, sizeof(serr));
        assert(lSod && lVan);
        int64_t fnSodVs = cm_compile_function(lSod, "shadow_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnSodCvs = cm_compile_function(lSod, "shadow_cutout_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnSodCfs = cm_compile_function(lSod, "shadow_cutout_fs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnVanVs = cm_compile_function(lVan, "shadow_vanilla_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnVanCvs = cm_compile_function(lVan, "shadow_vanilla_cutout_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnVanCfs = cm_compile_function(lVan, "shadow_vanilla_cutout_fs", 0, 0, 0, serr, sizeof(serr));
        assert(fnSodVs && fnSodCvs && fnSodCfs && fnVanVs && fnVanCvs && fnVanCfs);

        int64_t pSodSolid = cm_render_pipeline_create(ctx, fnSodVs, 0, NULL, 0, NULL, 0, NULL, 0, CM_FMT_D16_UNORM, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2m_sod_s", serr, sizeof(serr));
        int64_t pSodCut = cm_render_pipeline_create(ctx, fnSodCvs, fnSodCfs, NULL, 0, NULL, 0, NULL, 0, CM_FMT_D16_UNORM, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2m_sod_c", serr, sizeof(serr));
        int64_t pVanSolid = cm_render_pipeline_create(ctx, fnVanVs, 0, NULL, 0, NULL, 0, NULL, 0, CM_FMT_D16_UNORM, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2m_van_s", serr, sizeof(serr));
        int64_t pVanCut = cm_render_pipeline_create(ctx, fnVanCvs, fnVanCfs, NULL, 0, NULL, 0, NULL, 0, CM_FMT_D16_UNORM, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2m_van_c", serr, sizeof(serr));
        assert(pSodSolid && pSodCut && pVanSolid && pVanCut);

        const char *recvSrc =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct VOut { float4 pos [[position]]; float2 uv; };\n"
            "vertex VOut rv_vs(uint vid [[vertex_id]]) {\n"
            "    float2 ndc = float2(vid == 1u ? 3.0 : -1.0, vid == 2u ? 3.0 : -1.0);\n"
            "    VOut o; o.pos = float4(ndc, 0.0, 1.0); o.uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5); return o;\n"
            "}\n"
            "fragment float4 rv_fs(VOut in [[stage_in]], depth2d_array<float> sm [[texture(0)]], sampler cmp [[sampler(0)]]) {\n"
            "    float c0 = sm.sample_compare(cmp, in.uv, 0u, 0.3);\n"
            "    float c1 = sm.sample_compare(cmp, in.uv, 1u, 0.3);\n"
            "    return float4(c0, c1, 0.0, 1.0);\n"
            "}\n";
        int64_t lRecv = cm_compile_msl_library(ctx, recvSrc, "2m_recv", 1, serr, sizeof(serr));
        assert(lRecv);
        int64_t fnRvs = cm_compile_function(lRecv, "rv_vs", 0, 0, 0, serr, sizeof(serr));
        int64_t fnRfs = cm_compile_function(lRecv, "rv_fs", 0, 0, 0, serr, sizeof(serr));
        CMColorAttachmentDesc u8Desc = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
        int64_t pRecv = cm_render_pipeline_create(ctx, fnRvs, fnRfs, NULL, 0, NULL, 0, &u8Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2m_recv_p", serr, sizeof(serr));
        assert(pRecv);

        int64_t shdTex = cm_texture_create(ctx, CM_FMT_D16_UNORM, 256, 256, 2, 1, 0, 1, 1, 0, "2m_shd");
        int64_t outTex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 64, 64, 1, 1, 0, 1, 1, 0, "2m_out");
        int64_t outView = cm_texture_view_create(ctx, outTex, 0, 1);
        int64_t dummyPre = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 16, 16, 1, 1, 0, 1, 1, 0, "2m_pre");
        int64_t dummyPreView = cm_texture_view_create(ctx, dummyPre, 0, 1);
        int64_t cmpS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
        int64_t nearS = cm_sampler_create(ctx, 1, 1, 0, 0, 0, 1, 0, 0);
        int64_t outRead = cm_buffer_create(ctx, 64 * 64 * 4, NULL, "2m_read");

        float cascadeBytes[20] = {0};
        set_identity(cascadeBytes); // depthBias = 0

        // Vanilla 28-byte vertex quad covering x in [-1, 0], y in [-1, 1], z = 0.7
        uint8_t vanVerts[4 * 28] = {0};
        const float vanPos[4][3] = { {-1.0f, -1.0f, 0.7f}, {0.0f, -1.0f, 0.7f}, {0.0f, 1.0f, 0.7f}, {-1.0f, 1.0f, 0.7f} };
        for (int k = 0; k < 4; k++) memcpy(vanVerts + k * 28, vanPos[k], 12);
        int64_t vanBuf = cm_buffer_create(ctx, sizeof(vanVerts), vanVerts, "2m_vanV");

        // Test non-zero draw index (baseInstance=1): draw 0 off-screen, draw 1 at origin 0
        CMShadowVanillaDraw vanDraws[2] = {
            { vanBuf, 0, 1, 0, 10.0f, 10.0f, 0.0f, 0.0f },
            { vanBuf, 0, 1, 0, 0.0f, 0.0f, 0.0f, 0.0f }
        };

        // Sodium 20-byte vertex quad covering x in [0, 1], y in [-1, 1], z = 0.7 (region origin (-8,-8,0) shifts model +8)
        uint32_t sodVerts[4 * 5] = {0};
        const float sodPos[4][3] = { {8.0f, 7.0f, 0.7f}, {9.0f, 7.0f, 0.7f}, {9.0f, 9.0f, 0.7f}, {8.0f, 9.0f, 0.7f} };
        for (int k = 0; k < 4; k++) {
            uint32_t qx = (uint32_t)llround((sodPos[k][0] + 8.0) * (1048576.0 / 32.0));
            uint32_t qy = (uint32_t)llround((sodPos[k][1] + 8.0) * (1048576.0 / 32.0));
            uint32_t qz = (uint32_t)llround((sodPos[k][2] + 8.0) * (1048576.0 / 32.0));
            sodVerts[k * 5 + 0] = ((qx >> 10) & 0x3FFu) | (((qy >> 10) & 0x3FFu) << 10) | (((qz >> 10) & 0x3FFu) << 20);
            sodVerts[k * 5 + 1] = (qx & 0x3FFu) | ((qy & 0x3FFu) << 10) | ((qz & 0x3FFu) << 20);
        }
        int64_t sodArena = cm_buffer_create(ctx, sizeof(sodVerts), sodVerts, "2m_sodV");
        uint32_t sodChunks[4] = { 0u, 0u, 0u, (0u & 63u) | (1u << 6) }; // chunk 1 uses region 1
        float sodRegions[8] = { 0,0,0,0, -8.0f, -8.0f, 0.0f, 0.0f };
        int64_t chunksBuf = cm_buffer_create(ctx, sizeof(sodChunks), sodChunks, "2m_chunks");
        int64_t regionsBuf = cm_buffer_create(ctx, sizeof(sodRegions), sodRegions, "2m_regions");
        CMShadowSodiumDraw sodDraw = { sodArena, 1, 1, 0, 0 };

        cm_cmd_begin(ctx);
        // Leave a soft-ended render pass open before shadow passes to verify cm_flush_encoders ordering
        int32_t doClr = 1; float cZero[4] = {0, 0, 0, 1};
        cm_pass_begin(ctx, &dummyPreView, &doClr, cZero, 1, 0, 0, 0.0, 0, 0, 16, 16, "2m_soft");
        cm_pass_finish(ctx);

        cm_shadow_render_vanilla(ctx, shdTex, 0, 256, pVanSolid, pVanCut, cascadeBytes, sizeof(cascadeBytes),
                                 vanDraws, 2, 0, nearS, 0.0f, 0.0f, 0);
        cm_shadow_render_sodium(ctx, shdTex, 1, 256, pSodSolid, pSodCut, cascadeBytes, sizeof(cascadeBytes),
                                chunksBuf, 0, regionsBuf, 0, &sodDraw, 1, 0, nearS, 0.0f, 0.0f, 0);

        cm_pass_begin(ctx, &outView, &doClr, cZero, 1, 0, 0, 0.0, 0, 0, 64, 64, "2m_recvPass");
        cm_pass_set_pipeline(ctx, pRecv);
        cm_pass_set_texture_sampler(ctx, 0, shdTex, 0, cmpS);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_end(ctx);
        cm_blit_copy_texture_to_buffer(ctx, outTex, 0, 0, 0, 0, 64, 64, outRead, 0, 64 * 4);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);

        const uint8_t *rp = (const uint8_t *)cm_buffer_contents(outRead);
        const uint8_t *leftPx = rp + (32 * 64 + 16) * 4;
        const uint8_t *rightPx = rp + (32 * 64 + 48) * 4;
        if (leftPx[0] > 10 || leftPx[1] < 245 || rightPx[0] < 245 || rightPx[1] > 10) {
            fprintf(stderr, "FAIL 2m [%s]: left=(%u,%u,%u) right=(%u,%u,%u)\n",
                    preferMetal4 ? "Metal 4" : "Metal 3",
                    leftPx[0], leftPx[1], leftPx[2], rightPx[0], rightPx[1], rightPx[2]);
            exit(1);
        }
        printf("[Backend %s] Test 2m P2 Shadow cascades (Vanilla+Sodium+cmp) OK (L=%u,%u R=%u,%u)\n",
               preferMetal4 ? "Metal 4" : "Metal 3", leftPx[0], leftPx[1], rightPx[0], rightPx[1]);

        cm_buffer_destroy(ctx, regionsBuf); cm_buffer_destroy(ctx, chunksBuf); cm_buffer_destroy(ctx, sodArena);
        cm_buffer_destroy(ctx, vanBuf); cm_buffer_destroy(ctx, outRead);
        cm_sampler_destroy(ctx, nearS); cm_sampler_destroy(ctx, cmpS);
        cm_texture_view_destroy(ctx, dummyPreView); cm_texture_destroy(ctx, dummyPre);
        cm_texture_view_destroy(ctx, outView); cm_texture_destroy(ctx, outTex); cm_texture_destroy(ctx, shdTex);
        cm_pipeline_destroy(ctx, pRecv); cm_function_destroy(fnRfs); cm_function_destroy(fnRvs); cm_library_destroy(lRecv);
        cm_pipeline_destroy(ctx, pVanCut); cm_pipeline_destroy(ctx, pVanSolid);
        cm_pipeline_destroy(ctx, pSodCut); cm_pipeline_destroy(ctx, pSodSolid);
        cm_function_destroy(fnVanCfs); cm_function_destroy(fnVanCvs); cm_function_destroy(fnVanVs);
        cm_function_destroy(fnSodCfs); cm_function_destroy(fnSodCvs); cm_function_destroy(fnSodVs);
        cm_library_destroy(lVan); cm_library_destroy(lSod);
    }

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
    NSString *nativeDir = @"tools/fixtures/shaderpacks/celestia-native";
    NSString *minimalDir = @"tools/fixtures/shaderpacks/celestia-minimal";

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
        printf("[Shader fixtures] Compiled legacy pack fixtures on M1 Pro GPU with 0 errors!\n");
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

// Synthetic Minecraft-like frame: color+depth clear, then many load-only passes on the main target
// (sky, terrain layers, entities, particles, GUI layers ...). Compares GPU time with pass merging and
// clear folding enabled vs disabled at the given resolution.
static double run_pass_merge_frame(int64_t ctx, int64_t pso, int64_t vbo, int64_t ctex, int64_t cview,
                                   int64_t dtex, int64_t dview, int32_t w, int32_t h, int passes) {
    int32_t loadFlag = 0;
    float clr[4] = {0, 0, 0, 1};
    cm_cmd_begin(ctx);
    cm_blit_clear_color_depth(ctx, ctex, 0.2f, 0.4f, 0.8f, 1.0f, dtex, 0.0);
    for (int p = 0; p < passes; p++) {
        cm_pass_begin(ctx, &cview, &loadFlag, clr, 1, dview, 0, 0.0, 0, 0, w, h, "MergeBench");
        cm_pass_set_pipeline(ctx, pso);
        cm_pass_set_vertex_buffer(ctx, 0, vbo, 0, 16);
        cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
        cm_pass_finish(ctx);
    }
    uint64_t s = cm_cmd_submit(ctx, 2);
    cm_wait_submit(ctx, s, 5000000000ULL);
    return (double)cm_device_last_gpu_ns(ctx) / 1.0e6;
}

static void benchmark_pass_merging(int32_t preferMetal4) {
    const int32_t W = 3024, H = 1752, PASSES = 24, WARM = 4, ITERS = 30;
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    int64_t ctex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, W, H, 1, 1, 0, 1, 1, 0, "BenchMain");
    int64_t cview = cm_texture_view_create(ctx, ctex, 0, 1);
    int64_t dtex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "BenchDepth");
    int64_t dview = cm_texture_view_create(ctx, dtex, 0, 1);
    const char *msl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct VIn { float4 pos [[attribute(0)]]; };\n"
        "struct VOut { float4 pos [[position]]; };\n"
        "vertex VOut vs_b(VIn in [[stage_in]]) { VOut o; o.pos = in.pos; return o; }\n"
        "fragment half4 fs_b() { return half4(0.9h, 0.6h, 0.3h, 1.0h); }\n";
    char err[2048] = {0};
    int64_t lib = cm_compile_msl_library(ctx, msl, "merge_bench", 0, err, sizeof(err));
    int64_t vs = cm_compile_function(lib, "vs_b", 0, 0, 0, err, sizeof(err));
    int64_t fs = cm_compile_function(lib, "fs_b", 0, 0, 0, err, sizeof(err));
    CMVertexBufferDesc vb = { 0, 16, 0 };
    CMAttribBindingDesc at = { 0, 0, 0, CM_FMT_RGBA32_FLOAT };
    CMColorAttachmentDesc cd = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pso = cm_render_pipeline_create(ctx, vs, fs, &vb, 1, &at, 1, &cd, 1, CM_FMT_D32_FLOAT,
                                            CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1,
                                            0.0f, 0.0f, "MergeBenchPSO", err, sizeof(err));
    // Small triangle: per-pass fragment work is tiny, so the frame cost is dominated by pass overhead
    float tri[12] = { -0.1f, -0.1f, 0.5f, 1.0f,  0.1f, -0.1f, 0.5f, 1.0f,  0.0f, 0.1f, 0.5f, 1.0f };
    int64_t vbo = cm_buffer_create(ctx, sizeof(tri), tri, "MergeBenchVbo");
    assert(ctex && cview && dtex && dview && lib && pso && vbo);

    double avg[2] = {0, 0};
    for (int mode = 0; mode < 2; mode++) {
        int on = mode == 0;
        cm_device_set_option(ctx, CM_OPT_PASS_MERGE, on);
        cm_device_set_option(ctx, CM_OPT_DEFER_CLEARS, on);
        for (int i = 0; i < WARM; i++) run_pass_merge_frame(ctx, pso, vbo, ctex, cview, dtex, dview, W, H, PASSES);
        double sum = 0;
        for (int i = 0; i < ITERS; i++) sum += run_pass_merge_frame(ctx, pso, vbo, ctex, cview, dtex, dview, W, H, PASSES);
        avg[mode] = sum / ITERS;
    }
    printf("[Benchmark %s @ %dx%d] %d-pass frame GPU avg: merged %.3f ms vs unmerged %.3f ms (%.2fx)\n",
           preferMetal4 ? "Metal 4" : "Metal 3", W, H, PASSES, avg[0], avg[1], avg[1] / MAX(avg[0], 1e-6));

    char drained[1024] = {0};
    if (cm_device_drain_errors(ctx, drained, sizeof(drained)) > 0) {
        fprintf(stderr, "FAIL: GPU reported errors during pass-merge benchmark: %s\n", drained);
        exit(1);
    }
    cm_buffer_destroy(ctx, vbo);
    cm_pipeline_destroy(ctx, pso);
    cm_function_destroy(fs);
    cm_function_destroy(vs);
    cm_library_destroy(lib);
    cm_texture_view_destroy(ctx, dview);
    cm_texture_destroy(ctx, dtex);
    cm_texture_view_destroy(ctx, cview);
    cm_texture_destroy(ctx, ctex);
    cm_device_destroy(ctx);
}

// CPU encode cost per draw through the Celestia C ABI with realistic state changes between draws:
// (a) draws only, (b) Sodium-like per-draw push constants + uniform-buffer offset, (c) (b) + texture switches (Xaero-like).
static void benchmark_draw_overhead(int32_t preferMetal4) {
    const int DRAWS = 2000, WARM = 10, FRAMES = 60;
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    int64_t ctex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 3024, 1752, 1, 1, 0, 1, 1, 0, "DrawBenchRT");
    int64_t cview = cm_texture_view_create(ctx, ctex, 0, 1);
    int64_t texA = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 16, 16, 1, 1, 0, 0, 1, 0, "DrawBenchTexA");
    int64_t texB = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 16, 16, 1, 1, 0, 0, 1, 0, "DrawBenchTexB");
    int64_t viewA = cm_texture_view_create(ctx, texA, 0, 1), viewB = cm_texture_view_create(ctx, texB, 0, 1);
    int64_t samp = cm_sampler_create(ctx, 1, 1, 0, 0, 0, 1, 0, 0);
    const char *msl =
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct U { float4 off; };\n"
        "struct P { float4 tint; float4 pad; };\n"
        "struct VOut { float4 pos [[position]]; };\n"
        "vertex VOut vs_d(uint vid [[vertex_id]], constant U &u [[buffer(0)]], constant P &p [[buffer(15)]]) {\n"
        "  VOut o; float2 q = float2(vid & 1, vid >> 1) * 0.01f - 1.0f + u.off.xy + p.tint.zw * 0.0f; o.pos = float4(q, 0.5f, 1.0f); return o;\n"
        "}\n"
        "fragment half4 fs_d(texture2d<half> t [[texture(0)]], sampler s [[sampler(0)]], constant P &p [[buffer(15)]]) {\n"
        "  return t.sample(s, float2(0.5f)) * half4(p.tint);\n"
        "}\n";
    char err[2048] = {0};
    int64_t lib = cm_compile_msl_library(ctx, msl, "draw_bench", 0, err, sizeof(err));
    if (!lib) { fprintf(stderr, "draw bench msl: %s\n", err); exit(1); }
    int64_t vs = cm_compile_function(lib, "vs_d", 0, 0, 0, err, sizeof(err));
    int64_t fs = cm_compile_function(lib, "fs_d", 0, 0, 0, err, sizeof(err));
    CMColorAttachmentDesc cd = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pso = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &cd, 1, -1, CM_TOPO_TRIANGLE_STRIP, 0, 0, 0,
                                            CM_CMP_ALWAYS, 0, 0.0f, 0.0f, "DrawBenchPSO", err, sizeof(err));
    int64_t ubo = cm_buffer_create(ctx, 256 * DRAWS, NULL, "DrawBenchUbo");
    uint16_t idx[4] = { 0, 1, 2, 3 };
    int64_t ibo = cm_buffer_create(ctx, sizeof(idx), idx, "DrawBenchIbo");
    assert(ctex && cview && viewA && viewB && samp && pso && ubo && ibo);
    int32_t loadFlag = 0;
    float clr[4] = {0, 0, 0, 1};
    const char *names[3] = { "draws only", "push consts + UBO offset", "+ texture switch / 4 draws" };
    for (int mode = 0; mode < 3; mode++) {
        double sum = 0.0;
        for (int f = 0; f < WARM + FRAMES; f++) {
            cm_cmd_begin(ctx);
            cm_pass_begin(ctx, &cview, &loadFlag, clr, 1, 0, 0, 0.0, 0, 0, 3024, 1752, NULL);
            cm_pass_set_pipeline(ctx, pso);
            cm_pass_set_index_buffer(ctx, ibo, 0);
            cm_pass_set_uniform_buffer(ctx, 0, ubo, 0);
            cm_pass_set_texture_sampler(ctx, 0, viewA, 0, samp);
            float pc[8] = { 1, 1, 1, 1, 0, 0, 0, 0 };
            cm_pass_push_constants(ctx, 15, pc, sizeof(pc));
            CFTimeInterval t0 = CACurrentMediaTime();
            for (int d = 0; d < DRAWS; d++) {
                if (mode >= 1) {
                    pc[0] = (float)(d & 255) / 255.0f;
                    cm_pass_push_constants(ctx, 15, pc, sizeof(pc));
                    cm_pass_set_uniform_buffer(ctx, 0, ubo, (int64_t)d * 256);
                }
                if (mode >= 2 && (d & 3) == 0) {
                    cm_pass_set_texture_sampler(ctx, 0, ((d >> 2) & 1) ? viewB : viewA, 0, samp);
                }
                cm_pass_draw_indexed(ctx, CM_TOPO_TRIANGLE_STRIP, 0, 4, 1, 0, 0, 0);
            }
            CFTimeInterval t1 = CACurrentMediaTime();
            cm_pass_end(ctx);
            uint64_t sv = cm_cmd_submit(ctx, 2);
            cm_wait_submit(ctx, sv, 5000000000ULL);
            if (f >= WARM) sum += (t1 - t0) * 1000.0;
        }
        double ms = sum / FRAMES;
        printf("[Benchmark %s draw overhead] %-28s %.3f ms / %d draws = %.3f us/draw\n",
               preferMetal4 ? "Metal 4" : "Metal 3", names[mode], ms, DRAWS, ms * 1000.0 / DRAWS);
    }
    char drained[512] = {0};
    if (cm_device_drain_errors(ctx, drained, sizeof(drained)) > 0) {
        fprintf(stderr, "FAIL: GPU errors in draw-overhead benchmark: %s\n", drained);
        exit(1);
    }
    cm_buffer_destroy(ctx, ibo); cm_buffer_destroy(ctx, ubo);
    cm_pipeline_destroy(ctx, pso); cm_function_destroy(fs); cm_function_destroy(vs); cm_library_destroy(lib);
    cm_sampler_destroy(ctx, samp);
    cm_texture_view_destroy(ctx, viewB); cm_texture_view_destroy(ctx, viewA);
    cm_texture_destroy(ctx, texB); cm_texture_destroy(ctx, texA);
    cm_texture_view_destroy(ctx, cview); cm_texture_destroy(ctx, ctex);
    cm_device_destroy(ctx);
}

// GPU cost of the world upscale at real sizes: 75% and 50% of 3024x1752 -> 3024x1752, bilinear vs MetalFX Spatial.
static void benchmark_upscale(int32_t preferMetal4) {
    const int OW = 3024, OH = 1752, ITERS = 30;
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    int64_t dst = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, OW, OH, 1, 1, 0, 1, 1, 0, "UpBenchDst");
    const int pct[2] = { 75, 50 };
    for (int pi = 0; pi < 2; pi++) {
        int iw = OW * pct[pi] / 100, ih = OH * pct[pi] / 100;
        int64_t src = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, iw, ih, 1, 1, 0, 1, 1, 0, "UpBenchSrc");
        for (int mode = 0; mode < 2; mode++) {
            double sum = 0; int used = -1;
            for (int i = 0; i < ITERS + 5; i++) {
                cm_cmd_begin(ctx);
                used = cm_upscale_to(ctx, src, dst, mode);
                uint64_t sv = cm_cmd_submit(ctx, 2);
                cm_wait_submit(ctx, sv, 5000000000ULL);
                if (i >= 5) sum += (double)cm_device_last_gpu_ns(ctx) / 1e6;
            }
            printf("[Benchmark %s upscale] %d%% %dx%d -> %dx%d %-16s %.3f ms GPU\n", preferMetal4 ? "Metal 4" : "Metal 3",
                   pct[pi], iw, ih, OW, OH, used == 1 ? "MetalFX Spatial" : "bilinear", sum / ITERS);
        }
        cm_texture_destroy(ctx, src);
    }
    cm_texture_destroy(ctx, dst);
    cm_device_destroy(ctx);
}

static void benchmark_p1_hdr_post(NSString *assetsDir, int32_t preferMetal4) {
    const int W = 3024, H = 1752, WARM = 4, ITERS = 20;
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *portedDir = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    NSString *slots = read_file_str([portedDir stringByAppendingPathComponent:@"shade_slots.metal"]);
    NSString *lookSrc = read_file_str([portedDir stringByAppendingPathComponent:@"shade_look.metal"]);
    NSString *commonSrc = read_file_str([portedDir stringByAppendingPathComponent:@"shade_common.metal"]);
    NSString *m2Src = read_file_str([portedDir stringByAppendingPathComponent:@"shade_m2.metal"]);
    NSString *vuniSrc = read_file_str([portedDir stringByAppendingPathComponent:@"vanilla_uniforms.metal"]);
    NSString *prelude = [NSString stringWithFormat:@"#define MCOPT_SHADE 1\n#define MCOPT_HDR 1\n%@\n%@\n%@\n%@\n%@\n",
                         slots, lookSrc, commonSrc, m2Src, vuniSrc];

    char err[2048] = {0};
    NSString *lutSrc = [NSString stringWithFormat:@"%@\n%@", prelude, read_file_str([portedDir stringByAppendingPathComponent:@"sky_lut.metal"])];
    NSString *postSrc = [NSString stringWithFormat:@"%@\n%@", prelude, read_file_str([portedDir stringByAppendingPathComponent:@"shade_post.metal"])];
    int64_t lLut = cm_compile_msl_library(ctx, lutSrc.UTF8String, "BenchLut", 1, err, sizeof(err));
    int64_t lPost = cm_compile_msl_library(ctx, postSrc.UTF8String, "BenchPost", 1, err, sizeof(err));
    assert(lLut && lPost);

    int64_t fnLutVs = cm_compile_function(lLut, "shade_lut_vs", 0, 0, 0, err, sizeof(err));
    int64_t fnLutFs = cm_compile_function(lLut, "shade_lut_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnFsVs = cm_compile_function(lPost, "shade_fs_vs", 0, 0, 0, err, sizeof(err));
    int64_t fnBd0 = cm_compile_function(lPost, "shade_bloom_down0", 0, 0, 0, err, sizeof(err));
    int64_t fnBd = cm_compile_function(lPost, "shade_bloom_down", 0, 0, 0, err, sizeof(err));
    int64_t fnBu = cm_compile_function(lPost, "shade_bloom_up", 0, 0, 0, err, sizeof(err));
    int64_t fnFin = cm_compile_function(lPost, "shade_final", 0, 0, 0, err, sizeof(err));
    int64_t fnHist = cm_compile_function(lPost, "shade_histogram", 0, 0, 0, err, sizeof(err));
    int64_t fnExp = cm_compile_function(lPost, "shade_exposure", 0, 0, 0, err, sizeof(err));

    CMColorAttachmentDesc f16Desc = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    CMColorAttachmentDesc bloomDesc = { CM_FMT_RG11B10_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    CMColorAttachmentDesc u8Desc = { CM_FMT_RGBA8_UNORM, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pLut = cm_render_pipeline_create(ctx, fnLutVs, fnLutFs, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp_lut", err, sizeof(err));
    int64_t pBd0 = cm_render_pipeline_create(ctx, fnFsVs, fnBd0, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp_bd0", err, sizeof(err));
    int64_t pBd = cm_render_pipeline_create(ctx, fnFsVs, fnBd, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp_bd", err, sizeof(err));
    int64_t pBu = cm_render_pipeline_create(ctx, fnFsVs, fnBu, NULL, 0, NULL, 0, &bloomDesc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp_bu", err, sizeof(err));
    int64_t pFin = cm_render_pipeline_create(ctx, fnFsVs, fnFin, NULL, 0, NULL, 0, &u8Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp_fin", err, sizeof(err));
    int64_t cHist = cm_compute_pipeline_create(ctx, fnHist, "bp_hist", err, sizeof(err));
    int64_t cExp = cm_compute_pipeline_create(ctx, fnExp, "bp_exp", err, sizeof(err));
    assert(pLut && pBd0 && pBd && pBu && pFin && cHist && cExp);

    uint8_t frameBytes[1024] = {0}, lookBytes[1136] = {0}, gpuBytes[512] = {0};
    float *ff = (float *)frameBytes, *lf = (float *)lookBytes, *gf = (float *)gpuBytes;
    ff[0]=1; ff[5]=1; ff[10]=1; ff[15]=1; ff[16]=1; ff[21]=1; ff[26]=1; ff[31]=1;
    ff[32]=1; ff[37]=1; ff[42]=1; ff[47]=1; ff[48]=1; ff[53]=1; ff[58]=1; ff[63]=1;
    ff[120]=0.2f; ff[121]=0.8f; ff[122]=0.4f; ff[123]=0.8f;
    ff[132]=0.2f; ff[133]=0.8f; ff[134]=0.4f; ff[135]=1.0f;
    ff[136]=4.0f; ff[137]=3.8f; ff[138]=3.5f; ff[139]=3.8f;
    ff[212]=(float)W; ff[213]=(float)H; ff[214]=1.0f/(float)W; ff[215]=1.0f/(float)H;
    ff[218]=1.0f; ff[228]=20.0f; ff[229]=0.2f; ff[230]=0.75f; ff[231]=3.4f;
    lf[81]=1.0f; lf[82]=0.1f; lf[83]=1.0f; lf[84]=1.0f; lf[85]=1.0f; lf[86]=1.0f; lf[87]=0.55f; lf[91]=0.0025f;
    lf[92]=1.0f; lf[93]=1.0f; lf[94]=1.0f; lf[95]=0.2f; lf[96]=1.4f; lf[97]=0.92f; lf[98]=0.8f; lf[99]=0.05f;
    lf[100]=1.0f; lf[101]=1.0f; lf[102]=1.0f; lf[103]=0.8f; lf[104]=0.08f; lf[105]=0.6f; lf[106]=0.06f; lf[107]=1.0f;
    lf[112]=1.0f; lf[113]=10.0f; lf[114]=67.0f; lf[115]=0.9f; lf[116]=79.0f; lf[117]=0.78f;
    lf[160]=1.0f; lf[161]=1.0f; lf[162]=1.0f; lf[163]=1.0f; lf[164]=1.0f; lf[165]=1.0f; lf[166]=1.0f;
    lf[184]=1.75f; lf[185]=1.75f; lf[186]=0.6f; lf[187]=2.2f; lf[196]=0.016f; lf[197]=1.0f;
    int32_t *li = (int32_t *)lookBytes; li[200]=1; li[201]=1|2|4|16|32|64;
    for (int m = 0; m < 4; m++) { int base = (816 + m * 48) / 4; lf[base+0]=1; lf[base+5]=1; lf[base+10]=1; }
    lf[252]=0.5f; lf[253]=0.55f; lf[254]=0.30f; lf[280]=1.0f; lf[281]=1.0f; lf[282]=1.0f; lf[283]=0.1f;
    gf[44]=1.0f; gf[45]=1.0f; gf[46]=1.0f;

    int64_t fBuf = cm_buffer_create(ctx, 1024, frameBytes, "bp_frame");
    int64_t lBuf = cm_buffer_create(ctx, 1136, lookBytes, "bp_look");
    int64_t gBuf = cm_buffer_create(ctx, 512, gpuBytes, "bp_gpu");
    int64_t rBuf = cm_buffer_create(ctx, 256, NULL, "bp_res");
    int64_t dumShd = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 1, 1, 2, 1, 0, 1, 1, 0, "bp_shd");
    int64_t lutTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 128, 80, 1, 1, 0, 1, 1, 0, "bp_lut");
    int64_t hdrTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "bp_hdr");
    int64_t depTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "bp_dep");
    int64_t finTex = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, W, H, 1, 1, 0, 1, 1, 0, "bp_fin");
    int64_t bDown[6], bAcc[5];
    for (int i = 0; i < 6; i++) {
        int bw = MAX(1, (W / 2) >> i), bh = MAX(1, (H / 2) >> i);
        bDown[i] = cm_texture_create(ctx, CM_FMT_RG11B10_FLOAT, bw, bh, 1, 1, 0, 1, 1, 0, "bp_bd");
        bAcc[i < 5 ? i : 4] = (i >= 1 && i < 5)
            ? cm_texture_create(ctx, CM_FMT_RG11B10_FLOAT, bw, bh, 1, 1, 0, 1, 1, 0, "bp_ba") : 0;
    }
    int64_t cmpS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
    int64_t linS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);

    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, dumShd, 1.0);
    cm_blit_clear_color_depth(ctx, hdrTex, 0.24f, 0.18f, 0.12f, 1.0f, depTex, 0.35);
    cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL);
    cm_shade_set_globals(ctx, fBuf, 0, lBuf, 0, gBuf, 0, rBuf, 0, dumShd, lutTex, cmpS, linS);

    double gpuMsSum = 0.0;
    for (int f = 0; f < WARM + ITERS; f++) {
        cm_cmd_begin(ctx);
        cm_shade_set_enabled(ctx, 1);
        cm_shade_fullscreen_pass(ctx, pLut, lutTex, NULL, 0, NULL, 0, NULL, 0);
        float dp[4] = {1.0f, 1.0f, 0.0f, 0.0f};
        cm_shade_fullscreen_pass(ctx, pBd0, bDown[0], &hdrTex, 1, NULL, 0, dp, sizeof(dp));
        for (int i = 1; i < 6; i++) cm_shade_fullscreen_pass(ctx, pBd, bDown[i], &bDown[i - 1], 1, NULL, 0, NULL, 0);
        for (int i = 4; i >= 1; i--) {
            int64_t pair[2] = { bDown[i], (i == 4) ? bDown[5] : bAcc[i + 1] };
            float up[4] = { (float)(i + 1), (i == 4) ? 6.0f : 1.0f, 0.0f, 0.0f };
            cm_shade_fullscreen_pass(ctx, pBu, bAcc[i], pair, 2, NULL, 0, up, sizeof(up));
        }
        float fp[24] = {0};
        fp[0]=0.05f; fp[1]=1.0f; fp[4]=1.0f; fp[5]=1.0f; fp[6]=1.6f; fp[7]=0.4f;
        fp[12]=(float)W; fp[13]=(float)H; fp[17]=1.0f; fp[18]=1.0f; fp[19]=1.0f;
        int64_t finTexs[4] = { hdrTex, bAcc[1], depTex, bDown[0] };
        cm_shade_fullscreen_pass(ctx, pFin, finTex, finTexs, 4, NULL, 0, fp, sizeof(fp));
        int gx = MAX(1, ((W >> 3) / 2 + 7) / 8), gy = MAX(1, ((H >> 3) / 2 + 7) / 8);
        cm_shade_exposure_run(ctx, cHist, cExp, bDown[2], gBuf, 0, lBuf, 0, gx, gy);
        cm_shade_set_enabled(ctx, 0);
        cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL);
        if (f >= WARM) gpuMsSum += (double)cm_device_last_gpu_ns(ctx) / 1e6;
    }
    double avgMs = gpuMsSum / ITERS;
    printf("[Benchmark M1 Pro %s @ %dx%d] P1 HDR Post (LUT+6-lvl Bloom+Exp+Final) synthetic avg: %.3f ms GPU (%.1f FPS ceiling)\n",
           api, W, H, avgMs, 1000.0 / avgMs);

    cm_shade_set_globals(ctx, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    cm_sampler_destroy(ctx, cmpS); cm_sampler_destroy(ctx, linS);
    for (int i = 0; i < 6; i++) {
        cm_texture_destroy(ctx, bDown[i]);
        if (i >= 1 && i < 5 && bAcc[i]) cm_texture_destroy(ctx, bAcc[i]);
    }
    cm_texture_destroy(ctx, finTex); cm_texture_destroy(ctx, depTex); cm_texture_destroy(ctx, hdrTex);
    cm_texture_destroy(ctx, lutTex); cm_texture_destroy(ctx, dumShd);
    cm_buffer_destroy(ctx, rBuf); cm_buffer_destroy(ctx, gBuf); cm_buffer_destroy(ctx, lBuf); cm_buffer_destroy(ctx, fBuf);
    cm_compute_pipeline_destroy(ctx, cExp); cm_compute_pipeline_destroy(ctx, cHist);
    cm_pipeline_destroy(ctx, pFin); cm_pipeline_destroy(ctx, pBu); cm_pipeline_destroy(ctx, pBd);
    cm_pipeline_destroy(ctx, pBd0); cm_pipeline_destroy(ctx, pLut);
    cm_function_destroy(fnExp); cm_function_destroy(fnHist); cm_function_destroy(fnFin);
    cm_function_destroy(fnBu); cm_function_destroy(fnBd); cm_function_destroy(fnBd0);
    cm_function_destroy(fnFsVs); cm_function_destroy(fnLutFs); cm_function_destroy(fnLutVs);
    cm_library_destroy(lPost); cm_library_destroy(lLut);
    cm_device_destroy(ctx);
}

static void benchmark_p2_shadow(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *portedDir = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    char err[2048] = {0};

    int64_t lSod = cm_compile_msl_library(ctx, read_file_str([portedDir stringByAppendingPathComponent:@"shadow_sodium.metal"]).UTF8String, "bp2_sod", 1, err, sizeof(err));
    int64_t fnVs = cm_compile_function(lSod, "shadow_vs", 0, 0, 0, err, sizeof(err));
    int64_t pSolid = cm_render_pipeline_create(ctx, fnVs, 0, NULL, 0, NULL, 0, NULL, 0, CM_FMT_D16_UNORM, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "bp2_s", err, sizeof(err));
    assert(pSolid);

    const int QUADS = 50000;
    const int CHUNK_QUADS = 32;
    const int CHUNKS = (QUADS + CHUNK_QUADS - 1) / CHUNK_QUADS;
    uint32_t *verts = (uint32_t *)calloc((size_t)QUADS * 4 * 5, sizeof(uint32_t));
    for (int q = 0; q < QUADS; q++) {
        float x0 = -0.9f + (float)(q % 100) * 0.018f;
        float y0 = -0.9f + (float)((q / 100) % 100) * 0.018f;
        const float dx[4] = {0.0f, 0.015f, 0.015f, 0.0f};
        const float dy[4] = {0.0f, 0.0f, 0.015f, 0.015f};
        for (int c = 0; c < 4; c++) {
            uint32_t qx = (uint32_t)llround((x0 + dx[c] + 8.0) * (1048576.0 / 32.0));
            uint32_t qy = (uint32_t)llround((y0 + dy[c] + 8.0) * (1048576.0 / 32.0));
            uint32_t qz = (uint32_t)llround(8.5 * (1048576.0 / 32.0));
            size_t base = ((size_t)q * 4 + c) * 5;
            verts[base + 0] = ((qx >> 10) & 0x3FFu) | (((qy >> 10) & 0x3FFu) << 10) | (((qz >> 10) & 0x3FFu) << 20);
            verts[base + 1] = (qx & 0x3FFu) | ((qy & 0x3FFu) << 10) | ((qz & 0x3FFu) << 20);
        }
    }
    uint32_t *chunks = (uint32_t *)calloc((size_t)CHUNKS * 2, sizeof(uint32_t));
    for (int i = 0; i < CHUNKS; i++) {
        int rem = QUADS - i * CHUNK_QUADS;
        int q = rem > CHUNK_QUADS ? CHUNK_QUADS : rem;
        chunks[i * 2 + 0] = (uint32_t)(i * CHUNK_QUADS * 4);
        chunks[i * 2 + 1] = (uint32_t)((q - 1) & 63);
    }
    float regionOrigin[4] = {0, 0, 0, 0};
    int64_t vBuf = cm_buffer_create(ctx, (int64_t)QUADS * 4 * 20, verts, "bp2_arena");
    int64_t cBuf = cm_buffer_create(ctx, (int64_t)CHUNKS * 8, chunks, "bp2_chunks");
    int64_t rBuf = cm_buffer_create(ctx, sizeof(regionOrigin), regionOrigin, "bp2_regions");
    int64_t shdTex = cm_texture_create(ctx, CM_FMT_D16_UNORM, 2048, 2048, 2, 1, 0, 1, 1, 0, "bp2_shd");
    free(verts);
    free(chunks);

    float cascadeBytes[20] = {0};
    set_identity(cascadeBytes);
    CMShadowSodiumDraw drawRec = { vBuf, 0, (uint32_t)CHUNKS, 0, 0 };

    const int WARM = 4, ITERS = 20;
    double gpuMsSum = 0.0;
    for (int f = 0; f < WARM + ITERS; f++) {
        cm_cmd_begin(ctx);
        cm_shadow_render_sodium(ctx, shdTex, 0, 2048, pSolid, 0, cascadeBytes, sizeof(cascadeBytes),
                                cBuf, 0, rBuf, 0, &drawRec, 1, 0, 0, 1.0f, 0.01f, 0);
        cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL);
        if (f >= WARM) gpuMsSum += (double)cm_device_last_gpu_ns(ctx) / 1e6;
    }
    double avgMs = gpuMsSum / ITERS;
    printf("[Benchmark M1 Pro %s @ 2048x2048] P2 Shadow Cascade (50k quads, D16) synthetic avg: %.3f ms GPU\n",
           api, avgMs);

    cm_texture_destroy(ctx, shdTex);
    cm_buffer_destroy(ctx, rBuf); cm_buffer_destroy(ctx, cBuf); cm_buffer_destroy(ctx, vBuf);
    cm_pipeline_destroy(ctx, pSolid); cm_function_destroy(fnVs); cm_library_destroy(lSod);
    cm_device_destroy(ctx);
}

static NSString *build_water_bake_msl(NSString *portedDir) {
    NSMutableString *s = [NSMutableString stringWithString:
        @"#define MCOPT_SHADE 1\n"
         "#define MCOPT_HDR 1\n"
         "#define SHADE_WATER 1\n"
         "#define SHADE_SSR 1\n"
         "#define SHADE_SSR_HIER 1\n"
         "#define SHADE_SSRH_THICK 2.0\n"
         "#define SHADE_SSRH_OWN 1\n"
         "#define SHADE_SSRH_THIN 1\n"
         "#define SHADE_SSR_STEPS 24\n"
         "#define SHADE_SSR_RAWZ 1\n"
         "#define SHADE_SSR_LEAN2 1\n"
         "#define SHADE_SSR_EDGE 1\n"
         "#define SHADE_SSR_THICK_K 1.5\n"
         "#define SHADE_SSR_BEHIND 0\n"
         "#define SHADE_SSR_TOP 0.15\n"
         "#define SHADE_SSR_SIDE 0.25\n"
         "#define SHADE_SSR_SIDE_END 0.0\n"
         "#define SHADE_SSR_PREV 1\n"
         "#define SHADE_CAUSTICS 1\n"
         "#define SHADE_FOAM 1\n"
         "#define SHADE_GLOSSY 1\n"
         "#define SHADE_WATER_DETAIL 1\n"
         "#define SHADE_WATER_DETAIL_SIZE 256\n"
         "#define SHADE_WATER_DETAIL_FAR 112.0\n"
         "#define SHADE_WATER_PATTERN_FAR 0.075\n"
         "#define SHADE_WATER_SMOOTH 1\n"
         "#define SHADE_WATER_GLINT_GRAZE 1\n"
         "#define SHADE_WAVE_BAKE 1\n"
         "#define SHADE_WATER_SWELL 1\n"
         "#define SHADE_WATER_SWELL_BAKED 1\n"
         "#define SHADE_WATER_GLITTER 1\n"
         "#define SHADE_WATER_SUBRECT 1\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"shade_slots.metal"])];
    [s appendString:@"\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"shade_look.metal"])];
    [s appendString:@"\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"shade_common.metal"])];
    [s appendString:@"\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"shade_m2.metal"])];
    [s appendString:@"\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"shade_post.metal"])];
    [s appendString:@"\n"];
    [s appendString:read_file_str([portedDir stringByAppendingPathComponent:@"water.metal"])];
    return s;
}

static void verify_p3a_water(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *portedDir = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    char err[4096] = {0};

    NSString *waterSrc = build_water_bake_msl(portedDir);
    int64_t wLib = cm_compile_msl_library(ctx, waterSrc.UTF8String, "2n_water", 1, err, sizeof(err));
    if (!wLib) {
        fprintf(stderr, "FAIL compiling water.metal (%s):\n%s\n", api, err);
        exit(1);
    }
    int64_t fnFsVs = cm_compile_function(wLib, "shade_fs_vs", 0, 0, 0, err, sizeof(err));
    int64_t fnBake = cm_compile_function(wLib, "shade_water_bake_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnDet  = cm_compile_function(wLib, "shade_water_bake_detail_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnSwl  = cm_compile_function(wLib, "shade_water_bake_swell_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnPyr  = cm_compile_function(wLib, "shade_water_pyr_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnPyr2 = cm_compile_function(wLib, "shade_water_pyr2_fs", 0, 0, 0, err, sizeof(err));
    assert(fnFsVs && fnBake && fnDet && fnSwl && fnPyr && fnPyr2);

    CMColorAttachmentDesc f16Desc = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    CMColorAttachmentDesc rg16Desc = { CM_FMT_RG16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pBake = cm_render_pipeline_create(ctx, fnFsVs, fnBake, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2n_bake", err, sizeof(err));
    int64_t pDet  = cm_render_pipeline_create(ctx, fnFsVs, fnDet,  NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2n_det", err, sizeof(err));
    int64_t pSwl  = cm_render_pipeline_create(ctx, fnFsVs, fnSwl,  NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2n_swl", err, sizeof(err));
    int64_t pPyr  = cm_render_pipeline_create(ctx, fnFsVs, fnPyr,  NULL, 0, NULL, 0, &rg16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2n_pyr", err, sizeof(err));
    int64_t pPyr2 = cm_render_pipeline_create(ctx, fnFsVs, fnPyr2, NULL, 0, NULL, 0, &rg16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "2n_pyr2", err, sizeof(err));
    assert(pBake && pDet && pSwl && pPyr && pPyr2);

    // Probe shader that draws opaque quad on left half and samples captured water bindings on right half
    NSString *probeMsl = [NSString stringWithFormat:
        @"%@\n"
         "struct POut { float4 pos [[position]]; float2 uv; };\n"
         "vertex POut p_vs(uint vid [[vertex_id]]) {\n"
         "    POut o;\n"
         "    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);\n"
         "    o.pos = float4(p, 0.75, 1.0);\n"
         "    o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);\n"
         "    return o;\n"
         "}\n"
         "fragment float4 p_opq_fs(POut in [[stage_in]]) {\n"
         "    if (in.uv.x > 0.5) discard_fragment();\n"
         "    return float4(0.25, 0.85, 0.35, 1.0);\n"
         "}\n"
         "fragment float4 p_wtr_fs(POut in [[stage_in]],\n"
         "                         texture2d<half> sc [[texture(%d)]],\n"
         "                         depth2d<float> dc [[texture(%d)]],\n"
         "                         texture2d<half> wv [[texture(%d)]],\n"
         "                         texture2d<float> pyr [[texture(%d)]],\n"
         "                         texture2d<half> det [[texture(%d)]],\n"
         "                         constant float4 *wp [[buffer(%d)]],\n"
         "                         constant ShadeResources &res [[buffer(CM_SHADE_BUF_RESOURCES)]]) {\n"
         "    if (in.uv.x <= 0.5) discard_fragment();\n"
         "    constexpr sampler ls(filter::linear, mip_filter::linear, address::repeat);\n"
         "    float3 opq = float3(sc.read(uint2(32, 64)).rgb);\n"
         "    float dep = dc.read(uint2(32, 64));\n"
         "    float2 p16 = pyr.read(uint2(2, 4)).xy;\n"
         "    uint row128 = (128u + 15u) / 16u;\n"
         "    float2 p128 = pyr.read(uint2(0, row128)).xy;\n"
         "    float2 wSlope0 = float2(wv.sample(ls, float2(0.13, 0.27), level(0.0)).xy);\n"
         "    float2 wSlope3 = float2(wv.sample(ls, float2(0.13, 0.27), level(3.0)).xy);\n"
         "    float dLen = length(float2(det.sample(ls, float2(0.41, 0.19), level(1.0)).xy));\n"
         "    float swell = length(float2(res.waterSwell.sample(ls, float2(0.31, 0.71), level(2.0)).xy));\n"
         "    return float4(opq.g > 0.7 && dep > 0.7 ? 1.0 : 0.0,\n"
         "                  p16.x > 0.7 && p128.x > 0.7 ? 1.0 : 0.0,\n"
         "                  length(wSlope0) > 1e-4 && length(wSlope3) > 1e-4 && dLen > 1e-4 && swell > 1e-4 ? 1.0 : 0.0,\n"
         "                  wp[2].w > 0.5 ? 1.0 : 0.0);\n"
         "}\n",
        waterSrc,
        CM_SHADE_TEX_WATER_SCENE, CM_SHADE_TEX_WATER_DEPTH, CM_SHADE_TEX_WATER_WAVES,
        CM_SHADE_TEX_WATER_PYR, CM_SHADE_TEX_WATER_DETAIL, CM_SHADE_BUF_WATER];

    int64_t pLib = cm_compile_msl_library(ctx, probeMsl.UTF8String, "2n_probe", 1, err, sizeof(err));
    assert(pLib != 0);
    int64_t pVs = cm_compile_function(pLib, "p_vs", 0, 0, 0, err, sizeof(err));
    int64_t pOpqFs = cm_compile_function(pLib, "p_opq_fs", 0, 0, 0, err, sizeof(err));
    int64_t pWtrFs = cm_compile_function(pLib, "p_wtr_fs", 0, 0, 0, err, sizeof(err));
    int64_t pOpqPso = cm_render_pipeline_create(ctx, pVs, pOpqFs, NULL, 0, NULL, 0, &f16Desc, 1, CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2n_opq", err, sizeof(err));
    int64_t pWtrPso = cm_render_pipeline_create(ctx, pVs, pWtrFs, NULL, 0, NULL, 0, &f16Desc, 1, CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_GREATER_EQUAL, 1, 0, 0, "2n_wtr", err, sizeof(err));
    assert(pOpqPso && pWtrPso);

    uint8_t zeroFrame[1024] = {0};
    float *ff = (float *)zeroFrame;
    ff[0]=1; ff[5]=1; ff[10]=1; ff[15]=1;
    ff[248] = 1.25f; // sunPath.w = waterTime = 1.25s so wave height/slopes are non-zero
    uint8_t zeroLook[1136] = {0};
    uint8_t zeroGpu[512] = {0};
    float waterParams[64] = {0};
    waterParams[8] = 1.0f;  // state.x
    waterParams[11] = 1.0f; // state.w = baked waves ready
    waterParams[12] = 1.0f; // tune.x

    int64_t fBuf = cm_buffer_create(ctx, sizeof(zeroFrame), zeroFrame, "2n_frame");
    int64_t lBuf = cm_buffer_create(ctx, sizeof(zeroLook), zeroLook, "2n_look");
    int64_t gBuf = cm_buffer_create(ctx, sizeof(zeroGpu), zeroGpu, "2n_gpu");
    int64_t rBuf = cm_buffer_create(ctx, 256, NULL, "2n_res");
    int64_t wpBuf = cm_buffer_create(ctx, 256, waterParams, "2n_wp");
    int64_t dShd = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 1, 1, 2, 1, 0, 1, 1, 0, "2n_shd");
    int64_t sLut = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 8, 8, 1, 1, 0, 1, 1, 0, "2n_lut");
    int64_t cmpS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
    int64_t linS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);

    int64_t wavesTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 512, 512, 1, 10, 0, 1, 1, 0, "2n_waves");
    int64_t detTex   = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 256, 256, 1, 9, 0, 1, 1, 0, "2n_detT");
    int64_t swlTex   = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 256, 256, 1, 9, 0, 1, 1, 0, "2n_swlT");

    const int W = 128, H = 128;
    int64_t colTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "2n_col");
    int64_t colView = cm_texture_view_create(ctx, colTex, 0, 1);
    int64_t depTex = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "2n_dep");
    int64_t depView = cm_texture_view_create(ctx, depTex, 0, 1);
    int64_t rb = cm_buffer_create(ctx, (int64_t)W * H * 8, NULL, "2n_rb");

    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, dShd, 1.0);
    cm_shade_set_globals(ctx, fBuf, 0, lBuf, 0, gBuf, 0, rBuf, 0, dShd, sLut, cmpS, linS);
    cm_shade_set_enabled(ctx, 1);
    cm_water_set_params(ctx, wpBuf, 0, wavesTex, detTex, 1);

    // Bake three independent textures and check that their mipmaps share one blit encoder.
    cm_shade_set_resource(ctx, 15, swlTex);
    cm_shade_fullscreen_pass(ctx, pBake, wavesTex, NULL, 0, NULL, 0, NULL, 0);
    cm_shade_fullscreen_pass(ctx, pDet, detTex, NULL, 0, NULL, 0, NULL, 0);
    cm_shade_fullscreen_pass(ctx, pSwl, swlTex, NULL, 0, NULL, 0, NULL, 0);
    int64_t before[CM_STAT_COUNT], after[CM_STAT_COUNT];
    cm_device_stats(ctx, before, CM_STAT_COUNT);
    cm_water_generate_mipmaps(ctx, wavesTex, detTex, swlTex);
    cm_device_stats(ctx, after, CM_STAT_COUNT);
    assert(after[CM_STAT_BLIT_ENCODERS] == before[CM_STAT_BLIT_ENCODERS] + 1);

    // Render opaque left half, capture scene+depth+pyramid mid-pass, draw probing water on right half
    int32_t clrOn = 1;
    float clrVal[4] = { 0.05f, 0.05f, 0.1f, 1.0f };
    cm_pass_begin(ctx, &colView, &clrOn, clrVal, 1, depView, 1, 0.0, 0, 0, W, H, "2n_world");
    cm_pass_set_pipeline(ctx, pOpqPso);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);

    int32_t captured = cm_water_capture(ctx, pPyr, pPyr2);
    assert(captured == 1);

    cm_pass_set_pipeline(ctx, pWtrPso);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_end(ctx);

    cm_blit_copy_texture_to_buffer(ctx, colTex, 0, 0, 0, 0, W, H, rb, 0, W * 8);
    cm_shade_set_enabled(ctx, 0);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);

    char drained[1024] = {0};
    int errCnt = cm_device_drain_errors(ctx, drained, sizeof(drained));
    assert(errCnt == 0);

    const uint16_t *px = (const uint16_t *)cm_buffer_contents(rb);
    // Left half pixel (32, 64) preserved MTLLoadActionLoad green (g=0.85h -> > 0x3900)
    const uint16_t *leftH = px + (64 * W + 32) * 4;
    // Right half pixel (96, 64): r=1 (scene+depth copy), g=1 (pyr16+pyr128), b=1 (waves+detail mips), a=1 (params)
    const uint16_t *rightH = px + (64 * W + 96) * 4;
    if (leftH[1] < 0x3800 || rightH[0] != 0x3C00 || rightH[1] != 0x3C00 || rightH[2] != 0x3C00 || rightH[3] != 0x3C00) {
        fprintf(stderr, "FAIL 2n [%s]: left=(0x%04x,0x%04x,0x%04x,0x%04x) right=(0x%04x,0x%04x,0x%04x,0x%04x)\n",
                api, leftH[0], leftH[1], leftH[2], leftH[3], rightH[0], rightH[1], rightH[2], rightH[3]);
        exit(1);
    }
    printf("[Backend %s] Test 2n P3a Water (scene+depth capture, 3-pass RG16F pyramid, wave/detail/swell bake+mips, reopened pass) OK\n", api);

    cm_shade_set_globals(ctx, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    cm_water_set_params(ctx, 0, 0, 0, 0, 0);
    cm_buffer_destroy(ctx, rb);
    cm_texture_view_destroy(ctx, depView); cm_texture_destroy(ctx, depTex);
    cm_texture_view_destroy(ctx, colView); cm_texture_destroy(ctx, colTex);
    cm_texture_destroy(ctx, swlTex); cm_texture_destroy(ctx, detTex); cm_texture_destroy(ctx, wavesTex);
    cm_sampler_destroy(ctx, linS); cm_sampler_destroy(ctx, cmpS);
    cm_texture_destroy(ctx, sLut); cm_texture_destroy(ctx, dShd);
    cm_buffer_destroy(ctx, wpBuf); cm_buffer_destroy(ctx, rBuf); cm_buffer_destroy(ctx, gBuf); cm_buffer_destroy(ctx, lBuf); cm_buffer_destroy(ctx, fBuf);
    cm_pipeline_destroy(ctx, pWtrPso); cm_pipeline_destroy(ctx, pOpqPso);
    cm_function_destroy(pWtrFs); cm_function_destroy(pOpqFs); cm_function_destroy(pVs); cm_library_destroy(pLib);
    cm_pipeline_destroy(ctx, pPyr2); cm_pipeline_destroy(ctx, pPyr);
    cm_pipeline_destroy(ctx, pSwl); cm_pipeline_destroy(ctx, pDet); cm_pipeline_destroy(ctx, pBake);
    cm_function_destroy(fnPyr2); cm_function_destroy(fnPyr);
    cm_function_destroy(fnSwl); cm_function_destroy(fnDet); cm_function_destroy(fnBake); cm_function_destroy(fnFsVs);
    cm_library_destroy(wLib);
    cm_device_destroy(ctx);
}

static void benchmark_p3a_water(NSString *assetsDir, int32_t preferMetal4) {
    const int W = 3024, H = 1752, WARM = 3, ITERS = 12;
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx != 0);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *portedDir = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    char err[4096] = {0};

    int64_t wLib = cm_compile_msl_library(ctx, build_water_bake_msl(portedDir).UTF8String, "bp3a", 1, err, sizeof(err));
    int64_t fnFsVs = cm_compile_function(wLib, "shade_fs_vs", 0, 0, 0, err, sizeof(err));
    int64_t fnBake = cm_compile_function(wLib, "shade_water_bake_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnDet  = cm_compile_function(wLib, "shade_water_bake_detail_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnSwl  = cm_compile_function(wLib, "shade_water_bake_swell_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnPyr  = cm_compile_function(wLib, "shade_water_pyr_fs", 0, 0, 0, err, sizeof(err));
    int64_t fnPyr2 = cm_compile_function(wLib, "shade_water_pyr2_fs", 0, 0, 0, err, sizeof(err));
    CMColorAttachmentDesc f16Desc = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    CMColorAttachmentDesc rg16Desc = { CM_FMT_RG16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pBake = cm_render_pipeline_create(ctx, fnFsVs, fnBake, NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp3a_bake", err, sizeof(err));
    int64_t pDet  = cm_render_pipeline_create(ctx, fnFsVs, fnDet,  NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp3a_det", err, sizeof(err));
    int64_t pSwl  = cm_render_pipeline_create(ctx, fnFsVs, fnSwl,  NULL, 0, NULL, 0, &f16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp3a_swl", err, sizeof(err));
    int64_t pPyr  = cm_render_pipeline_create(ctx, fnFsVs, fnPyr,  NULL, 0, NULL, 0, &rg16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp3a_pyr", err, sizeof(err));
    int64_t pPyr2 = cm_render_pipeline_create(ctx, fnFsVs, fnPyr2, NULL, 0, NULL, 0, &rg16Desc, 1, -1, CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "bp3a_pyr2", err, sizeof(err));

    uint8_t zero[1136] = {0};
    ((float *)zero)[248] = 2.0f;
    int64_t fBuf = cm_buffer_create(ctx, 1024, zero, "bp3a_f");
    int64_t lBuf = cm_buffer_create(ctx, 1136, zero, "bp3a_l");
    int64_t gBuf = cm_buffer_create(ctx, 512, zero, "bp3a_g");
    int64_t rBuf = cm_buffer_create(ctx, 256, NULL, "bp3a_r");
    int64_t wpBuf = cm_buffer_create(ctx, 256, zero, "bp3a_wp");
    int64_t dShd = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 1, 1, 2, 1, 0, 1, 1, 0, "bp3a_d");
    int64_t sLut = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 8, 8, 1, 1, 0, 1, 1, 0, "bp3a_lut");
    int64_t cmpS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
    int64_t linS = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);
    int64_t wavesTex = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 512, 512, 1, 10, 0, 1, 1, 0, "bp3a_w");
    int64_t detTex   = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 256, 256, 1, 9, 0, 1, 1, 0, "bp3a_dt");
    int64_t swlTex   = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 256, 256, 1, 9, 0, 1, 1, 0, "bp3a_sw");
    int64_t colTex   = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "bp3a_c");
    int64_t colView  = cm_texture_view_create(ctx, colTex, 0, 1);
    int64_t depTex   = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "bp3a_dp");
    int64_t depView  = cm_texture_view_create(ctx, depTex, 0, 1);

    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, dShd, 1.0);
    cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL);
    cm_shade_set_globals(ctx, fBuf, 0, lBuf, 0, gBuf, 0, rBuf, 0, dShd, sLut, cmpS, linS);
    cm_water_set_params(ctx, wpBuf, 0, wavesTex, detTex, 1);

    double gpuMsSum = 0.0;
    int32_t noClr = 0; float clr[4] = {0};
    for (int f = 0; f < WARM + ITERS; f++) {
        cm_cmd_begin(ctx);
        cm_shade_set_enabled(ctx, 1);
        cm_shade_fullscreen_pass(ctx, pBake, wavesTex, NULL, 0, NULL, 0, NULL, 0);
        cm_shade_fullscreen_pass(ctx, pDet, detTex, NULL, 0, NULL, 0, NULL, 0);
        cm_shade_fullscreen_pass(ctx, pSwl, swlTex, NULL, 0, NULL, 0, NULL, 0);
        cm_water_generate_mipmaps(ctx, wavesTex, detTex, swlTex);
        cm_pass_begin(ctx, &colView, &noClr, clr, 1, depView, 0, 0.0, 0, 0, W, H, "bp3a_main");
        cm_water_capture(ctx, pPyr, pPyr2);
        cm_pass_end(ctx);
        cm_shade_set_enabled(ctx, 0);
        cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL);
        if (f >= WARM) gpuMsSum += (double)cm_device_last_gpu_ns(ctx) / 1e6;
    }
    printf("[Benchmark M1 Pro %s @ %dx%d] P3a Water Prep (512^2 waves+256^2 ripples/swell+mips+copy+3-pass pyr) synthetic avg: %.3f ms GPU\n",
           api, W, H, gpuMsSum / ITERS);

    cm_shade_set_globals(ctx, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    cm_water_set_params(ctx, 0, 0, 0, 0, 0);
    cm_texture_view_destroy(ctx, depView); cm_texture_destroy(ctx, depTex);
    cm_texture_view_destroy(ctx, colView); cm_texture_destroy(ctx, colTex);
    cm_texture_destroy(ctx, swlTex); cm_texture_destroy(ctx, detTex); cm_texture_destroy(ctx, wavesTex);
    cm_sampler_destroy(ctx, linS); cm_sampler_destroy(ctx, cmpS);
    cm_texture_destroy(ctx, sLut); cm_texture_destroy(ctx, dShd);
    cm_buffer_destroy(ctx, wpBuf); cm_buffer_destroy(ctx, rBuf); cm_buffer_destroy(ctx, gBuf); cm_buffer_destroy(ctx, lBuf); cm_buffer_destroy(ctx, fBuf);
    cm_pipeline_destroy(ctx, pPyr2); cm_pipeline_destroy(ctx, pPyr);
    cm_pipeline_destroy(ctx, pSwl); cm_pipeline_destroy(ctx, pDet); cm_pipeline_destroy(ctx, pBake);
    cm_function_destroy(fnPyr2); cm_function_destroy(fnPyr);
    cm_function_destroy(fnSwl); cm_function_destroy(fnDet); cm_function_destroy(fnBake); cm_function_destroy(fnFsVs);
    cm_library_destroy(wLib);
    cm_device_destroy(ctx);
}

static void verify_p3b_atmosphere(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx);
    NSString *ported = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    NSMutableString *source = [NSMutableString stringWithString:
        @"#define MCOPT_SHADE 1\n#define MCOPT_HDR 1\n#define SHADE_WX_NOISE_BAKE 1\n"
         "#define CELESTIA_VL_MARCH 1\n#define CELESTIA_VL_COMPOSITE 1\n#define CELESTIA_SSAO 1\n"];
    for (NSString *fn in @[@"shade_slots.metal", @"shade_look.metal", @"shade_common.metal", @"shade_m2.metal", @"vl.metal",
                           @"ssao.metal", @"shade_post.metal", @"clouds.metal", @"weather_surface.metal"]) {
        [source appendFormat:@"%@\n", read_file_str([ported stringByAppendingPathComponent:fn])];
    }
    [source appendString:
        @"struct AoDepthFixture { half4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
         "fragment AoDepthFixture ao_depth_fixture(ShadeFsOut in [[stage_in]]) {"
         "return {half4(0.0h), in.uv.x < 0.5 ? 0.022 : 0.02}; }\n"
         "fragment half4 snell_fixture() {\n"
         "    const float3 up = float3(0.0, 1.0, 0.0);\n"
         "    float4 normal = shadeSnellExit(up, up);\n"
         "    float4 angled = shadeSnellExit(float3(0.5, 0.8660254, 0.0), up);\n"
         "    float4 edge = shadeSnellExit(float3(0.7431448, 0.6691306, 0.0), up);\n"
         "    float4 outside = shadeSnellExit(float3(0.7660444, 0.6427876, 0.0), up);\n"
         "    return half4(normal.w, angled.x, edge.w, outside.w == 1.0 && all(outside.xyz == 0.0) ? 1.0 : 0.0);\n"
         "}\n"];
    char err[4096] = {0};
    int64_t lib = cm_compile_msl_library(ctx, source.UTF8String, "P3b atmosphere", 1, err, sizeof(err));
    if (!lib) {
        fprintf(stderr, "FAIL 2o compiling atmosphere shaders: %s\n", err);
        exit(1);
    }
    int64_t vs = cm_compile_function(lib, "shade_fs_vs", 0, 0, 0, err, sizeof(err));
    assert(vs);

    // (alpha.25) the Photon-style clouds: a quarter-rate trace (48x32) resolved into the half-resolution image (96x64)
    enum { TRACE, CLOUDS, DOME, VOLUME, WEATHER, FINAL, AO, PASSES };
    const char *entries[PASSES] = {
        "shade_cloud_trace", "shade_cloud_resolve", "shade_cloud_dome", "shade_vl_march", "shade_wx_noise_fs", "shade_final",
        "shade_ambient_occlusion"
    };
    const int widths[PASSES] = {48, 96, 160, 96, 1024, 96, 48};
    const int heights[PASSES] = {32, 64, 64, 64, 1024, 64, 32};
    const int formats[PASSES] = {CM_FMT_RGBA16_FLOAT, CM_FMT_RGBA16_FLOAT, CM_FMT_RGBA16_FLOAT,
                                 CM_FMT_RGBA16_FLOAT, CM_FMT_RG16_FLOAT, CM_FMT_RGBA8_UNORM, CM_FMT_RG16_FLOAT};
    int64_t pso[PASSES], tex[PASSES];
    for (int i = 0; i < PASSES; i++) {
        int64_t fs = cm_compile_function(lib, entries[i], 0, 0, 0, err, sizeof(err));
        assert(fs);
        CMColorAttachmentDesc color = { formats[i], 0, 1, 0, 0, 1, 0, 0, 15 };
        pso[i] = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &color, 1, -1, CM_TOPO_TRIANGLES,
                                           0, 0, 0, 0, 0, 0, 0, entries[i], err, sizeof(err));
        if (!pso[i]) {
            fprintf(stderr, "FAIL 2o creating %s: %s\n", entries[i], err);
            exit(1);
        }
        cm_function_destroy(fs);
        tex[i] = cm_texture_create(ctx, formats[i], widths[i], heights[i], 1, 1, 0, 1, 1, 0, entries[i]);
        assert(tex[i]);
    }

    float frame[256] = {0};
    float look[284] = {0};
    float gpu[128] = {0};
    // Inverse Vulkan-style reversed-Z projection, camera at the origin, 90-degree field of view.
    const float inv[16] = {1,0,0,0, 0,1,0,0, 0,0,0,10, 0,0,-1,0};
    frame[21] = 1.0f; // proj[1][1]
    memcpy(frame + 48, inv, sizeof(inv)); // invViewProj
    const float cascade[16] = {0.0075f,0,0,0, 0,0.0075f,0,0, 0,0,0,0, 0,0,0.25f,1};
    memcpy(frame + 80, cascade, sizeof(cascade)); // near shadow covers all tested samples
    int32_t hasShadow = 1;
    memcpy(frame + 242, &hasShadow, sizeof(hasShadow));
    frame[133] = 0.7071068f; frame[134] = -0.7071068f;
    for (int c = 0; c < 3; c++) {
        frame[136 + c] = 2.0f; // sunColor
        frame[140 + c] = 0.35f; frame[144 + c] = 0.15f; // ambient
    }
    look[112] = 0.002f; look[113] = 128.0f; // fogM
    look[132] = 12.0f; look[133] = 1.0f; look[135] = 1.0f; // clouds0: base, coverage scale, on
    look[128] = 0.40f; look[129] = 0.55f; look[130] = 0.30f; look[131] = 0.50f; // weatherA: cumulus, altocumulus coverage
    look[188] = 0.40f; look[189] = 0.50f; // weatherB: cirrus, cirrocumulus (no congestus, no stratus)
    look[136] = 1.0f; look[137] = 14.0f; look[138] = 1.0f; // reflection dome, steps, density
    look[92] = look[93] = look[94] = 1.0f; // grade3
    look[96] = 1.4f; look[97] = 0.92f; look[98] = 0.8f; look[99] = 0.05f; // tonemap
    look[100] = 1.0f; // output ceiling
    for (int i = 0; i < 3; i++) {
        look[204 + 5 * i] = 1.0f;
        look[216 + 5 * i] = 1.0f;
    }
    gpu[44] = 1.0f; // exposure
    int64_t frameBuf = cm_buffer_create(ctx, sizeof(frame), frame, "2o frame");
    int64_t lookBuf = cm_buffer_create(ctx, sizeof(look), look, "2o look");
    int64_t gpuBuf = cm_buffer_create(ctx, sizeof(gpu), gpu, "2o gpu");
    int64_t resBuf = cm_buffer_create(ctx, 256, NULL, "2o resources");
    int64_t depth = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 96, 64, 1, 1, 0, 1, 1, 0, "2o depth");
    int64_t shadow = cm_texture_create(ctx, CM_FMT_D32_FLOAT, 1, 1, 2, 1, 0, 1, 1, 0, "2o shadow");
    int64_t lut = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 16, 8, 1, 1, 0, 1, 1, 0, "2o sky");
    int64_t scene = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 96, 64, 1, 1, 0, 1, 1, 0, "2o scene");
    int64_t cmp = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 1, CM_CMP_GREATER_EQUAL);
    int64_t linear = cm_sampler_create(ctx, 1, 1, 1, 1, 0, 1, 0, 0);
    int64_t cloudRead = cm_buffer_create(ctx, 96 * 64 * 8, NULL, "2o cloud read");
    int64_t vlRead = cm_buffer_create(ctx, 256, NULL, "2o vl read");
    int64_t wxRead = cm_buffer_create(ctx, 256, NULL, "2o weather read");
    int64_t finalRead = cm_buffer_create(ctx, 256, NULL, "2o final read");

    cm_cmd_begin(ctx);
    cm_shade_set_globals(ctx, frameBuf, 0, lookBuf, 0, gpuBuf, 0, resBuf, 0, shadow, lut, cmp, linear);
    cm_shade_set_enabled(ctx, 1);
    cm_blit_clear_depth(ctx, depth, 0.0);
    cm_blit_clear_depth(ctx, shadow, 0.0);
    cm_blit_clear_color(ctx, lut, 0.3f, 0.4f, 0.5f, 1.0f);
    cm_blit_clear_color(ctx, scene, 0.1f, 0.1f, 0.1f, 1.0f);
    // the cloud noises (ShadeCloudNoise's layouts): a 64^2 2D noise whose shape channel (alpha) is an 8-texel checkerboard
    // (~580 m cells at its 0.000027 / m scale, so part of the sky clouds over), blank Worley and curl atlases
    static uint8_t n2dPx[64 * 64 * 4];
    for (int y = 0; y < 64; y++)
        for (int x = 0; x < 64; x++) {
            uint8_t *t = n2dPx + (y * 64 + x) * 4;
            t[0] = 128; t[1] = 128; t[2] = 128; t[3] = (((x >> 3) + (y >> 3)) & 1) ? 255 : 0;
        }
    int64_t n2d = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 64, 64, 1, 1, 0, 0, 1, 0, "2o cloud noise");
    int64_t worley = cm_texture_create(ctx, CM_FMT_R8_UNORM, 528, 528, 1, 1, 0, 1, 1, 0, "2o worley");
    int64_t curl = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, 272, 136, 1, 1, 0, 1, 1, 0, "2o curl");
    cm_blit_write_texture(ctx, n2d, n2dPx, sizeof(n2dPx), 64 * 4, 0, 0, 0, 0, 64, 64);
    cm_blit_clear_color(ctx, worley, 0.0f, 0.0f, 0.0f, 0.0f);
    cm_blit_clear_color(ctx, curl, 0.0f, 0.0f, 0.0f, 0.0f);
    int64_t cloudHistory = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 96, 64, 1, 1, 0, 1, 1, 0, "2o cloud history");
    cm_blit_clear_color(ctx, cloudHistory, 0.0f, 0.0f, 0.0f, 1.0f);
    uint32_t cloudPush[4] = {0, 0, 0, 0}; // frame 0, no history
    int64_t traceInputs[4] = { n2d, worley, curl, cloudHistory };
    cm_shade_fullscreen_pass(ctx, pso[TRACE], tex[TRACE], traceInputs, 4, NULL, 0, cloudPush, sizeof(cloudPush));
    int64_t resolveInputs[2] = { tex[TRACE], cloudHistory };
    cm_shade_fullscreen_pass(ctx, pso[CLOUDS], tex[CLOUDS], resolveInputs, 2, NULL, 0, cloudPush, sizeof(cloudPush));
    cm_shade_fullscreen_pass(ctx, pso[DOME], tex[DOME], traceInputs, 3, NULL, 0, NULL, 0);
    cm_shade_fullscreen_pass(ctx, pso[VOLUME], tex[VOLUME], &depth, 1, NULL, 0, NULL, 0);
    cm_shade_fullscreen_pass(ctx, pso[WEATHER], tex[WEATHER], NULL, 0, NULL, 0, NULL, 0);
    int64_t finalInputs[6] = { scene, scene, depth, scene, tex[VOLUME], tex[AO] };
    float finalParams[24] = {0};
    finalParams[8] = 1.0f;
    cm_shade_fullscreen_pass(ctx, pso[FINAL], tex[FINAL], finalInputs, 6, NULL, 0, finalParams, sizeof(finalParams));
    cm_blit_copy_texture_to_buffer(ctx, tex[CLOUDS], 0, 0, 0, 0, 96, 64, cloudRead, 0, 96 * 8);
    cm_blit_copy_texture_to_buffer(ctx, tex[VOLUME], 0, 0, 48, 52, 1, 1, vlRead, 0, 8);
    cm_blit_copy_texture_to_buffer(ctx, tex[FINAL], 0, 0, 48, 52, 1, 1, finalRead, 0, 4);
    cm_blit_copy_texture_to_buffer(ctx, tex[WEATHER], 0, 0, 4, 4, 16, 1, wxRead, 0, 16 * 4);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    const __fp16 *cloudPixels = (const __fp16 *)(void *)cm_buffer_contents(cloudRead);
    size_t covered = 0;
    for (size_t i = 0; i < 96 * 64; i++) {
        float light = cloudPixels[i * 4], transmittance = cloudPixels[i * 4 + 3];
        assert(isfinite(light) && transmittance >= 0.0f && transmittance <= 1.0f);
        if (transmittance < 0.95f && light > 0.01f) covered++;
    }
    const __fp16 *vlPixel = (const __fp16 *)(void *)cm_buffer_contents(vlRead);
    const __fp16 *wxPixels = (const __fp16 *)(void *)cm_buffer_contents(wxRead);
    assert(covered > 96 && covered < 96 * 48);
    assert(vlPixel[0] > 0.01f && vlPixel[3] == 128.0f);
    assert(wxPixels[0] > 0.0f && wxPixels[1] > 0.0f && wxPixels[0] != wxPixels[30]);

    const uint8_t *finalPixel = (const uint8_t *)(void *)cm_buffer_contents(finalRead);
    uint8_t litFinal = finalPixel[0];
    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, shadow, 1.0);
    cm_shade_fullscreen_pass(ctx, pso[VOLUME], tex[VOLUME], &depth, 1, NULL, 0, NULL, 0);
    cm_shade_fullscreen_pass(ctx, pso[FINAL], tex[FINAL], finalInputs, 6, NULL, 0, finalParams, sizeof(finalParams));
    cm_blit_copy_texture_to_buffer(ctx, tex[VOLUME], 0, 0, 48, 52, 1, 1, vlRead, 0, 8);
    cm_blit_copy_texture_to_buffer(ctx, tex[FINAL], 0, 0, 48, 52, 1, 1, finalRead, 0, 4);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    if (vlPixel[0] >= 0.001f || vlPixel[3] != 128.0f || finalPixel[0] >= litFinal) {
        fprintf(stderr, "FAIL 2o VL occlusion: scatter=%g distance=%g composite red=%u (lit %u)\n",
                (double)vlPixel[0], (double)vlPixel[3], finalPixel[0], litFinal);
        exit(1);
    }
    assert(cm_device_drain_errors(ctx, err, sizeof(err)) == 0);
    printf("[Backend %s] Test 2o P3b atmosphere (clouds, volumetric scatter, weather bake, final composite) OK\n",
           cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3");

    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, depth, 0.02);
    cm_shade_fullscreen_pass(ctx, pso[AO], tex[AO], &depth, 1, NULL, 0, NULL, 0);
    finalParams[9] = 1.0f;
    cm_shade_fullscreen_pass(ctx, pso[FINAL], tex[FINAL], finalInputs, 6, NULL, 0, finalParams, sizeof(finalParams));
    cm_blit_copy_texture_to_buffer(ctx, tex[AO], 0, 0, 24, 16, 1, 1, wxRead, 0, 4);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    assert(wxPixels[0] > 0.99f && fabsf(wxPixels[1] - 5.0f) < 0.05f);
    int64_t fixtureFs = cm_compile_function(lib, "ao_depth_fixture", 0, 0, 0, err, sizeof(err));
    CMColorAttachmentDesc fixtureColor = {CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15};
    int64_t fixturePso = cm_render_pipeline_create(ctx, vs, fixtureFs, NULL, 0, NULL, 0,
        &fixtureColor, 1, CM_FMT_D32_FLOAT, CM_TOPO_TRIANGLES, 0, 0, 1, CM_CMP_ALWAYS, 1, 0, 0, "AO step", err, sizeof(err));
    assert(fixturePso);
    int64_t sceneView = cm_texture_view_create(ctx, scene, 0, 1);
    int64_t depthView = cm_texture_view_create(ctx, depth, 0, 1);
    assert(sceneView && depthView);
    int32_t noClear = 0;
    float clear[4] = {0};
    cm_cmd_begin(ctx);
    assert(cm_pass_begin(ctx, &sceneView, &noClear, clear, 1, depthView, 0, 0.0, 0, 0, 96, 64, "AO step") == 1);
    cm_pass_set_pipeline(ctx, fixturePso);
    cm_pass_draw(ctx, CM_TOPO_TRIANGLES, 3, 1, 0, 0);
    cm_pass_finish(ctx);
    cm_shade_fullscreen_pass(ctx, pso[AO], tex[AO], &depth, 1, NULL, 0, NULL, 0);
    cm_blit_copy_texture_to_buffer(ctx, tex[AO], 0, 0, 25, 16, 1, 1, wxRead, 0, 4);
    cm_blit_copy_texture_to_buffer(ctx, tex[AO], 0, 0, 40, 16, 1, 1, wxRead, 8, 4);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    assert(wxPixels[0] < 0.99f && wxPixels[4] > 0.99f);
    cm_texture_view_destroy(ctx, sceneView); cm_texture_view_destroy(ctx, depthView);
    cm_pipeline_destroy(ctx, fixturePso); cm_function_destroy(fixtureFs);
    printf("[Backend %s] P4 SSAO flat surface, depth step contact and final binding OK\n",
           cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3");
    finalParams[9] = 0.0f;

    // Snell angles and Fresnel at normal incidence, inside the rim and beyond the critical angle.
    int64_t snellFs = cm_compile_function(lib, "snell_fixture", 0, 0, 0, err, sizeof(err));
    int64_t snellPso = cm_render_pipeline_create(ctx, vs, snellFs, NULL, 0, NULL, 0, &fixtureColor, 1, -1,
        CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, "Snell window probe", err, sizeof(err));
    assert(snellFs && snellPso);
    cm_cmd_begin(ctx);
    cm_shade_fullscreen_pass(ctx, snellPso, tex[VOLUME], NULL, 0, NULL, 0, NULL, 0);
    cm_blit_copy_texture_to_buffer(ctx, tex[VOLUME], 0, 0, 0, 0, 1, 1, vlRead, 0, 8);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    assert(fabsf(vlPixel[0] - 0.0204f) < 0.001f && fabsf(vlPixel[1] - 0.6665f) < 0.001f
        && vlPixel[2] > 0.35f && vlPixel[2] < 1.0f && vlPixel[3] == 1.0f);
    cm_pipeline_destroy(ctx, snellPso);
    cm_function_destroy(snellFs);

    // Use the production volume pass with a three-block column. The upper rays end at the
    // water surface, the downward rays march to the distance cap, and opaque depth shortens both.
    float *waterLook = (float *)(void *)cm_buffer_contents(lookBuf);
    waterLook[120] = 12.0f; waterLook[121] = 1.0f; waterLook[122] = 3.0f;
    waterLook[159] = 1.0f; // smoothed eye skylight
    for (int test = 0; test < 3; test++) {
        cm_cmd_begin(ctx);
        cm_blit_clear_depth(ctx, depth, test == 2 ? 0.1 : 0.0);
        cm_blit_clear_depth(ctx, shadow, test == 1 ? 1.0 : 0.0);
        int64_t vlInputs[2] = { depth, n2d }; // (the 2D noise bands the underwater light)
        cm_shade_fullscreen_pass(ctx, pso[VOLUME], tex[VOLUME], vlInputs, 2, NULL, 0, NULL, 0);
        cm_blit_copy_texture_to_buffer(ctx, tex[VOLUME], 0, 0, 0, 0, 96, 64, cloudRead, 0, 96 * 8);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        float peak = 0.0f;
        for (size_t i = 0; i < 96 * 64; i++) {
            assert(isfinite(cloudPixels[4 * i + 2]) && cloudPixels[4 * i + 3] > 0.0f);
            assert(cloudPixels[4 * i + 3] <= (test == 2 ? 1.75f : 32.0f));
            peak = MAX(peak, cloudPixels[4 * i + 2]);
        }
        if (test == 0) {
            float upward = cloudPixels[(52 * 96 + 48) * 4 + 3];
            assert(upward > 3.0f && upward < 8.0f && cloudPixels[(10 * 96 + 48) * 4 + 3] == 32.0f);
            assert(peak > 0.001f);
        } else if (test == 1) {
            assert(peak == 0.0f);
        }
    }
    waterLook[120] = waterLook[121] = waterLook[122] = waterLook[159] = 0.0f;
    assert(cm_device_drain_errors(ctx, err, sizeof(err)) == 0);
    printf("[Backend %s] Underwater shafts, depth and shadow occlusion, and Snell angles OK\n",
           cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3");

    // Time the recurring atmosphere passes at the owner test resolution.
    const int W = 3024, H = 1752, SW = W / 4, SH = H / 4;
    // clouds: traced at a quarter of the half-resolution pixels (SW x SH), resolved at half resolution (ping-pong history)
    int64_t benchCloud = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, SW, SH, 1, 1, 0, 1, 1, 0, "P3b bench cloud");
    int64_t benchHist[2] = {
        cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W / 2, H / 2, 1, 1, 0, 1, 1, 0, "P3b bench cloud history 0"),
        cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W / 2, H / 2, 1, 1, 0, 1, 1, 0, "P3b bench cloud history 1")
    };
    int64_t benchVL = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, SW, SH, 1, 1, 0, 1, 1, 0, "P3b bench VL");
    int64_t benchScene = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "P3b bench scene");
    int64_t benchDepth = cm_texture_create(ctx, CM_FMT_D32_FLOAT, W, H, 1, 1, 0, 1, 1, 0, "P3b bench depth");
    int64_t benchOut = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, W, H, 1, 1, 0, 1, 1, 0, "P3b bench output");
    assert(benchCloud && benchVL && benchScene && benchDepth && benchOut);
    cm_cmd_begin(ctx);
    cm_blit_clear_depth(ctx, shadow, 0.0);
    cm_blit_clear_color_depth(ctx, benchScene, 0.1f, 0.1f, 0.1f, 1.0f, benchDepth, 0.0);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    int64_t benchInputs[6] = { benchScene, benchScene, benchDepth, benchScene, benchVL, tex[AO] };
    float *lookMapped = (float *)(void *)cm_buffer_contents(lookBuf);
    double sums[3] = {0};
    const int warm = 6, samples = 16;
    for (int iteration = 0; iteration < warm + samples; iteration++) {
        // Interleave modes so each one sees the same GPU warmup and clock changes.
        for (int offset = 0; offset < 3; offset++) {
            int mode = (iteration + offset) % 3;
            lookMapped[137] = mode == 2 ? 14.0f : 8.0f;
            finalParams[8] = mode != 0 ? 1.0f : 0.0f;
            cm_cmd_begin(ctx);
            if (mode != 0) {
                uint32_t push[4] = { (uint32_t)iteration, iteration > 0 ? 1u : 0u, 0, 0 };
                int64_t hPrev = benchHist[iteration & 1], hNext = benchHist[(iteration & 1) ^ 1];
                int64_t ti[4] = { n2d, worley, curl, hPrev }, ri[2] = { benchCloud, hPrev };
                cm_shade_fullscreen_pass(ctx, pso[TRACE], benchCloud, ti, 4, NULL, 0, push, sizeof(push));
                cm_shade_fullscreen_pass(ctx, pso[CLOUDS], hNext, ri, 2, NULL, 0, push, sizeof(push));
                if ((iteration & 3) == 0) cm_shade_fullscreen_pass(ctx, pso[DOME], tex[DOME], ti, 3, NULL, 0, NULL, 0);
                cm_shade_fullscreen_pass(ctx, pso[VOLUME], benchVL, &benchDepth, 1, NULL, 0, NULL, 0);
            }
            cm_shade_fullscreen_pass(ctx, pso[FINAL], benchOut, benchInputs, 6, NULL, 0, finalParams, sizeof(finalParams));
            assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
            if (iteration >= warm) sums[mode] += (double)cm_device_last_gpu_ns(ctx) / 1e6;
        }
    }
    printf("[Benchmark M1 Pro %s @ %dx%d] P3b atmosphere + final synthetic avg: off %.3f / Fast %.3f / Fancy %.3f ms GPU\n",
           cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3", W, H,
           sums[0] / samples, sums[1] / samples, sums[2] / samples);
    assert(cm_device_drain_errors(ctx, err, sizeof(err)) == 0);
    cm_texture_destroy(ctx, benchOut); cm_texture_destroy(ctx, benchDepth); cm_texture_destroy(ctx, benchScene);
    cm_texture_destroy(ctx, benchVL); cm_texture_destroy(ctx, benchCloud);
    cm_texture_destroy(ctx, benchHist[0]); cm_texture_destroy(ctx, benchHist[1]);
    cm_texture_destroy(ctx, n2d); cm_texture_destroy(ctx, worley); cm_texture_destroy(ctx, curl); cm_texture_destroy(ctx, cloudHistory);

    cm_buffer_destroy(ctx, finalRead); cm_buffer_destroy(ctx, wxRead); cm_buffer_destroy(ctx, vlRead); cm_buffer_destroy(ctx, cloudRead);
    cm_sampler_destroy(ctx, linear); cm_sampler_destroy(ctx, cmp);
    cm_texture_destroy(ctx, scene); cm_texture_destroy(ctx, lut); cm_texture_destroy(ctx, shadow); cm_texture_destroy(ctx, depth);
    cm_buffer_destroy(ctx, resBuf); cm_buffer_destroy(ctx, gpuBuf); cm_buffer_destroy(ctx, lookBuf); cm_buffer_destroy(ctx, frameBuf);
    for (int i = 0; i < PASSES; i++) {
        cm_texture_destroy(ctx, tex[i]);
        cm_pipeline_destroy(ctx, pso[i]);
    }
    cm_function_destroy(vs);
    cm_library_destroy(lib);
    cm_device_destroy(ctx);
}

static void verify_p4_taau(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx);
    NSString *file = [assetsDir stringByAppendingPathComponent:@"shaders/ported/taa.metal"];
    NSString *source = [read_file_str(file) stringByAppendingString:
        @"\nfragment half4 taa_edge(TaaIn in [[stage_in]]) {"
         "return half4(half3(in.uv.x < 0.5 ? 0.0h : 1.0h), 1.0h); }"];
    char error[4096] = {0};
    int64_t lib = cm_compile_msl_library(ctx, source.UTF8String, "TAAU Test", 0, error, sizeof(error));
    if (!lib) {
        fprintf(stderr, "FAIL 2p TAAU compile: %s\n", error);
        exit(1);
    }
    int64_t vs = cm_compile_function(lib, "taa_vs", 0, 0, 0, error, sizeof(error));
    assert(vs);
    enum { EDGE, RESOLVE, OUTPUT };
    const char *entry[] = {"taa_edge", "taa_resolve", "taa_output"};
    int64_t pso[3];
    for (int i = 0; i < 3; i++) {
        int64_t fs = cm_compile_function(lib, entry[i], 0, 0, 0, error, sizeof(error));
        CMColorAttachmentDesc color = {i == OUTPUT ? CM_FMT_RGBA8_UNORM : CM_FMT_RGBA16_FLOAT,
                                       0, 1, 0, 0, 1, 0, 0, 15};
        pso[i] = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &color, 1, -1,
                                           CM_TOPO_TRIANGLES, 0, 0, 0, 0, 0, 0, 0, entry[i], error, sizeof(error));
        if (!pso[i]) {
            fprintf(stderr, "FAIL 2p TAAU pipeline %s: %s\n", entry[i], error);
            exit(1);
        }
        cm_function_destroy(fs);
    }

    const int inW = 32, inH = 24, outW = 64, outH = 48;
    int64_t scene = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, inW, inH, 1, 1, 0, 1, 1, 0, "2p scene");
    int64_t depth = cm_texture_create(ctx, CM_FMT_D32_FLOAT, inW, inH, 1, 1, 0, 1, 1, 0, "2p depth");
    int64_t hand = cm_texture_create(ctx, CM_FMT_D32_FLOAT, inW, inH, 1, 1, 0, 1, 1, 0, "2p hand");
    int64_t history = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, outW, outH, 1, 1, 0, 1, 1, 0, "2p history");
    int64_t resolved = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, outW, outH, 1, 1, 0, 1, 1, 0, "2p resolved");
    int64_t output = cm_texture_create(ctx, CM_FMT_RGBA8_UNORM, outW, outH, 1, 1, 0, 1, 1, 0, "2p output");
    int64_t read = cm_buffer_create(ctx, 256, NULL, "2p read");
    assert(scene && depth && hand && history && resolved && output && read);
    int64_t textures[4] = {scene, depth, history, hand};

    const float inv[16] = {1,0,0,0, 0,1,0,0, 0,0,0,10, 0,0,-1,0};
    const float proj[16] = {1,0,0,0, 0,1,0,0, 0,0,0,-1, 0,0,0.1f,0};
    float params[52] = {0};
    memcpy(params, inv, sizeof(inv));
    memcpy(params + 16, proj, sizeof(proj));
    memcpy(params + 32, proj, sizeof(proj));
    float current = 0.0;
    for (int test = 0; test < 4; test++) {
        cm_cmd_begin(ctx);
        cm_blit_clear_depth(ctx, depth, 0.1);
        cm_blit_clear_depth(ctx, hand, test == 3 ? 1.0 : 0.0);
        cm_blit_clear_color(ctx, history, 0.25f, 0.25f, 0.25f, test == 2 ? 4.0f : 1.0f);
        cm_shade_fullscreen_pass(ctx, pso[EDGE], scene, NULL, 0, NULL, 0, NULL, 0);
        params[48] = test == 3 ? 0.0125f : 0.0f;
        params[50] = test != 0;
        cm_shade_fullscreen_pass(ctx, pso[RESOLVE], resolved, textures, 4, NULL, 0, params, sizeof(params));
        cm_shade_fullscreen_pass(ctx, pso[OUTPUT], output, &resolved, 1, NULL, 0, NULL, 0);
        cm_blit_copy_texture_to_buffer(ctx, resolved, 0, 0, outW / 2, outH / 2, 1, 1, read, 0, 8);
        cm_blit_copy_texture_to_buffer(ctx, output, 0, 0, outW / 2, outH / 2, 1, 1, read, 16, 4);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);

        const __fp16 *pixel = (const __fp16 *)(void *)cm_buffer_contents(read);
        const uint8_t *display = (const uint8_t *)pixel + 16;
        float rgb = pixel[0];
        assert(display[3] == 255);
        assert(fabsf(pixel[3] - (test == 3 ? -1.0f : 1.0f)) < 0.005f);
        switch (test) {
            case 0: current = rgb; assert(current > 0.65f && current < 0.85f); break;
            case 1: assert(rgb > 0.25f && rgb < current - 0.2f); break;
            case 2:
            case 3: assert(fabsf(rgb - current) < 0.006f); break;
        }
    }
    assert(cm_device_drain_errors(ctx, error, sizeof(error)) == 0);
    printf("[Backend %s] Test 2p P4 TAAU history blend, depth rejection, hand rejection and full-resolution resolve OK\n",
           cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3");

    cm_buffer_destroy(ctx, read);
    for (int i = 0; i < 4; i++) cm_texture_destroy(ctx, textures[i]);
    cm_texture_destroy(ctx, resolved); cm_texture_destroy(ctx, output);
    for (int i = 0; i < 3; i++) cm_pipeline_destroy(ctx, pso[i]);
    cm_function_destroy(vs);
    cm_library_destroy(lib);
    cm_device_destroy(ctx);
}

// P6a dynamic lights: the module's kernels (visibility rays / flood fill, irradiance volume) and the shading read through
// the render-encoder bindings (buffer 29, textures 24/25), with the zeroed fallback bound before the module exists.
// One light at (16.5, 16.5, 16.5) with a solid wall at x = 20: the voxel in front stays lit, the one behind goes dark.
static void verify_p6a_dynlights(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *ported = [assetsDir stringByAppendingPathComponent:@"shaders/ported"];
    NSString *dl = read_file_str([ported stringByAppendingPathComponent:@"dynlight.metal"]);
    NSString *vis = read_file_str([ported stringByAppendingPathComponent:@"dynlight_vis.metal"]);
    NSString *kernels = [NSString stringWithFormat:@"#define SHADE_DL_KERNELS\n%@\n%@", dl, vis];
    NSString *probeSrc = [NSString stringWithFormat:@"%@\n"
        "struct DlProbeOut { float4 position [[position]]; float2 uv; };\n"
        "vertex DlProbeOut dl_probe_vs(uint vid [[vertex_id]]) {\n"
        "  float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);\n"
        "  DlProbeOut o; o.position = float4(p, 0.0, 1.0); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o; }\n"
        "fragment half4 dl_probe_fs(DlProbeOut in [[stage_in]], constant ShadeDynLights &D [[buffer(29)]],\n"
        "    texture3d<half> irr [[texture(24)]], texture3d<half> dirs [[texture(25)]]) {\n"
        "  bool front = in.uv.x < 0.5;\n"
        "  float3 p = front ? float3(12.5, 16.5, 16.5) : float3(22.5, 16.5, 16.5);\n"
        "  float3 n = front ? float3(1.0, 0.0, 0.0) : float3(-1.0, 0.0, 0.0);\n"
        "  return half4(half3(shadeDynamicLightsVol(D, irr, dirs, p, n, false, 0.0h)), 1.0h); }\n", dl];
    char err[4096] = {0};
    int64_t lib = cm_compile_msl_library(ctx, probeSrc.UTF8String, "P6a probe", 1, err, sizeof(err));
    if (!lib) { fprintf(stderr, "FAIL 2q compiling dynamic-light probe: %s\n", err); exit(1); }
    int64_t vs = cm_compile_function(lib, "dl_probe_vs", 0, 0, 0, err, sizeof(err));
    int64_t fs = cm_compile_function(lib, "dl_probe_fs", 0, 0, 0, err, sizeof(err));
    assert(vs && fs);
    CMColorAttachmentDesc color = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pso = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &color, 1, -1, CM_TOPO_TRIANGLES,
                                            0, 0, 0, 0, 0, 0, 0, "dl probe", err, sizeof(err));
    if (!pso) { fprintf(stderr, "FAIL 2q dynamic-light probe PSO: %s\n", err); exit(1); }
    int64_t target = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 2, 1, 1, 1, 0, 1, 1, 0, "dl probe target");
    int64_t read = cm_buffer_create(ctx, 256, NULL, "dl probe read");
    assert(target && read);
    const __fp16 *px = (const __fp16 *)(void *)cm_buffer_contents(read);

    enum { DL_BYTES = 28736, OCC_BYTES = 512 * 128 * 4 };
    #define DL_PROBE() do { \
        cm_cmd_begin(ctx); \
        cm_shade_fullscreen_pass(ctx, pso, target, NULL, 0, NULL, 0, NULL, 0); \
        cm_blit_copy_texture_to_buffer(ctx, target, 0, 0, 0, 0, 2, 1, read, 0, 16); \
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1); \
    } while (0)

    // 1. Module off: the zeroed fallback is bound, so the probe reads no light (and no stale argument-table entries).
    assert(cm_dl_fallback(ctx, DL_BYTES) == 1);
    DL_PROBE();
    assert(px[0] == 0.0f && px[4] == 0.0f);

    int64_t state = cm_dl_new(ctx, kernels.UTF8String, (int32_t)strlen(kernels.UTF8String) + 1, 3, 4, OCC_BYTES,
                              96, 64, 96, err, sizeof(err));
    if (!state) { fprintf(stderr, "FAIL 2q cm_dl_new: %s\n", err); exit(1); }
    cm_dl_slot(state, 0);

    // Occupancy: a solid plane at absolute x = 20 (all y, z of the 128^3 window).
    uint32_t *occ = calloc(1, OCC_BYTES);
    for (int y = 0; y < 128; y++) for (int z = 0; z < 128; z++) {
        int x = 20;
        uint32_t slot = ((uint32_t)((y >> 4) & 7) << 6) | ((uint32_t)((z >> 4) & 7) << 3) | (uint32_t)((x >> 4) & 7);
        uint32_t idx = ((uint32_t)(y & 15) << 8) | ((uint32_t)(z & 15) << 4) | (uint32_t)(x & 15);
        occ[(slot << 7) | (idx >> 5)] |= 1u << (idx & 31u);
    }
    cm_dl_occupancy(state, occ);
    free(occ);

    // ShadeDynLights (camera at the origin, so camera-relative = absolute): one light, every grid cell lists it.
    uint8_t *D = (uint8_t *)(uintptr_t)cm_dl_contents(state, 0);
    assert(D);
    memset(D, 0, DL_BYTES);
    uint32_t *info = (uint32_t *)D;
    float *f = (float *)D;
    info[0] = 1; info[1] = 1;
    f[4] = -64; f[5] = -48; f[6] = -64; f[7] = 1.0f / 8.0f;        // grid
    f[8] = 4; f[9] = 1; f[10] = 1; f[11] = 1;                       // slabs, strength, spec, entity
    f[12] = -48; f[13] = -32; f[14] = -48; f[15] = 1;               // irradiance volume min corner, computed
    float *L = f + 16;
    L[0] = 16.5f; L[1] = 16.5f; L[2] = 16.5f; L[3] = 15.0f;         // pos, reach
    L[4] = 1; L[5] = 0.8f; L[6] = 0.6f; L[7] = 1;                   // colour
    L[8] = 0; L[9] = 0; L[10] = 0; L[11] = -1;                      // volume corner, no slab yet
    L[12] = 0.75f;                                                  // core radius, directional, rays
    uint32_t *cells = (uint32_t *)(D + 4160);
    for (int i = 0; i < 16 * 12 * 16; i++) cells[i * 2] = 1u;

    float volParams[4 + 8] = {0};
    int32_t *vp = (int32_t *)volParams;
    vp[0] = 1; vp[1] = 0;                                           // one volume, rays
    vp[4] = 0; vp[5] = 0; vp[6] = 0; vp[7] = 0;                     // origin (absolute), slab 0
    volParams[8] = 16.5f; volParams[9] = 16.5f; volParams[10] = 16.5f; volParams[11] = 15.0f;

    // 2. No visibility volume: the light reaches through the wall (both probes lit).
    cm_cmd_begin(ctx);
    cm_dl_irr(ctx, state, 0, 0, 0, 96, 64, 96);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    DL_PROBE();
    float openFront = px[0], openBehind = px[4];
    if (!(openFront > 0.05f && openBehind > 0.02f && px[1] < openFront)) {
        fprintf(stderr, "FAIL 2q unoccluded light: front=%g behind=%g\n", (double)openFront, (double)openBehind);
        exit(1);
    }

    // 3. Ray visibility: the wall blocks the light behind it, the front keeps it.
    L[11] = 0;
    cm_cmd_begin(ctx);
    cm_dl_vis(ctx, state, volParams, sizeof(volParams), 1);
    cm_dl_irr(ctx, state, 0, 0, 0, 96, 64, 96);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    DL_PROBE();
    if (!(px[0] > 0.5f * openFront && px[4] < 0.25f * openBehind)) {
        fprintf(stderr, "FAIL 2q ray visibility: front=%g (open %g) behind=%g (open %g)\n",
                (double)px[0], (double)openFront, (double)px[4], (double)openBehind);
        exit(1);
    }

    // 4. Flood fill (where the device runs it): no detour around an endless wall, so behind stays dimmer than open.
    int flood = cm_dl_has_flood(state);
    if (flood) {
        vp[1] = 1;
        L[14] = 1;
        cm_cmd_begin(ctx);
        cm_dl_vis(ctx, state, volParams, sizeof(volParams), 1);
        cm_dl_irr(ctx, state, 0, 0, 0, 96, 64, 96);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        DL_PROBE();
        if (!(px[0] > 0.5f * openFront && px[4] < 0.5f * openBehind)) {
            fprintf(stderr, "FAIL 2q flood visibility: front=%g behind=%g (open %g / %g)\n",
                    (double)px[0], (double)px[4], (double)openFront, (double)openBehind);
            exit(1);
        }
    }
    float occFront = px[0], occBehind = px[4];

    // Timing: 4 ray volumes + the full irradiance box (upstream budget ~0.2 ms GPU).
    float benchParams[4 + 8 * 16] = {0};
    int32_t *bp = (int32_t *)benchParams;
    bp[0] = 4;
    for (int i = 0; i < 4; i++) {
        bp[4 + i * 8 + 3] = i;
        benchParams[4 + i * 8 + 4] = 16.5f; benchParams[4 + i * 8 + 5] = 16.5f; benchParams[4 + i * 8 + 6] = 16.5f;
        benchParams[4 + i * 8 + 7] = 15.0f;
    }
    double best = 1e9;
    for (int it = 0; it < 12; it++) {
        double t0 = CFAbsoluteTimeGetCurrent();
        cm_cmd_begin(ctx);
        cm_dl_vis(ctx, state, benchParams, sizeof(benchParams), 4);
        cm_dl_irr(ctx, state, 0, 0, 0, 96, 64, 96);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        if (it >= 2 && ms < best) best = ms;
    }
    assert(cm_device_drain_errors(ctx, err, sizeof(err)) == 0);
    printf("[Backend %s] Test 2q P6a dynamic lights (fallback, irradiance, ray%s visibility: front %.3f behind %.3f, open %.3f / %.3f; "
           "4 volumes + full irradiance %.3f ms) OK\n",
           api, flood ? " + flood" : "", (double)occFront, (double)occBehind, (double)openFront, (double)openBehind, best);
    #undef DL_PROBE

    cm_dl_free(ctx, state);
    cm_buffer_destroy(ctx, read);
    cm_texture_destroy(ctx, target);
    cm_pipeline_destroy(ctx, pso);
    cm_function_destroy(vs); cm_function_destroy(fs);
    cm_library_destroy(lib);
    cm_device_destroy(ctx);
}

// P6b coloured block light: the flood kernels (clear + spread per colour channel, blocked by opaque cells) and the shading's
// read through the render-encoder bindings (buffer 30, textures 26 / 27), with the zeroed fallback bound before the module.
// A soul-fire light (class 1, level 15) at (8, 8, 8) in a 2 x 2 x 2-section window with an opaque wall at x = 12: blue in
// front, nothing behind.
static void verify_p6b_colorlights(NSString *assetsDir, int32_t preferMetal4) {
    int64_t ctx = cm_device_create(preferMetal4, 0, "");
    assert(ctx);
    const char *api = cm_device_is_metal4(ctx) ? "Metal 4" : "Metal 3";
    NSString *cl = read_file_str([[assetsDir stringByAppendingPathComponent:@"shaders/ported"] stringByAppendingPathComponent:@"colorlight.metal"]);
    NSString *kernels = [NSString stringWithFormat:@"#define SHADE_CL_KERNELS\n%@", cl];
    NSString *probeSrc = [NSString stringWithFormat:@"%@\n"
        "struct ClProbeOut { float4 position [[position]]; float2 uv; };\n"
        "vertex ClProbeOut cl_probe_vs(uint vid [[vertex_id]]) {\n"
        "  float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);\n"
        "  ClProbeOut o; o.position = float4(p, 0.0, 1.0); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return o; }\n"
        "fragment half4 cl_probe_fs(ClProbeOut in [[stage_in]], constant ShadeColorLights &H [[buffer(30)]],\n"
        "    texture3d<float> fine [[texture(26)]], texture3d<float> coarse [[texture(27)]]) {\n"
        "  int3 qi = in.uv.x < 0.5 ? int3(5, 8, 8) : int3(14, 8, 8);\n"
        "  return half4(half3(shadeColorLightAt(H, fine, coarse, qi, float3(0.5), 12.0 / 15.0)), 1.0h); }\n"
        "fragment half4 cl_probe_world_fs(ClProbeOut in [[stage_in]], constant ShadeColorLights &H [[buffer(30)]],\n"
        "    texture3d<float> fine [[texture(26)]], texture3d<float> coarse [[texture(27)]]) {\n"
        "  int3 qi = int3(994, 140, 1010);\n"
        "  return half4(in.uv.x < 0.5 ? half3(shadeClSample(H, fine, qi, float3(0.5), false))\n"
        "                             : half3(shadeColorLightAt(H, fine, coarse, qi, float3(0.5), 8.0 / 15.0)), 1.0h); }\n"
        "fragment half4 cl_probe_smooth_fs(ClProbeOut in [[stage_in]], constant ShadeColorLights &H [[buffer(30)]],\n"
        "    texture3d<float> lv [[texture(28)]]) {\n"
        "  float v = in.uv.x < 0.5 ? shadeSmoothBlockAt(H, lv, int3(992 + 7, 128 + 3, 1008 + 9), float3(1.0, 0.5, 0.5), -1.0)\n"
        "                          : shadeSmoothBlockAt(H, lv, int3(992 + 3, 128 + 12, 1008 + 4), float3(0.5, 0.5, 1.0), -1.0);\n"
        "  return half4(half(v), 0.0h, 0.0h, 1.0h); }\n", cl];
    char err[4096] = {0};
    int64_t lib = cm_compile_msl_library(ctx, probeSrc.UTF8String, "P6b probe", 1, err, sizeof(err));
    if (!lib) { fprintf(stderr, "FAIL 2r compiling coloured-light probe: %s\n", err); exit(1); }
    int64_t vs = cm_compile_function(lib, "cl_probe_vs", 0, 0, 0, err, sizeof(err));
    int64_t fs = cm_compile_function(lib, "cl_probe_fs", 0, 0, 0, err, sizeof(err));
    assert(vs && fs);
    CMColorAttachmentDesc color = { CM_FMT_RGBA16_FLOAT, 0, 1, 0, 0, 1, 0, 0, 15 };
    int64_t pso = cm_render_pipeline_create(ctx, vs, fs, NULL, 0, NULL, 0, &color, 1, -1, CM_TOPO_TRIANGLES,
                                            0, 0, 0, 0, 0, 0, 0, "cl probe", err, sizeof(err));
    if (!pso) { fprintf(stderr, "FAIL 2r coloured-light probe PSO: %s\n", err); exit(1); }
    int64_t target = cm_texture_create(ctx, CM_FMT_RGBA16_FLOAT, 2, 1, 1, 1, 0, 1, 1, 0, "cl probe target");
    int64_t read = cm_buffer_create(ctx, 256, NULL, "cl probe read");
    assert(target && read);
    const __fp16 *px = (const __fp16 *)(void *)cm_buffer_contents(read);
    #define CL_PROBE() do { \
        cm_cmd_begin(ctx); \
        cm_shade_fullscreen_pass(ctx, pso, target, NULL, 0, NULL, 0, NULL, 0); \
        cm_blit_copy_texture_to_buffer(ctx, target, 0, 0, 0, 0, 2, 1, read, 0, 16); \
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1); \
    } while (0)

    // 1. Module off: the zeroed fallback header (fineMin.w = 0) means no colour anywhere.
    assert(cm_cl_fallback(ctx) == 1);
    CL_PROBE();
    assert(px[0] == 0.0f && px[2] == 0.0f && px[4] == 0.0f && px[6] == 0.0f);

    enum { FINE_SLOTS = 8, COARSE_SLOTS = 1, CELLS = 4096 };
    int64_t state = cm_cl_new(ctx, kernels.UTF8String, 32, 32, 32, 16, 16, 16, (int64_t)(FINE_SLOTS + COARSE_SLOTS) * CELLS,
                              64, 3, err, sizeof(err));
    if (!state) { fprintf(stderr, "FAIL 2r cm_cl_new: %s\n", err); exit(1); }
    uint8_t *ids = (uint8_t *)(uintptr_t)cm_cl_ids(state);
    assert(ids);
    // Fine slot of world section (sx, sy, sz) in a 2 x 2 x 2 window at the origin: (y * 2 + z) * 2 + x; cells in (y, z, x) order.
    #define CL_ID(x, y, z) ids[((((y) >> 4) * 2 + ((z) >> 4)) * 2 + ((x) >> 4)) * CELLS + ((((y) & 15) * 16 + ((z) & 15)) * 16 + ((x) & 15))]
    CL_ID(8, 8, 8) = 16 + 1 * 16 + 15;                                        // soul fire, level 15
    for (int y = 0; y < 32; y++) for (int z = 0; z < 32; z++) CL_ID(12, y, z) = 15; // opaque wall
    int32_t header[20] = {0};
    header[0] = 0; header[1] = 0; header[2] = 0; header[3] = 1;               // fineMin, on
    header[4] = 2; header[5] = 2; header[6] = 2; header[7] = 1;               // fineDim, fine active
    header[8] = 0; header[9] = 0; header[10] = 0; header[11] = FINE_SLOTS * CELLS; // coarseMin, coarse ids base
    header[12] = 1; header[13] = 1; header[14] = 1; header[15] = 0;           // coarseDim, coarse idle
    float *tune = (float *)&header[16];
    tune[0] = 1.0f; tune[1] = 1.0f; tune[2] = 2.0f; tune[3] = 0.0f;           // strength, glow, edge band
    cm_cl_header(state, 0, header);
    uint32_t *list = (uint32_t *)(uintptr_t)cm_cl_list(state, 0);
    int n = 0;
    for (int i = 0; i < FINE_SLOTS; i++) list[n++] = (uint32_t)i;             // clears (the textures start undefined)
    list[n++] = 0x80000000u;
    for (int i = 0; i < FINE_SLOTS; i++) list[n++] = (uint32_t)i;             // spread

    // 2. Clear + 24 spread steps converge the light (15 levels at one per block).
    double t0 = CFAbsoluteTimeGetCurrent();
    cm_cmd_begin(ctx);
    cm_cl_frame(ctx, state, 0, FINE_SLOTS + COARSE_SLOTS, FINE_SLOTS, 0, 24, 0, 0);
    assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
    double floodMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    CL_PROBE();
    float fr = px[0], fg = px[1], fb = px[2], br = px[4], bg = px[5], bb = px[6];
    if (!(fb > 0.02f && fr < 0.0f && fb > fg)) {
        fprintf(stderr, "FAIL 2r soul light in front of the wall: add = (%g, %g, %g)\n", (double)fr, (double)fg, (double)fb);
        exit(1);
    }
    if (!(fabsf(br) < 1e-4f && fabsf(bg) < 1e-4f && fabsf(bb) < 1e-4f)) {
        fprintf(stderr, "FAIL 2r light through the wall: add = (%g, %g, %g)\n", (double)br, (double)bg, (double)bb);
        exit(1);
    }

    // 3. Strength 0 in the header: the shading adds nothing (the live option off).
    tune[0] = 0.0f;
    cm_cl_header(state, 1, header);
    CL_PROBE();
    assert(px[0] == 0.0f && px[2] == 0.0f);
    // 4. The in-game layout: a 16 x 8 x 16-section window at section (55, 4, 54) with a 12 x 4 x 12 coarse one, a soul lantern
    //    (level 10) at world (994, 140, 1012); only its slot spreads. The probe reads the volume one block in front of it.
    {
        cm_cl_free(ctx, state);
        enum { FX = 16, FY = 8, FZ = 16, CX = 12, CY = 4, CZ = 12, FINE = FX * FY * FZ, COARSE = CX * CY * CZ };
        state = cm_cl_new(ctx, kernels.UTF8String, FX * 16, FY * 16, FZ * 16, CX * 16, CY * 16, CZ * 16,
                          (int64_t)(FINE + COARSE) * CELLS, 3 * (FINE + COARSE) + 64, 6, err, sizeof(err));
        assert(state);
        uint8_t *ids2 = (uint8_t *)(uintptr_t)cm_cl_ids(state);
        int wx = 994, wy = 140, wz = 1012;
        int sx = wx >> 4, sy = wy >> 4, sz = wz >> 4;
        int slotL = (((sy % FY) + FY) % FY * FZ + ((sz % FZ) + FZ) % FZ) * FX + ((sx % FX) + FX) % FX;
        ids2[(size_t)slotL * CELLS + (((wy & 15) * 16 + (wz & 15)) * 16 + (wx & 15))] = 16 + 1 * 16 + 10;
        int32_t h2[20] = {0};
        h2[0] = 55; h2[1] = 4; h2[2] = 54; h2[3] = 1;
        h2[4] = FX; h2[5] = FY; h2[6] = FZ; h2[7] = 1;
        h2[8] = (994 >> 6) - CX / 2; h2[9] = (140 >> 6) - CY / 2; h2[10] = (1012 >> 6) - CZ / 2; h2[11] = FINE * CELLS;
        h2[12] = CX; h2[13] = CY; h2[14] = CZ; h2[15] = 0;
        float *t2 = (float *)&h2[16];
        t2[0] = 1.0f; t2[1] = 1.0f; t2[2] = 16.0f;
        cm_cl_header(state, 0, h2);
        uint32_t *l2 = (uint32_t *)(uintptr_t)cm_cl_list(state, 0);
        int m = 0;
        for (int i = 0; i < FINE; i++) l2[m++] = (uint32_t)i;
        for (int i = 0; i < COARSE; i++) l2[m++] = 0x80000000u | (uint32_t)i;
        l2[m++] = (uint32_t)slotL;
        cm_cmd_begin(ctx);
        cm_cl_frame(ctx, state, 0, FINE + COARSE, 1, 0, 24, 0, 0);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        // probe: re-point the probe shader at (994, 140, 1010) through a second fragment entry
        int64_t fs2 = cm_compile_function(lib, "cl_probe_world_fs", 0, 0, 0, err, sizeof(err));
        assert(fs2);
        int64_t pso2 = cm_render_pipeline_create(ctx, vs, fs2, NULL, 0, NULL, 0, &color, 1, -1, CM_TOPO_TRIANGLES,
                                                 0, 0, 0, 0, 0, 0, 0, "cl probe world", err, sizeof(err));
        assert(pso2);
        cm_cmd_begin(ctx);
        cm_shade_fullscreen_pass(ctx, pso2, target, NULL, 0, NULL, 0, NULL, 0);
        cm_blit_copy_texture_to_buffer(ctx, target, 0, 0, 0, 0, 2, 1, read, 0, 16);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        printf("[Backend %s] Test 2r in-game layout: raw (%g, %g, %g) add (%g, %g, %g)\n", api,
               (double)px[0], (double)px[1], (double)px[2], (double)px[4], (double)px[5], (double)px[6]);
        if (!(px[2] > 0.005f && px[6] > 0.05f)) { fprintf(stderr, "FAIL 2r in-game layout: no light in the volume\n"); exit(1); }
        cm_pipeline_destroy(ctx, pso2);
        cm_function_destroy(fs2);

        // 5. Smooth block light: the soul lantern's section with level 10 for local x < 8, 6 beyond, one opaque row (y 12, z 5).
        //    Halfway between cells 7 and 8 the filter gives 8 / 15; next to the opaque row only the open cells count (10 / 15).
        uint8_t *lv = (uint8_t *)(uintptr_t)cm_cl_levels(state);
        assert(lv);
        for (int c = 0; c < CELLS; c++) {
            int x = c & 15, z = (c >> 4) & 15, y = c >> 8;
            bool open = !(y == 12 && z == 5);
            lv[((size_t)slotL * CELLS + c) * 2] = open ? (uint8_t)((x < 8 ? 10 : 6) * 17) : 0;
            lv[((size_t)slotL * CELLS + c) * 2 + 1] = open ? 255 : 0;
        }
        h2[19] = 0; t2[3] = 1.0f; // tune.w: smooth block light on
        cm_cl_header(state, 1, h2);
        uint32_t *l3 = (uint32_t *)(uintptr_t)cm_cl_list(state, 1);
        l3[0] = (uint32_t)slotL;
        cm_cmd_begin(ctx);
        cm_cl_frame(ctx, state, 1, 0, 0, 0, 1, 0, 1);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        int64_t fs3 = cm_compile_function(lib, "cl_probe_smooth_fs", 0, 0, 0, err, sizeof(err));
        assert(fs3);
        int64_t pso3 = cm_render_pipeline_create(ctx, vs, fs3, NULL, 0, NULL, 0, &color, 1, -1, CM_TOPO_TRIANGLES,
                                                 0, 0, 0, 0, 0, 0, 0, "cl probe smooth", err, sizeof(err));
        assert(pso3);
        cm_cmd_begin(ctx);
        cm_shade_fullscreen_pass(ctx, pso3, target, NULL, 0, NULL, 0, NULL, 0);
        cm_blit_copy_texture_to_buffer(ctx, target, 0, 0, 0, 0, 2, 1, read, 0, 16);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        float mid = px[0], wall = px[4];
        printf("[Backend %s] Test 2r smooth block light: between levels 10 and 6 %.3f (want %.3f), beside an opaque row %.3f (want %.3f)\n",
               api, (double)mid, 8.0 / 15.0, (double)wall, 10.0 / 15.0);
        if (fabsf(mid - 8.0f / 15.0f) > 0.02f || fabsf(wall - 10.0f / 15.0f) > 0.02f) {
            fprintf(stderr, "FAIL 2r smooth block light\n");
            exit(1);
        }
        cm_pipeline_destroy(ctx, pso3);
        cm_function_destroy(fs3);
    }

    // Warm cost of the in-game step (one spread step a frame over the slots near coloured lights): 8 sections, best of 10.
    double stepMs = 1e9;
    for (int it = 0; it < 12; it++) {
        uint32_t *l2 = (uint32_t *)(uintptr_t)cm_cl_list(state, 2);
        for (int i = 0; i < FINE_SLOTS; i++) l2[i] = (uint32_t)i;
        double s0 = CFAbsoluteTimeGetCurrent();
        cm_cmd_begin(ctx);
        cm_cl_frame(ctx, state, 2, 0, FINE_SLOTS, 0, 1, 0, 0);
        assert(cm_wait_submit(ctx, cm_cmd_submit(ctx, 2), 5000000000ULL) == 1);
        double ms = (CFAbsoluteTimeGetCurrent() - s0) * 1000.0;
        if (it >= 2 && ms < stepMs) stepMs = ms;
    }
    assert(cm_device_drain_errors(ctx, err, sizeof(err)) == 0);
    printf("[Backend %s] Test 2r P6b coloured block light (fallback, soul-fire spread %.3f %.3f %.3f in front, 0 behind the wall, "
           "strength 0; cold clear + 24 steps %.3f ms, warm step over 8 sections %.3f ms incl. submit) OK\n",
           api, (double)fr, (double)fg, (double)fb, floodMs, stepMs);
    #undef CL_ID
    #undef CL_PROBE

    cm_cl_free(ctx, state);
    cm_buffer_destroy(ctx, read);
    cm_texture_destroy(ctx, target);
    cm_pipeline_destroy(ctx, pso);
    cm_function_destroy(vs); cm_function_destroy(fs);
    cm_library_destroy(lib);
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
    benchmark_pass_merging(1);
    benchmark_pass_merging(0);
    benchmark_draw_overhead(1);
    benchmark_draw_overhead(0);
    benchmark_upscale(1);
    benchmark_upscale(0);
    benchmark_p1_hdr_post([NSString stringWithUTF8String:argv[1]], 1);
    benchmark_p1_hdr_post([NSString stringWithUTF8String:argv[1]], 0);
    benchmark_p2_shadow([NSString stringWithUTF8String:argv[1]], 1);
    benchmark_p2_shadow([NSString stringWithUTF8String:argv[1]], 0);
    verify_p3a_water([NSString stringWithUTF8String:argv[1]], 1);
    verify_p3a_water([NSString stringWithUTF8String:argv[1]], 0);
    benchmark_p3a_water([NSString stringWithUTF8String:argv[1]], 1);
    benchmark_p3a_water([NSString stringWithUTF8String:argv[1]], 0);
    verify_p3b_atmosphere([NSString stringWithUTF8String:argv[1]], 1);
    verify_p3b_atmosphere([NSString stringWithUTF8String:argv[1]], 0);
    verify_p4_taau([NSString stringWithUTF8String:argv[1]], 1);
    verify_p4_taau([NSString stringWithUTF8String:argv[1]], 0);
    verify_p6a_dynlights([NSString stringWithUTF8String:argv[1]], 1);
    verify_p6a_dynlights([NSString stringWithUTF8String:argv[1]], 0);
    verify_p6b_colorlights([NSString stringWithUTF8String:argv[1]], 1);
    verify_p6b_colorlights([NSString stringWithUTF8String:argv[1]], 0);
    printf("ALL CELESTIA METAL NATIVE GPU TESTS PASSED.\n");
    return 0;
}
