# Changelog

## 0.1.0-alpha.11

### Performance
- **Render pass merging**: consecutive RenderPearl passes on identical attachments without clears now continue the same Metal render encoder (`cm_pass_finish` soft end), avoiding a full-resolution tile store/load and a Metal 4 queue barrier per pass. Synthetic 24-pass 3024 × 1752 frame on M1 Pro: ~1.2–2.1 ms → ~0.13–0.27 ms GPU (Metal 4 and Metal 3).
- **Deferred clears**: `clearColorTexture` / `clearDepthTexture` / `clearColorAndDepthTextures` fold into the next pass's load action instead of running as separate clear encoders.
- **Metal 4 argument-table dedup**: uniform and vertex buffer GPU addresses are only rewritten when they change.
- **FFM hot path**: per-frame downcall handles are `static final` (inlinable by C2) and short non-blocking calls use `Linker.Option.critical(false)`; per-pass/per-draw `Arena` allocations were replaced with reusable scratch memory, and interleaved `multiDraw` / `multiDrawIndexed` commands are read natively without Java-side repacking (`cm_pass_multi_draw_packed`, `cm_pass_multi_draw_indexed_packed`). Pass labels are only built when debug labels are enabled.

### Added
- F3 `Celestia Encoders` line with per-frame passes, render encoders, merges, folded/flushed clears, blit encoders, and draw counts (`cm_device_stats`).
- **Render Pass Merging** and **Deferred Clears** toggles (Advanced tab and Sodium's Celestia Metal page, `performance.renderPassMerging` / `performance.deferredClears`), applied live on the next frame. `-Dcelestiametal.noPassMerge=true` / `-Dcelestiametal.noDeferClears=true` force them off.
- Native Test 2h (staging-buffer reuse across buffer->texture uploads in one blit encoder; fails on Metal 4 without the barrier).
- `BufferReadbackSyncTest` (JUnit, real Metal device) covering read-map synchronization after GPU copies.
- Native Test 2g (merging, clear folding & ordering, stats, disabled-option path) and a pass-merge GPU benchmark for Metal 4 and Metal 3; FFM smoke coverage for the new entry points.

### Fixed
- **Corrupted / banded Xaero's Minimap tiles on Metal 4 (missing blit barrier)**: `cm_blit_copy_buffer_to_texture` (used by `copyBufferToTexture` and `writeToTexture`) was the only buffer/texture blit without a Metal 4 intra-encoder `MTLStageBlit` barrier. Xaero's World Map fills a tile's upload buffer with `writeToBuffer` (a buffer->buffer blit) and immediately copies it into the tile texture, so on Metal 4 the texture copy could run before its source was written, uploading the previous tile's or partially written bytes. Present since the first alpha; Metal 3 was unaffected (automatic hazard tracking).
- **GPU readback race on buffer maps**: `GpuBuffer.map(read = true)` now waits for queued GPU writes into that buffer (`copyTextureToBuffer`, `copyToBuffer`, `writeToBuffer`), submitting the recording command buffer when needed, matching OpenGL's implicit synchronization. Xaero's World Map reads branch-texture downloads by mapping its pack buffer straight away and could previously read stale bytes 1–3 frames early. Write-only maps remain unsynchronized. Present since the first alpha.
- **Celestia Metal F3 lines hidden**: Minecraft 26.3 only shows debug entries that belong to the active F3 profile or the saved custom layout, so the `celestiametal:status` entry defaulted to `NEVER`. `DebugScreenEntryListMixin` now enables it (`IN_OVERLAY`) unless the player has explicitly chosen a status for it in F3+F6.

### Changed
- Native ABI bumped to `CM_ABI_VERSION 2` (`cm_pass_finish`, `cm_device_set_option`, `cm_device_stats`, packed multi-draws).

## 0.1.0-alpha.10

### Fixed
- **Sodium Chunk Geometry Spikes (`cm_blit_copy_buffer` Metal 4 Barriers & Overlap Guard)**:
  - Emitted intra-encoder `MTLStageBlit -> MTLStageBlit` barriers (`MTL4VisibilityOptionDevice`) between chained blit operations in `cm_encoder.m` (`cm_blit_copy_buffer`, `cm_blit_copy_texture_to_buffer`, `cm_blit_copy_texture`) so Sodium's `BufferArena` staging-to-arena upload followed immediately by arena resize or compaction copies never race concurrently on Metal 4.
  - Handled overlapping same-buffer `cm_blit_copy_buffer` ranges safely through a retired temporary staging buffer so incremental arena defragmentation behaves like `memmove`.
  - Guarded `cm_pass_multi_draw_indexed` against out-of-range byte offsets before computing `indexBufferLength`.
- **Non-Blocking Fence Polls & `TEXEL_BUFFER` Whole-Buffer Binding**:
  - Updated `CelestiaFence.awaitCompletion(0L)` to return `false` without flushing an active recording command buffer when polling unsubmitted staging fences (such as Sodium's `MappedStagingBuffer.flip()`).
  - Handled `CelestiaBuffer` directly in `CelestiaRenderPass.flushUniforms()` for `TEXEL_BUFFER` uniforms (`u_SectionTimeInfo` in Sodium).

### Added
- Chained blit upload/resize and overlapping bidirectional `memmove` GPU regression test (`Test 2f` in `tools/test_metal_backend.m`) for both Metal 4 and Metal 3.

## 0.1.0-alpha.9

### Added
- **Sodium 0.9+ / Reese's Sodium Options Config API Integration**: Implemented `CelestiaSodiumConfigEntrypoint` (`sodium:config_api_user` in `fabric.mod.json`) so **Celestia Metal** appears directly in Sodium's Video Settings sidebar with `Apple Silicon`, `Performance`, `Shader Packs`, and `CelestiaGlow UI` pages while keeping zero hard dependency when Sodium is not installed.
- **Updated Roadmap ([ARCHITECTURE.md](ARCHITECTURE.md))**: Added zero-allocation hot-path FFM encoding, Metal 4 uniform/vertex GPU-address deduplication, and full-frame GPU timestamp accumulation alongside live `LevelRenderer` G-buffer/shadow injection, Iris frame-graph execution, and standalone indirect terrain meshing.

## 0.1.0-alpha.8

### Fixed
- **In-Game Sky Flickering & Metal 4 Encoder Barriers**: Added explicit Metal 4 producer barriers (`barrierAfterStages:beforeQueueStages:visibilityOptions:MTL4VisibilityOptionDevice`) before `endEncoding` in `cm_blit_clear_color`, `cm_blit_clear_depth`, and `cm_blit_clear_color_depth` so subsequent `MTLLoadActionLoad` render passes (such as the sky pass following `clearColorAndDepthTextures`) never race the preceding clear on Apple Silicon.
- **Ring Buffer Fence Synchronization**: Updated `CelestiaCommandEncoder.createFence()` and `CelestiaFence.awaitCompletion` using `cm_cmd_has_active` so fences created while commands are recording track the upcoming submission serial rather than the previously submitted serial, preventing `MappableRingBuffer` (`Dynamic Transforms UBO`) slot reuse while GPU draws are still in flight.
- **Persistent Native `TRIANGLE_FAN` Index Buffer**: Moved `TRIANGLE_FAN` triangulation (`CM_TOPO_TRIANGLE_FAN`) into native `cm_pass_draw` backed by a grow-only shared `fanIndexBuffer` with `baseVertex` offsetting, eliminating per-frame sky index buffer churn and preventing fan draws from overwriting the caller's bound index buffer.
- **Metal 4 Argument Table & Blit/Compute Barrier Hardening**: Clamped `MTL4ArgumentTableDescriptor.maxBufferBindCount` to the documented max of `31`, switched `cm_compute_dispatch` post-dispatch barrier to `barrierAfterStages:beforeQueueStages:`, added intra-blit `MTLStageBlit` barriers before texture read/copy commands on Metal 4, and cleared stale `pendingUniforms` on `CelestiaRenderPass.setPipeline`.

### Added
- Native Metal 4 & Metal 3 GPU stress test (`Test 2e` in `tools/test_metal_backend.m`) and Java FFM smoke assertions covering `cm_cmd_has_active`, clear-to-load barriers across 16 back-to-back iterations, and `CM_TOPO_TRIANGLE_FAN` index-buffer preservation.

## 0.1.0-alpha.7

### Fixed
- **Missing Text & Panorama Background (`copyBufferToTexture` Signature)**: Corrected parameter order in `CelestiaCommandEncoder.copyBufferToTexture` to match RenderPearl's `(dstX, dstY, width, height, mipLevel, arrayLayer)` order instead of `(mip, slice, dstX, dstY, width, height)`. Previously `mip=0` / `slice=0` overwrote `width`/`height` as zero, skipping every bitmap font glyph upload and every panorama cubemap upload.
- **Interleaved Multi-Draw Signature**: Corrected the `(instanceCount, firstInstance, drawCount)` parameter order in `CelestiaRenderPass.multiDraw` and `multiDrawIndexed` to match `RenderPassBackend`.
- **Metal 2D Copy `bytesPerImage`**: Set `sourceBytesPerImage` / `destinationBytesPerImage` to `0` for `depth == 1` buffer-texture copies in `cm_encoder.m` per Metal 4 / Metal 3 spec.

### Added
- Native Metal 4 & Metal 3 GPU readback verification in `tools/test_metal_backend.m` covering strided sub-rect `R8_UNORM` glyph uploads and 6-face cubemap texture uploads.

## 0.1.0-alpha.6

### Fixed
- **Black Screen on Launch (`ByteOrder.BIG_ENDIAN` Mapped Buffers)**: Configured `ByteOrder.nativeOrder()` (little-endian on Apple Silicon) on every `MemorySegment.asByteBuffer()` view in `CelestiaBuffer.map`, `CelestiaTransientMemory`, and `ShaderPipelineManager`. Previously, `MemorySegment.asByteBuffer()` defaulted to big-endian, byte-swapping every uniform matrix, color, and UI/world vertex written by Minecraft (`1.0f` collapsed to near-zero) and producing a solid black frame.
- **Deferred Cleanup Serial Tracking & Surface Present Viewport**: Synced `CelestiaCommandEncoder.runWhenSubmitDone(...)` directly with native submit serials so deferred transient rotations and texel view releases never drift across frames, explicitly set viewport/scissor/cull mode on `cm_surface_blit_and_present`, and logged Metal GPU errors via `deviceDrainErrors` / `stderr`.

### Added
- Little-endian native byte-order verification in `NativeFfmSmokeTest`.

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
