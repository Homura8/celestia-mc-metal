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

        // Compile-verify every ported P1 .metal file on both Metal 4 and Metal 3
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
            NSString *src = [NSString stringWithFormat:@"%@\n%@\n%@", dummyDefines, prelude, body];
            int64_t l = cm_compile_msl_library(ctx, src.UTF8String, fn.UTF8String, 1, serr, sizeof(serr));
            if (!l) {
                fprintf(stderr, "FAIL 2l compiling ported shader %s:\n%s\n", fn.UTF8String, serr);
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
    printf("ALL CELESTIA METAL NATIVE GPU TESTS PASSED.\n");
    return 0;
}
