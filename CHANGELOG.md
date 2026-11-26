# Changelog

## 0.1.0-alpha.5

### Fixed
- **Depth-Writing Shaders & OIT Terrain PSO Crash**: Matched RenderPearl's depth pre-warming contract in `CelestiaPipeline` by always pre-warming `FMT_D32_FLOAT` and only pre-warming `NO_DEPTH` when `depthStencilState == null`. This prevents Metal from rejecting shaders that write `[[depth(any)]]` (such as `minecraft:pipeline/oit_transmittance_terrain_multidraw`) with `depthAttachmentPixelFormat is not valid and shader writes to depth`.
- **Combined Depth-Stencil Pass Attachments**: Attached and cleared `stencilAttachment` in `cm_pass_begin`, `cm_blit_clear_depth`, and `cm_blit_clear_color_depth` whenever the depth texture uses `MTLPixelFormatDepth32Float_Stencil8`.

### Added
- Live Metal 4 / Metal 3 GPU test in `tools/test_metal_backend.m` verifying fragment depth writes (`[[depth(any)]]`) with both `CM_FMT_D32_FLOAT` and combined `CM_FMT_D32_FLOAT_S8_UINT` attachments.

## 0.1.0-alpha.4

### Fixed
- **Java 25 FFM `WrongMethodTypeException` Crash**: Replaced inline nullable ternary expressions inside signature-polymorphic `MethodHandle.invokeExact(...)` calls in `MetalNative` (`renderPipelineCreate`, `passBegin`, `passMultiDrawIndexed`, `computeDispatch`, and `bufferCreate`) with `segOrNull(...)` so `javac` always emits exact `MemorySegment` call-site descriptors instead of `Object`.
- **Concurrent Pipeline Compilation Safety**: Synchronized `MTLBinaryArchive` additions across parallel pipeline compile workers and handled zero-stride constant vertex buffer descriptors cleanly in native code.

### Added
- Exhaustive Java FFM integration test (`NativeFfmSmokeTest.exercisesRenderPipelinePassDrawAndComputeViaFfm`) exercising all `MetalNative` render pipeline, render pass, multi-draw, texel buffer, compute, blit, and MetalFX upscaler calls directly on Apple Silicon GPUs.

## 0.1.0-alpha.3

### Fixed
- **Proportional Tab & Responsive Footer Layout**: Updated Video Settings, Shader Packs, and Shader Options screens to distribute tab and footer button widths proportionally (`CelestiaWidgets.computeProportionalWidths`) and clip labels safely so `Performance` and `Apple Silicon` never overflow their tab frames and footer buttons never overlap at narrow GUI sizes.
- **Native CelestiaGlow Search Input**: Removed the vanilla dark opaque border around `EditBox` across all UI screens and replaced it with translucent violet-slate glass chrome and responsive sizing so search inputs never collide with header status badges.
- **Scrollbars, Soft Clipping & Card Rhythm**: Added frosted 3px scrollbars, subtle top/bottom scroll fade gradients, hover left-edge lavender accents, `4px` inter-row breathing room, and accurate inspector preset hit-testing.
- **Deferred Retina GUI Scale Slider**: Deferred `GUI Scale` application until `Apply` or `Done` so dragging the slider never rescales and shifts the UI under the cursor mid-drag, and expanded its range to support HiDPI/Retina scales (`Auto` through `8x`+, dynamically scaled with framebuffer size).
- **One-Click Fallback Status & Recovery**: Replaced `"Fallback Backend"` with clear backend diagnostics (`OpenGL · Click -> Metal`, `Vulkan · Click -> Metal`, or `Metal Ready · Restart`) so if Minecraft's crash recovery switched `preferredGraphicsBackend` to `opengl` after an earlier crash, clicking the header badge switches it right back to `Default (Metal)` and saves `options.txt`.

### Added
- Unit tests verifying proportional tab/footer layout distribution across wide and narrow window widths (`ConfigAndUiTest.proportionalWidthDistributionFitsAndPreservesHierarchy`).

## 0.1.0-alpha.2

### Fixed
- **Startup Crash (`RGB32_FLOAT`)**: Added full Metal vertex attribute format support for all 12 3-component `RGB*` formats (`CM_FMT_RGB8_UNORM` through `CM_FMT_RGB32_FLOAT`, including `MTLVertexFormatFloat3`) while keeping 3-component texture creation disallowed per Metal spec.
- **Texel Buffers (`TEXEL_BUFFER`)**: Added `cm_texture_buffer_create` (`MTLTextureTypeTextureBuffer` with automatic linear alignment staging fallback) and bound `GpuBufferSlice` texel buffers properly in `CelestiaRenderPass`.
- **Render Pass Uniform Flushing**: Cached `setUniform` bindings per pass and flushed lazily before draw calls so bindings set prior to `setPipeline` or preserved across pipeline switches apply reliably.
- **Buffer Upload Safety**: Fixed direct `ByteBuffer` buffer creation reading past input capacity when size is rounded up to the power-of-two pool bucket.
- **Pipeline & Encoder Hardening**: Guarded optional null `DepthStencilState` and depth-only pipeline pre-warming, ensured native byte order for SPIR-V translation, aligned Metal 4 argument table static vertex strides, applied full-attachment viewport + `renderArea` scissor on pass start, and inserted explicit Metal 4 producer barriers between encoders.

### Added
- Regression unit tests covering all 12 `RGB*` vertex attribute mappings and live Metal 4 / Metal 3 GPU readback verification for `CM_FMT_RGB32_FLOAT` / `CM_FMT_RGB8_SNORM` vertex attributes and `MTLTextureTypeTextureBuffer` sampling.

## 0.1.0-alpha.1

Initial independent release of **Celestia Metal** for Minecraft: Java Edition 26.3 (Fabric, Java 25, Apple Silicon).

### Added
- **Native Metal 4 & Metal 3 Backend (`libcelestiametal.dylib`)**:
  - Metal 4 support on macOS 26+ (`MTL4CommandQueue`, `MTL4CommandAllocator` ring, `MTL4CommandBuffer`, `MTL4ArgumentTable`, `MTL4Compiler`, `MTLResidencySet`, `MTL4CommitOptions`, `MTL4FXSpatialScaler`, `MTL4FXTemporalScaler`) with automatic Metal 3 fallback on macOS 15+.
  - Java 25 FFM bridge (`MetalNative`) implementing `com.mojang.renderpearl` (`GpuBackend`, `GpuDeviceBackend`, `CommandEncoderBackend`, `RenderPassBackend`, `GpuSurfaceBackend`).
  - Size-bucketed `MTLStorageModeShared` buffer pooling, unified-memory transient allocator, `MTLBinaryArchive` disk pipeline cache, and SPIRV-Cross MSL 3.1 shader translation with selective relaxed terrain math.
  - HDR / EDR (`RGBA16Float` Extended Linear Display P3) swapchain & ProMotion 120 Hz + thermal/battery telemetry.
- **Native MSL Shader Pack Ecosystem (API v1)**:
  - Bundled **`Celestia Native`** (4 presets, 20 options) and **`Celestia Minimal`** (2 presets, 5 options) Apple Silicon-first MSL packs.
  - External `shaderpacks/` discovery, hotkeys (`O` open, `K` toggle, `R` reload), and Iris/OptiFine GLSL pack option parser + `Shaderc`→`Spvc` translation bridge.
- **CelestiaGlow Frosted Observatory UI**:
  - Tabbed, searchable replacement for Vanilla Video Settings (`General`, `Quality`, `Performance`, `Apple Silicon`, `Shaders`, `Advanced`), dedicated Shader Packs & Shader Options screens, and top-left Performance HUD pill.
- **Automated Testing & M1 Pro GPU Verification**:
  - JUnit 5 test suite (`ShaderManifestTest`, `IrisPackParserTest`, `ConfigAndUiTest`, `NativeFfmSmokeTest`).
  - Live Apple Silicon GPU test & benchmark suite (`tools/test_metal_backend.m`).
