# Celestia Metal — Development & Engineering Notes

This document records how **Celestia Metal** was designed, built, verified, and debugged from initial bootstrap (`0.1.0-alpha.1`) through `0.1.0-alpha.8` on Minecraft: Java Edition 26.3 (Fabric, Java 25) and Apple Silicon (`M1 Pro`, macOS 27 / Xcode 27.2, 120 Hz ProMotion).

---

## 1. Research & Design Synthesis

Minecraft 26.3 replaced its legacy OpenGL core with **RenderPearl** (`com.mojang.renderpearl`), an explicit Vulkan-inspired RHI abstraction (`GpuBackend`, `GpuDeviceBackend`, `CommandEncoderBackend`, `RenderPassBackend`, `GpuSurfaceBackend`). Surveying the existing Apple Silicon Metal ecosystem shaped our architecture:

- **Backend Lifetime & Safety (`Pure Metal`, `mcopt`, `Cadence`)**: Explicit deferred resource retirement keyed by `MTLSharedEvent` submit serials, Metal 4 `MTLResidencySet` tracking, power-of-two `MTLStorageModeShared` buffer pooling, unified-memory transient rings, persistent `MTLBinaryArchive` PSO caching, and startup crash-loop isolation (`StartupGuard`).
- **Shader Translation & Native MSL (`Pure Metal`, `Minecraft Metal Shaders`, `Ciderlight`, `SiliconShaders`)**:
  - Vanilla and modded RenderPearl SPIR-V pipelines translate cleanly to MSL 3.1 via LWJGL `Spvc` (SPIRV-Cross) with vertex Y-flip and deterministic slot bindings (`0..14` UBOs, `15` push constants, `16..23` vertex attributes, `0..30` textures, `0..15` samplers), enabling selective fast-math for terrain shaders.
  - Dedicated Apple Silicon shader packs (`Celestia Native` and `Celestia Minimal`) target native MSL directly using `dir.y = v²` Rayleigh/Mie LUTs (eliminating per-pixel `asin`), sky-light cave early-out, half-precision `half4` arithmetic, dual Kawase bloom, and Display P3 HDR output.
  - World packs (`"kind": "world"`, `SHADER_PACK_SPEC.md` §5) override Celestia Native's MSL in `shaderpacks/celestia-native/shaders/` by file name over the engine-owned ABI in `shaders/engine/`, and switch live (`ShadeShaderPatcher.epoch()`).
  - Iris/OptiFine option & property compatibility (`IrisPackParser`, `IrisGlslBridge`) reuses the same option model and UI, but those packs are hidden unless `-Dcelestiametal.irisPacks=true`.
- **Why Java 25 FFM instead of JNI**: `java.lang.foreign` eliminates generated JNI boilerplate headers, binds directly to `libcelestiametal.dylib` extracted from the single JAR, and keeps zero external runtime dependencies beyond `--enable-native-access=ALL-UNNAMED` already passed by Minecraft 26.3.
- **Dual-Backend Architecture (`Metal 4` + `Metal 3`)**: `cm_device.m`, `cm_resources.m`, `cm_encoder.m`, `cm_surface.m`, and `cm_upscaler.m` expose one C ABI backed by Metal 4 (`MTL4CommandQueue`, `MTL4CommandAllocator` ring, `MTL4ArgumentTable`, `MTL4Compiler`, `MTLResidencySet`, `MTL4FX*`) on macOS 26+ with seamless Metal 3 fallback on macOS 15+.

---

## 2. Iterative Engineering & Challenges Solved

Real-world testing against Minecraft 26.3 + Fabric Loader 0.20.1 on Apple M1 Pro uncovered seven subtle interactions across RenderPearl, Java 25 FFM, and Metal 4. Each fix was paired with an automated GPU or FFM regression test.

### Challenge 1 (`0.1.0-alpha.2`): 3-Component Vertex Attributes, Texel Buffers & Argument Strides
- **Symptom**: Immediate startup crash (`Unsupported vertex attribute format: RGB32_FLOAT`) and texel buffer failures.
- **Root Cause**: Metal disallows 3-component *texture* formats (`RGB8`, `RGB32_FLOAT`, etc.), so `MetalConst.toNativeFormat` rejected them—but `CelestiaPipeline.buildPso` initially shared texture-format validation with vertex attributes, where Metal *does* support `MTLVertexFormatFloat3`, `Char3Normalized`, etc. Additionally, `cm_texture_buffer_create` was still a stub, and `MTL4ArgumentTableDescriptor.supportAttributeStrides` defaulted inconsistently with fixed vertex descriptor layouts.
- **Solution**: Split `toNativeVertexFormat` cleanly from `toNativeFormat` and implemented all 12 `CM_FMT_RGB*` vertex formats; implemented `MTLTextureTypeTextureBuffer` with `minimumLinearTextureAlignmentForPixelFormat:`-aligned staging fallback; disabled dynamic attribute strides on `m4VertexArgTable`; guarded null `DepthStencilState`; and added lazy `flushUniforms()` in `CelestiaRenderPass`.

### Challenge 2 (`0.1.0-alpha.3`): CelestiaGlow Layout Overflow, Retina GUI Scale & Watchdog Lockout
- **Symptom**: After any startup crash, Minecraft's graphics watchdog wrote `preferredGraphicsBackend:opengl`, locking the UI into a `"Fallback Backend"` state. Meanwhile, `Performance` / `Apple Silicon` tabs overflowed their frames and dragging the `GUI Scale` slider immediately rescaled the screen mid-drag, shifting the slider thumb away from the cursor.
- **Solution**: Implemented proportional width distribution (`CelestiaWidgets.computeProportionalWidths`), frosted borderless `EditBox` styling, 3px scrollbars with soft fades, an interactive header recovery badge (`OpenGL · Click -> Metal`), and a deferred Retina `GUI Scale` (`Auto`..`8x`+) applied only on `Apply` / `Done`.

### Challenge 3 (`0.1.0-alpha.4`): Java 25 `MethodHandle.invokeExact` Signature Polymorphism
- **Symptom**: `java.lang.invoke.WrongMethodTypeException: cannot convert MethodHandle(long,long,...,MemorySegment,...)long to (long,long,...,Object,...)long` in `MetalNative.renderPipelineCreate`.
- **Root Cause**: Passing `x != null ? x : MemorySegment.NULL` directly to `MethodHandle.invokeExact(...)` caused `javac` to type the argument expression as `java.lang.Object` instead of `MemorySegment` due to ternary type inference inside signature-polymorphic calls. Under parallel `ForkJoinPool` pipeline loading, `MTLBinaryArchive` mutations and zero-stride constant vertex buffers also raced/failed.
- **Solution**: Replaced every nullable ternary inside `MetalNative` with `segOrNull(MemorySegment)` and verified `0` `Ljava/lang/Object;` `invokeExact` descriptors in `MetalNative.class` via `javap -c`. Synchronized `@synchronized(ctx.binaryArchive)` in `cm_resources.m`, handled `stride == 0` with `MTLVertexStepFunctionConstant`, and added `NativeFfmSmokeTest.exercisesRenderPipelinePassDrawAndComputeViaFfm()` to hit every FFM entry point.

### Challenge 4 (`0.1.0-alpha.5`): Depth-Writing Shaders & Combined Depth-Stencil Attachments
- **Symptom**: `Minecraft` crashed compiling `minecraft:pipeline/oit_transmittance_terrain_multidraw` with `depthAttachmentPixelFormat is not valid and shader writes to depth`.
- **Root Cause**: Some RenderPearl shaders write `[[depth(any)]]` (`gl_FragDepth`) even on pipelines pre-warmed without depth testing. We previously pre-warmed `NO_DEPTH` (`MTLPixelFormatInvalid`) indiscriminately, and forgot to attach `rpd.stencilAttachment` for `Depth32Float_Stencil8`.
- **Solution**: Audited `VulkanRenderPipeline` via `javap -v` and matched its exact contract: always pre-warm `FMT_D32_FLOAT`, and only pre-warm `NO_DEPTH` when `info.depthStencilState() == null && !info.colorTargetStates().isEmpty()`. Added `configure_depth_stencil_attachments` in `cm_encoder.m` so `Depth32Float_Stencil8` binds and clears both depth and stencil.

### Challenge 5 (`0.1.0-alpha.6`): Solid Black Screen (`MemorySegment.asByteBuffer()` Endianness)
- **Symptom**: Minecraft booted into Metal 4 with zero GPU errors or crashes, yet rendered a solid black window.
- **Root Cause**: In Java's Foreign Memory API, `MemorySegment.asByteBuffer()` **always returns a `ByteOrder.BIG_ENDIAN` view**, whereas `MemoryUtil.memByteBuffer` in LWJGL/Vulkan uses native byte order! Every transformation matrix (`1.0f` → tiny subnormal float), color, and vertex position uploaded into `CelestiaBuffer.map`, `CelestiaTransientMemory`, and `ShaderPipelineManager` was byte-swapped on little-endian Apple Silicon.
- **Solution**: Applied `.order(ByteOrder.nativeOrder())` on all mapped buffer views, aligned `CelestiaCommandEncoder.runWhenSubmitDone` directly with `MetalNative.deviceNextSubmit`, surfaced GPU errors to `stderr` + `LOGGER.error`, and explicitly configured viewport/scissor/cull state on the present encoder.

### Challenge 6 (`0.1.0-alpha.7`): Missing Text & Panorama Background (Swapped Backend Parameters)
- **Symptom**: 3D UI rectangles and world geometry rendered, while all bitmap font glyphs and the main-menu panorama cubemap were missing.
- **Root Cause**: Bytecode `MethodParameters` audit across RenderPearl's `CommandEncoderBackend` and `RenderPassBackend` revealed two parameter-order mismatches from manual Java interface implementation:
  1. `copyBufferToTexture` takes `(srcSlice, srcX, srcY, srcRowLengthPixels, srcImageHeight, dstTex, dstX, dstY, width, height, mipLevel, arrayLayer)`—we had `(mip, slice, dstX, dstY, width, height)`, passing `mip=0, slice=0` into `width` and `height` so every atlas/cubemap upload became a `0 × 0` copy.
  2. `multiDraw` and `multiDrawIndexed` take `(drawCommands, instanceCount, firstInstance, drawCount)` rather than `(drawCommands, drawCount, instanceCount, firstInstance)`.
  Additionally, Metal requires `sourceBytesPerImage = 0` / `destinationBytesPerImage = 0` for `depth == 1` buffer-texture copies.
- **Solution**: Corrected the Java signatures and native `bytesPerImage` arguments, and added native GPU readback tests in `tools/test_metal_backend.m` verifying strided sub-rect `R8_UNORM` glyph uploads and 6-face cubemap uploads.

### Challenge 7 (`0.1.0-alpha.8`): Intermittent In-Game Sky Flickering & Metal 4 Barriers
- **Symptom**: After UI and gameplay rendered cleanly, the in-game sky occasionally flickered.
- **Root Cause**: Three interacting issues:
  1. **Missing Metal 4 producer barriers on clear encoders**: `MTL4CommandBuffer` provides no implicit hazard tracking between encoders. `cm_pass_end` and `cm_end_blit_if_active` emitted `MTL4` barriers, but `cm_blit_clear_color`, `cm_blit_clear_depth`, and `cm_blit_clear_color_depth` ended their `MTL4RenderCommandEncoder` without a producer barrier—allowing Minecraft's pre-sky `clearColorAndDepthTextures` to race concurrently with the `MTLLoadActionLoad` sky render pass.
  2. **Off-by-one `createFence()` submit serial**: `CelestiaCommandEncoder.createFence()` returned `deviceNextSubmit` (already submitted) instead of the active recording serial (`deviceNextSubmit + 1`), allowing `MappableRingBuffer` (`Dynamic Transforms UBO`) to rotate onto a frame still executing on the GPU.
  3. **Per-draw `TRIANGLE_FAN` allocation & `boundIndexBuffer` clobbering**: `SkyRenderer` renders sky discs and sunrise/sunset as `TRIANGLE_FAN`; the Java helper allocated a fresh index buffer per draw and overwrote `ctx.boundIndexBuffer`.
- **Solution**: Added `emit_m4_render_producer_barrier` to all Metal 4 clear encoders, fixed `cm_compute_dispatch` post-dispatch barrier stage method and `maxBufferBindCount = 31`, added intra-blit `MTLStageBlit` barriers before texture reads, implemented `cm_cmd_has_active` for exact fence serials, moved `CM_TOPO_TRIANGLE_FAN` into native `cm_pass_draw` using a grow-only `fanIndexBuffer` with `baseVertex`, and added a 16-iteration stress test (`Test 2e`) to `tools/test_metal_backend.m`.

---

## 3. Verification Architecture

Every commit targeting the backend or shaders is verified across four layers on Apple Silicon:
1. **Native Compilation**: `clang` compiles `src/main/native/*.m` (`-arch arm64 -mmacosx-version-min=15.0 -Wall -Werror`).
2. **Privacy & Packaging (`./gradlew check`)**: `checkPrivacy` scans all tracked files and non-native resources for accidental personal paths/usernames.
3. **JUnit 5 + Java 25 FFM Smoke Tests (`./gradlew test`)**: Covers config serialization, Iris pack parsing, shader manifests, UI proportional layout math, and live Java→C FFM calls (`NativeFfmSmokeTest`).
4. **Live GPU Functional + Benchmark Suite (`./gradlew runNativeTests`)**: Runs `tools/test_metal_backend.m` identically under **both Metal 4 and Metal 3** (`buffer` blits, `RGB32_FLOAT` / `RGB8_SNORM` + texel buffers, `[[depth(any)]]` on `D32_FLOAT` & `D32S8`, sub-rect `R8_UNORM` & 6-face cubemap readback, 16-iteration clear→load barrier + `CM_TOPO_TRIANGLE_FAN`, MetalFX Spatial/Temporal scaling, all shader presets, and a 3024 × 1752 synthetic GPU frame benchmark).
