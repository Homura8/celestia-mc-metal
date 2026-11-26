# AGENTS.md

Practical guidance for AI agents and contributors working on **Celestia Metal** (`https://github.com/Homura8/celestia-mcmetal`). Keep changes coherent, test directly against Apple Silicon hardware, and preserve the single-JAR, zero-manual-setup user experience.

---

## Project Snapshot

- **Goal**: Independent, single-JAR, Apple Silicon-first **Metal 4 / Metal 3** renderer (`com.mojang.renderpearl`) and native **MSL** shader pack ecosystem for **Minecraft: Java Edition 26.3 (Fabric, Java 25)**.
- **Distribution model**: Everything builds into one Fabric mod JAR (`build/libs/celestia-metal-<version>.jar`) bundling `natives/macos-arm64/libcelestiametal.dylib`. Avoid introducing external tools, manual JVM arguments, or mandatory Fabric API dependencies.
- **License & Attribution**: Apache-2.0. Keep `LICENSE`, `NOTICE`, and `CREDITS.md` accurate whenever incorporating ideas or algorithms from the open-source ecosystem.

---

## Repository Map

- **Native Engine (`src/main/native/`)**
  - `celestia_metal.h`: C ABI (`CM_ABI_VERSION`), format/topology/blend enums matching `MetalConst.java`, and `CMContext`.
  - `cm_device.m`: Device probe (Apple7+), Metal 4 / Metal 3 init, `MTLResidencySet`, `MTL4CommandAllocator` ring, `MTLBinaryArchive`, telemetry, and retired-resource draining.
  - `cm_resources.m`: `MTLStorageModeShared` buffers, private textures/views, linear `MTLTextureTypeTextureBuffer`, samplers, MSL compilation (`MTL4Compiler` / `MTLDevice`), and PSO creation.
  - `cm_encoder.m`: Command buffers, clear render passes, render pass state deduplication, push-constant ring, native `TRIANGLE_FAN` index buffer, and multi-draw / indirect draws.
  - `cm_surface.m`: `CAMetalLayer` SDR (`BGRA8Unorm`) & HDR/EDR (`RGBA16Float` Display P3) presentation.
  - `cm_upscaler.m`: `MTL4FX*` / `MTLFX*` Spatial & Temporal upscaling.
  - `cm_shader_runtime.m`: Compute dispatch helper for shader packs.
- **Java Backend (`src/main/java/dev/celestia/metal/backend/`)**: RenderPearl backend (`CelestiaMetalBackend`, `CelestiaMetalDevice`, `CelestiaCommandEncoder`, `CelestiaRenderPass`, `CelestiaSurface`, `CelestiaPipeline`, `CelestiaTransientMemory`, `MetalNative`, `MetalConst`, `MetalShaderTranslator`, `StartupGuard`).
- **Mixins (`src/main/java/dev/celestia/metal/mixin/`)**: Entry points into MC 26.3 (`PreferredGraphicsApiMixin`, `GameRendererMixin`, `GuiMixin`, `HudMixin`, `KeyboardHandlerMixin`, `MinecraftMixin`, `DebugScreenEntriesMixin`).
- **Shader Packs (`src/main/java/dev/celestia/metal/shader/` & `src/main/resources/assets/celestiametal/`)**: Native MSL packs (`celestia-native`, `celestia-minimal`, `celestia_common.metal`) and Iris/OptiFine parser/bridge (`IrisPackParser`, `IrisGlslBridge`).
- **CelestiaGlow UI (`src/main/java/dev/celestia/metal/ui/`) & Perf (`dev.celestia.metal.perf`)**: Tabbed video settings, shader pack/option screens, performance engine, and HUD pill.
- **Tests & Benchmarks**: `src/test/java/dev/celestia/metal/` (JUnit 5 + FFM) and `tools/test_metal_backend.m` (live Metal 4 & Metal 3 GPU verification + 3024 × 1752 synthetic benchmark).

---

## Essential Commands

Run the full build, privacy check, JUnit 5 suite, native compilation (`-Wall -Werror`), and live Metal 4 / Metal 3 GPU tests together:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@25 ./gradlew clean build check runNativeTests --no-daemon
```

Useful targeted checks when debugging:

```sh
# 1. Verify no Java 25 MethodHandle.invokeExact call accidentally inferred Object:
javap -c build/classes/java/main/dev/celestia/metal/backend/MetalNative.class | grep -E "invokeExact.*Ljava/lang/Object;"

# 2. Inspect Minecraft 26.3 / RenderPearl exact parameter order & names:
javap -cp ~/.gradle/caches/fabric-loom/minecraftMaven/net/minecraft/minecraft-merged-deobf/26.3/minecraft-merged-deobf-26.3.jar \
  -v com.mojang.renderpearl.backend.api.CommandEncoderBackend

# 3. Inspect Apple Metal 4 SDK headers:
ls "$(xcrun --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers/" | grep MTL4
```

---

## Technical Invariants & Pitfalls

1. **Java 25 FFM (`MetalNative.java`)**:
   - `MethodHandle.invokeExact` is signature-polymorphic at compile time. Never pass an inline ternary (`seg != null ? seg : MemorySegment.NULL`) as an argument — `javac` may infer `Object` instead of `MemorySegment`, triggering `WrongMethodTypeException` at runtime. Always wrap nullable segments in `segOrNull(seg)`.
   - Keep `cm_*` C signatures in `src/main/native/celestia_metal.h`, `FunctionDescriptor`s in `MetalNative.java`, and numeric enums in `MetalConst.java` strictly synchronized.

2. **Byte Order on `MemorySegment.asByteBuffer()`**:
   - `MemorySegment.asByteBuffer()` returns a **`BIG_ENDIAN`** `ByteBuffer` by default on every architecture! Always chain `.order(ByteOrder.nativeOrder())` on any mapped view before handing it to Minecraft/LWJGL or reading/writing floats/ints.

3. **Metal 4 Explicit Synchronization & Residency**:
   - Unlike Metal 3, `MTL4CommandBuffer` has **no automatic inter-encoder hazard tracking**. Whenever adding a Metal 4 render pass, clear encoder, compute dispatch, or dependent blit copy, emit an explicit producer/intra-encoder barrier (`barrierAfterStages:beforeQueueStages:visibilityOptions:MTL4VisibilityOptionDevice` or `barrierAfterEncoderStages:beforeEncoderStages:`).
   - Register every Metal 4 `MTLBuffer` / `MTLTexture` / texture view with `cm_track_allocation(ctx, obj)`, never destroy resources while in flight (use `cm_retire_object`), and keep `MTL4ArgumentTableDescriptor.maxBufferBindCount <= 31`.
   - Guard all Metal 4 API usage with `@available(macOS 26.0, *)` so Metal 3 (macOS 15+) and `-Wall -Werror` stay clean.

4. **RenderPearl Backend Contracts**:
   - **Always verify parameter names/order via `javap -v` (`MethodParameters`)** instead of guessing — RenderPearl overloads have non-obvious parameter orderings (for example, `copyBufferToTexture` uses `(dstX, dstY, width, height, mip, slice)` and `multiDraw` uses `(commands, instanceCount, firstInstance, drawCount)`).
   - **Depth PSO pre-warming**: Pre-warm `FMT_D32_FLOAT` unconditionally, and only pre-warm `NO_DEPTH` when `info.depthStencilState() == null` so shaders writing `[[depth(any)]]` never compile against `MTLPixelFormatInvalid`.
   - **Fences & Ring Buffers**: `createFence()` must return the upcoming submit serial (`deviceNextSubmit + 1`) whenever `cm_cmd_has_active` is true, and `awaitCompletion()` must flush an active recording command buffer before waiting.
   - **Primitive Topology**: Handle `TRIANGLE_FAN` natively inside `cm_pass_draw` (`CM_TOPO_TRIANGLE_FAN`) via the grow-only `fanIndexBuffer` with `baseVertex`, without overwriting `ctx.boundIndexBuffer`.

5. **Privacy Check (`checkPrivacy`) & Workspace Boundaries**:
   - `./gradlew check` scans tracked files and non-native resources to ensure no machine-specific home directory paths or local OS usernames are committed. Always use `~/` or environment variables in docs and scripts.
   - Do not modify external user launcher instances (e.g., PrismLauncher `mods/` or `options.txt`); only inspect logs/crash reports read-only when debugging user reports.

---

## Workflow Tips

- **UI changes**: Respect `CelestiaTheme` palette/glass tokens, distribute tab/footer widths proportionally (`CelestiaWidgets.computeProportionalWidths`) so narrow/HiDPI windows never clip, and avoid instant viewport-mutating actions during slider drags.
- **Shaders**: Keep native MSL packs fast-path and self-contained per `SHADER_PACK_SPEC.md`. When extending shader integration into `LevelRenderer`, verify compilation on all presets via `tools/test_metal_backend.m`.
- **When fixing a backend or FFM bug**: Add a deterministic regression assertion in `tools/test_metal_backend.m` (runs on both Metal 4 and Metal 3) and/or `NativeFfmSmokeTest.java` before packaging a release.
