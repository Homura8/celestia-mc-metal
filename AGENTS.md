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
- **Mixins (`src/main/java/dev/celestia/metal/mixin/`)**: Entry points into MC 26.3 (`PreferredGraphicsApiMixin`, `GameRendererMixin`, `GuiMixin`, `HudMixin`, `KeyboardHandlerMixin`, `MinecraftMixin`, `DebugScreenEntriesMixin`, `DebugScreenEntryListMixin`) and world render scale (`dev.celestia.metal.render.WorldRenderScale`).
- **Shader Packs (`src/main/java/dev/celestia/metal/shader/` & `src/main/resources/assets/celestiametal/`)**: Native MSL packs. World packs (`"kind": "world"`) replace the world renderer's MSL: Celestia Native's sources are `shaderpacks/celestia-native/shaders/`, the engine-owned ABI and kernels `shaders/engine/` (`shade_api.metal`, `shade_slots.metal`, light/TAA kernels), resolved by `ShadeShaderPatcher.resource`. Pass packs use `celestia_common.metal`. The Iris/OptiFine parser/bridge (`IrisPackParser`, `IrisGlslBridge`) is hidden unless `-Dcelestiametal.irisPacks=true`. Spec: `SHADER_PACK_SPEC.md` (§5 world packs); example: `examples/shaderpacks/celestia-example-world`.
- **CelestiaGlow UI (`src/main/java/dev/celestia/metal/ui/`) & Perf (`dev.celestia.metal.perf`)**: Tabbed video settings, shader pack/option screens, performance engine, and HUD pill.
- **QA**: `tools/qa/` (in-game probe and runner, `docs/QA.md`) and `tools/qa/analyze/` (image measurements).
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

## QA harness

- **Judge looks and frame rate in the village suite**, the default for `shots`, `perf` and `profile`. It is a real plains village on the coast of the QA seed: houses, foliage, docks, shallow water, rain. The floating test pond is a water-only worst case; use it (`pond-*`, `underwater*`, the `frames` descent) only for water-specific work. `celestiaqa.scenes=all` runs every scene.
- Measure on the owner's settings unless told otherwise: `-PqaJvm=celestiaqa.preset=Quality,celestiaqa.renderScale=100`, which is native 3024 × 1744 on the M1 Pro, 12 chunks, Metal 4. Add `celestiaqa.measureFrames=300,celestiaqa.timedPanYaw=0.14` for FPS under a slow pan.
- Modes: `shots` for screenshots, `profile` for Metal 4 pass breakdowns (`-PqaProfile=120`), `perf` for A/B/A GPU timing, `lights` for the light rooms, `packs` for world-pack switching, `scales` for upscaler switching, and `frames` for the pond descent. See [docs/QA.md](docs/QA.md) for options, output locations and Iris reference runs.
- For animated effects (waves, caustics, shafts), capture a burst (`celestiaqa.repeat=40,celestiaqa.repeatTicks=1`). Then measure it, or turn it into a GIF for the owner with `tools/qa/analyze/` (`motion`, `gif`, `stats`, `sharp`, `crop`, `montage`). Stills hide motion direction.
- Read `summary.txt` first and open `review.jpg` when images are needed. Open individual captures only for specific follow-up.
- Keep QA in `build/qa/` so the runner can reuse the compiled Metal pipeline cache and QA world template. Use the Gradle daemon for repeated runs.
- Keep every `/fill` below 32,000 blocks. Compare changed screenshot settles against the 240-tick baseline and preserve the light propagation and performance sampling windows.
- Use only Photon commit `26c2906e` (MIT) for code or assets. Photon v1.4 is a visual reference.

---

## Technical Invariants & Pitfalls

1. **Java 25 FFM (`MetalNative.java`)**:
   - `MethodHandle.invokeExact` is signature-polymorphic at compile time. Never pass an inline ternary (`seg != null ? seg : MemorySegment.NULL`) as an argument — `javac` may infer `Object` instead of `MemorySegment`, triggering `WrongMethodTypeException` at runtime. Always wrap nullable segments in `segOrNull(seg)`.
   - Keep `cm_*` C signatures in `src/main/native/celestia_metal.h`, `FunctionDescriptor`s in `MetalNative.java`, and numeric enums in `MetalConst.java` strictly synchronized.

2. **Byte Order on `MemorySegment.asByteBuffer()`**:
   - `MemorySegment.asByteBuffer()` returns a **`BIG_ENDIAN`** `ByteBuffer` by default on every architecture! Always chain `.order(ByteOrder.nativeOrder())` on any mapped view before handing it to Minecraft/LWJGL or reading/writing floats/ints.

3. **Metal 4 Explicit Synchronization & Residency**:
   - Unlike Metal 3, `MTL4CommandBuffer` has **no automatic inter-encoder hazard tracking**. Whenever adding a Metal 4 render pass, clear encoder, compute dispatch, or dependent blit copy, emit an explicit producer/intra-encoder barrier (`barrierAfterStages:beforeQueueStages:visibilityOptions:MTL4VisibilityOptionDevice` or `barrierAfterEncoderStages:beforeEncoderStages:`).
   - Every blit that reads or writes a resource another blit in the same encoder may touch (all copies, including `cm_blit_copy_buffer_to_texture`) must call `emit_m4_blit_intra_barrier_if_needed` first; see Test 2h.
   - Register every Metal 4 `MTLBuffer` / `MTLTexture` / texture view with `cm_track_allocation(ctx, obj)`, never destroy resources while in flight (use `cm_retire_object`), and keep `MTL4ArgumentTableDescriptor.maxBufferBindCount <= 31`.
   - Guard all Metal 4 API usage with `@available(macOS 26.0, *)` so Metal 3 (macOS 15+) and `-Wall -Werror` stay clean. **Exception:** the hot pass/draw/bind functions in `cm_encoder.m` (from `cm_pass_set_pipeline` on) branch on `ctx.metal4Active` only, which is set exclusively on macOS 26+; keep new Metal 4 calls there behind that flag.
   - Metal 4 uses **one** argument table (`m4VertexArgTable == m4FragmentArgTable`) bound to vertex and fragment stages: write each binding once. Binding caches (`_boundTextures`, `_boundUboAddrV`, `_boundVtxAddr`, `_lastPush*`) are only valid within one render encoder and are reset in `reset_pass_cache`.
   - `CMContext` is `objc_direct_members`: add plain properties only (no KVC/selectors on it).

4. **RenderPearl Backend Contracts**:
   - **Always verify parameter names/order via `javap -v` (`MethodParameters`)** instead of guessing — RenderPearl overloads have non-obvious parameter orderings (for example, `copyBufferToTexture` uses `(dstX, dstY, width, height, mip, slice)` and `multiDraw` uses `(commands, instanceCount, firstInstance, drawCount)`).
   - **Depth PSO pre-warming**: Pre-warm `FMT_D32_FLOAT` unconditionally, and only pre-warm `NO_DEPTH` when `info.depthStencilState() == null` so shaders writing `[[depth(any)]]` never compile against `MTLPixelFormatInvalid`.
   - **Fences & Ring Buffers**: `createFence()` must return the upcoming submit serial (`deviceNextSubmit + 1`) whenever `cm_cmd_has_active` is true, and `awaitCompletion()` must flush an active recording command buffer before waiting.
   - **Primitive Topology**: Handle `TRIANGLE_FAN` natively inside `cm_pass_draw` (`CM_TOPO_TRIANGLE_FAN`) via the grow-only `fanIndexBuffer` with `baseVertex`, without overwriting `ctx.boundIndexBuffer`.

5. **Render Pass Merging & Deferred Clears (`cm_encoder.m`)**:
   - Java ends each RenderPearl pass with `MetalNative.passFinish` (`cm_pass_finish`), a *soft* end: the native encoder stays open so an immediately following pass with identical color/depth views and no clears merges into it. `cm_pass_end` is the *hard* end.
   - `cm_blit_clear_*` are deferred and folded into the next pass's `MTLLoadActionClear` when it targets the same texture (mip 0 / slice 0); anything else flushes them first.
   - Any new native entry point that encodes non-render-pass GPU work (compute, MetalFX, blits, present, submit) **must** call `cm_flush_encoders(ctx)` (or `ensure_blit_encoder`) first, otherwise a soft-ended pass or deferred clear would be reordered. Cover new paths in `tools/test_metal_backend.m` Test 2g.
   - Both are live config toggles (`performance.renderPassMerging` / `performance.deferredClears`, pushed per frame by `CelestiaMetalDevice.applyEncoderOptions`); `-Dcelestiametal.noPassMerge=true` / `-Dcelestiametal.noDeferClears=true` force them off for A/B checks; F3 shows per-frame `Celestia Encoders` counters (`cm_device_stats`).

6. **FFM Hot Path (`MetalNative.Hot`)**:
   - Per-frame downcalls live in the `static final` `MetalNative.Hot` holder so C2 can inline `invokeExact`. Short, non-blocking calls use `Linker.Option.critical(false)`: they must never block on the GPU, upcall into Java, or receive heap segments (use `CelestiaCommandEncoder.Scratch` / direct buffers). Calls that can wait (`cm_pass_begin`, clears, submit, present) stay non-critical.

7. **Presentation (`cm_surface.m`)**:
   - With VSync off and `nonBlocking` on, the render thread must never call `nextDrawable`: frames go into present slots and the serial `presentQueue` owns drawables. Any change to `CAMetalLayer` properties must run on `presentQueue` (`cm_surface_configure` uses `dispatch_sync`) so the layer never changes while that queue is inside `nextDrawable`. Never `dispatch_sync` onto `presentQueue` from code already running on it.

8. **World Render Scale (`WorldRenderScale`, `GameRendererMixin`)**:
   - Between `preparePostEffects` (ordinal 0, inside `shouldRenderLevel`) and `applyPostEffects`, `GameRenderer.mainRenderTarget()` / `hud3DTarget` are the *scaled* targets. Code that must target the full window (GUI, screenshots of the final image, present) runs after the swap back. Anything new that renders the world (native shader packs) must render into `GameRenderer.mainRenderTarget()` during that window, not cache the full-size target.
   - `render()` HEAD and RETURN always restore the full-size targets, so an exception mid-frame cannot leave them swapped.

9. **Buffer Map Synchronization (`CelestiaBuffer.map`)**:
   - Mods are often written against OpenGL, where mapping a buffer for read implicitly waits for GPU writes. Every GPU write into a `CelestiaBuffer` (`copyTextureToBuffer`, `copyToBuffer`, `writeToBuffer`, and any new blit/compute path that writes buffers) must call `markGpuWrite(recordingSerial())` so `map(read = true)` can submit and wait. Keep write-only maps unsynchronized (Minecraft's ring buffers rely on fences instead).

10. **World packs (`ShadeShaderPatcher`, `CelestiaShade.reloadShaders`)**:
   - Load world MSL only through `ShadeShaderPatcher.resource(name)`, never from a fixed path, so the active pack's file wins. Layouts Java writes go in `shaders/engine/shade_api.metal` (engine-owned, not overridable); keep it in sync with `ShadeFrame`/`ShadeLook`/`ShadeWater.packParams`.
   - Anything new that compiles world MSL must rebuild when `ShadeShaderPatcher.epoch()` changes: own it from `CelestiaShade` (closed and re-initialised by `reloadShaders`) or check the epoch as `CelestiaPipeline` does. GPU state that converges over frames goes in `ShadeGpu` (carried across rebuilds).

11. **Privacy Check (`checkPrivacy`) & Workspace Boundaries**:
   - `./gradlew check` scans tracked files and non-native resources to ensure no machine-specific home directory paths or local OS usernames are committed. Always use `~/` or environment variables in docs and scripts.
   - Do not modify external user launcher instances (e.g., PrismLauncher `mods/` or `options.txt`); only inspect logs/crash reports read-only when debugging user reports.

---

## Workflow Tips

- **UI changes**: Respect `CelestiaTheme` palette/glass tokens, distribute tab/footer widths proportionally (`CelestiaWidgets.computeProportionalWidths`) so narrow/HiDPI windows never clip, and avoid instant viewport-mutating actions during slider drags.
- **Shaders**: Keep native MSL packs fast-path and self-contained per `SHADER_PACK_SPEC.md`. When extending shader integration into `LevelRenderer`, verify compilation on all presets via `tools/test_metal_backend.m`.
- **When fixing a backend or FFM bug**: Add a deterministic regression assertion in `tools/test_metal_backend.m` (runs on both Metal 4 and Metal 3) and/or `NativeFfmSmokeTest.java` before packaging a release.
