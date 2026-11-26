# Celestia Metal Architecture

Celestia Metal is organized into five cleanly separated layers packaged into a single Fabric JAR (`build/libs/celestia-metal-*.jar`).

---

## 1. Native Metal 4 / Metal 3 Engine (`src/main/native/`)

Compiled at build time into `natives/macos-arm64/libcelestiametal.dylib` (`-fobjc-arc -O2 -arch arm64 -Wall -Werror`) and loaded on startup via Java 25's `java.lang.foreign` FFM API (`MetalNative.java`).

| File | Responsibility |
| --- | --- |
| `celestia_metal.h` | Shared C ABI enums (`CMFormat`, `CMCompareFunc`, `CMBlendFactor`, `CMBlendOp`, `CMTopology`), `CMContext` state, and exported symbols. |
| `cm_device.m` | Apple7+ GPU probe, ProMotion refresh rate / EDR headroom / macOS thermal & Low Power Mode telemetry, Metal 4 (`MTL4CommandQueue`, `MTL4Compiler`, `MTLResidencySet`, 4-slot `MTL4CommandAllocator` ring, `MTL4ArgumentTable`) + Metal 3 fallback, `MTLBinaryArchive` disk persistence, and deferred object retirement. |
| `cm_resources.m` | Unified-memory `MTLStorageModeShared` buffers, private GPU textures/views, comparison & anisotropic samplers, `MTL4Compiler` / `MTLDevice` MSL compilation, and `MTLRenderPipelineState` / `MTLComputePipelineState` creation with binary archive caching. |
| `cm_encoder.m` | Unified command encoding for Metal 4 (`MTL4CommandBuffer`, `MTL4RenderCommandEncoder`, `MTL4ComputeCommandEncoder` blits/barriers) and Metal 3 (`MTLCommandBuffer`, `MTLRenderCommandEncoder`, `MTLBlitCommandEncoder`), explicit producer/intra-blit barriers, `cm_cmd_has_active` fence tracking, native state-cache deduplication, push-constant ring buffer, grow-only native `CM_TOPO_TRIANGLE_FAN` index buffer, and batched `multiDraw` / `multiDrawIndexed` / indirect draws. |
| `cm_surface.m` | `CAMetalLayer` swapchain setup (SDR `BGRA8Unorm` and HDR/EDR `RGBA16Float` Extended Linear Display P3), `displaySyncEnabled` VSync toggle, Y-flip present shader, and Metal 4 `waitForDrawable` / `signalDrawable` synchronization. |
| `cm_upscaler.m` | `MTL4FXSpatialScaler` / `MTL4FXTemporalScaler` (Metal 4) and `MTLFXSpatialScaler` / `MTLFXTemporalScaler` (Metal 3) wrappers. |
| `cm_shader_runtime.m` | Compute dispatch (`MTLStageDispatch` producer barrier) & pass-graph helpers for native MSL shader packs. |

### Metal 4 Lifetime, Barriers & Residency Discipline
- Every buffer, texture, view, and shared `fanIndexBuffer` created while `metal4Active == YES` is immediately registered with the queue's `MTLResidencySet` under an `os_unfair_lock`, and `residencySet` is committed before command submission whenever dirty.
- Explicit Metal 4 producer barriers (`barrierAfterStages:beforeQueueStages:visibilityOptions:MTL4VisibilityOptionDevice`) are emitted before `endEncoding` across render passes (`cm_pass_end`), clear encoders (`cm_blit_clear_color`, `cm_blit_clear_depth`, `cm_blit_clear_color_depth`), blit passes (`cm_end_blit_if_active`), and compute dispatches (`cm_compute_dispatch`), alongside intra-blit `MTLStageBlit` barriers before texture read/copy commands.
- Destroyed GPU resources are never freed while in flight; they are appended to a retirement queue tagged with `nextSubmitSerial + 1` and released/untracked only once `MTLSharedEvent.signaledValue` reaches that serial. Fences created via `createFence()` track `nextSubmitSerial + 1` when `cm_cmd_has_active` reports an open command buffer and flush before waiting.

---

## 2. Java RenderPearl Backend (`dev.celestia.metal.backend`)

Plugs directly into Minecraft 26.3's `com.mojang.renderpearl` abstraction via `PreferredGraphicsApiMixin` (which prepends `CelestiaMetalBackend` when Graphics API is `Default`).

- **SPIR-V → MSL 3.1 Translation (`MetalShaderTranslator`)**: Uses LWJGL `org.lwjgl.util.spvc.Spvc` to cross-compile RenderPearl SPIR-V modules to MSL with vertex Y-flip, explicit slot bindings (buffers `0..14`, push constants `15`, vertex buffers `16..23`, textures `0..30`, samplers `0..15`), and selective fast-math for terrain pipelines.
- **Unified-Memory Transient Allocator (`CelestiaTransientMemory`)**: Allocates 4 MB `MTLStorageModeShared` blocks rotated on submit completion with zero staging copies.
- **Size-Bucketed Buffer Pool (`CelestiaMetalDevice`)**: Pools closed buffers by power-of-two bucket up to 256 MB total and reuses them only after their last referencing submit serial has completed.
- **Crash Isolation (`StartupGuard`)**: Writes a lightweight lock file while attempting Metal startup; clears it on `Minecraft.onGameLoadFinished`.

---

## 3. Performance & Telemetry Engine (`dev.celestia.metal.perf`)

- `CelestiaConfig`: JSON config (`config/celestia-metal.json`) with atomic writes and validated bounds.
- `PerformanceEngine`: Tracks EWMA CPU & GPU frame times, 1% low FPS, polls macOS thermal state / Low Power Mode / ProMotion Hz every 2 seconds, adjusts **Auto Render Scale** with hysteresis, and detects Sodium automatically so no redundant terrain hooks interfere.
- `PerformanceHud`: Top-left CelestiaGlow frosted pill overlay (`Off` / `Compact` / `Detailed`), auto-hidden when F1 or F3 is open.

---

## 4. Shader Pack System (`dev.celestia.metal.shader`)

- **Native MSL Packs (`dev.celestia.metal.shader.pack`)**: Reads `celestia-shader.json` manifests from bundled classpath resources or `shaderpacks/` directories/ZIPs, generates deterministic `#define` preludes from user options, compiles with `celestia_common.metal` via `MTL4Compiler`/`MTLDevice`, and records non-fatal diagnostics on errors.
- **Iris / OptiFine Bridge (`dev.celestia.metal.shader.iris`)**: `IrisPackParser` parses `shaders.properties`, `en_us.lang`, and `#define` option comments into the unified option model (persisting to standard Iris `.txt` files), while `IrisGlslBridge` translates GLSL → SPIR-V → MSL via LWJGL `Shaderc` + `Spvc` on demand.

---

## 5. CelestiaGlow UI (`dev.celestia.metal.ui`)

- `CelestiaTheme` & `CelestiaWidgets`: Frosted dark violet-slate surfaces (`#211e30`, `#2e283f`, `#302a3d`), 1px glass rims (`0x2EEDDEFF`), lavender accents (`#c8b3e4`, `#e0cdef`), and `✦` starlight motifs.
- `CelestiaVideoSettingsScreen`: Tabbed & searchable replacement for `VideoSettingsScreen` (with a fallback button in `Advanced` to open Vanilla Video Settings if needed).
- `CelestiaShaderPacksScreen` & `CelestiaShaderOptionsScreen`: Unified pack selector (`Off`, `✦ Native MSL`, `Iris / GLSL`), preset switcher, hot-reload, and categorized option editor.

---

## Roadmap for Upcoming Alpha Releases

1. **Remaining Hot-Path Work** (render pass merging, deferred clears, `static final` critical FFM handles, scratch memory, packed multi-draws, and Metal 4 address dedup landed in `0.1.0-alpha.11`):
   - Cache `TEXEL_BUFFER` texture views across passes instead of creating/retiring one per pass.
   - Accumulate GPU timestamps across all command submissions within a frame so the Performance HUD pill reports true total GPU work alongside CPU frame time.
2. **In-Game G-Buffer & Shadow Injection Hook**: Patch live `LevelRenderer` terrain/entity/water passes to populate `gAlbedo` / `gData` / `waterMask` and execute the 2-cascade shadow pass directly inside the active world frame so `Celestia Native` and `Celestia Minimal` render live in-world.
3. **Iris Full Frame-Graph Executor**: Extend `IrisGlslBridge` from shader/option parsing & translation to full multi-pass deferred/composite/shadow execution for third-party Iris packs.
4. **Terrain Indirect & Distant LOD Mesher**: Optional standalone chunk mesh arena & GPU frustum/Hi-Z culling when running without Sodium.
