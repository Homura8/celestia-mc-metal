# Changelog

## 0.1.0-alpha.21

### Added
- **P6a dynamic lights**. Held light sources, glowing and burning mobs, dropped light items, projectiles and other moving sources now light nearby terrain, water and entities. Walls block the light: each of the nearest lights gets a 32³ visibility volume, traced from a block occupancy map around the camera or flood-filled around corners where the GPU supports it. A 96×64×96 irradiance volume carries the light into terrain and water shading. Lights fade in and out, and fire-like sources flicker.
- New Lighting & Shadows options: Dynamic Lights, Dynamic Light Strength, Dynamic Light Count (16 on Performance, 32 on Balanced, 48 on Quality, 64 on Ultra), and Lights From Entities. They apply live. With Dynamic Lights off, the module releases its buffers and does no per-frame work.
- F3 shows the per-frame light count in the Celestia shader status line.
- Native Test 2q checks the zeroed fallback bindings, unoccluded irradiance, ray and flood-fill visibility behind a wall, and the shading read through buffer 29 and textures 24–25 on Metal 4 and Metal 3.

### Changed
- Native ABI 8 adds the `cm_dl_*` entry points. Buffer slot 29 now carries the dynamic lights, replacing the unused bloom slot.

## 0.1.0-alpha.20

### Added
- **P5 live shader settings**. Celestia Native exposes 34 controls across lighting and shadows, sky, water, clouds and weather, and post-processing. The Performance, Balanced, Quality, and Ultra presets apply without restarting Minecraft.
- Presets adjust shadow resolution, update interval and range, SSR budget and range, cloud and volumetric light sample counts, and other settings. Individual options and custom combinations persist locally.

### Changed
- The bundled Celestia Native entry now configures the active world shader suite. Existing Celestia Minimal selections migrate to the Performance preset. The legacy samples remain available as native test fixtures.
- Disabling bloom preserves the luminance samples used for auto-exposure. Turning off animated waves skips the wave and ripple bakes.

## 0.1.0-alpha.19

### Added
- **P4 TAAU**. Select TAAU in Upscaler with Internal Render Scale below 100%. Halton jitter, camera reprojection, depth rejection and neighborhood clipping reconstruct the world at output resolution. The depth written by the first-person hand rejects temporal history at held-item pixels. The 2D HUD draws at native resolution.
- **Screen-space ambient occlusion**. Half-resolution depth sampling adds contact shading to the Overworld, with depth-aware compositing to limit bleeding across silhouettes.
- **Bloom and tone mapping**. Reject non-finite color components before the bloom downsample and display conversion.
- Native GPU checks cover the SSAO plane and TAAU history blending, disocclusion, hand rejection and full-size output on Metal 4 and Metal 3.

## 0.1.0-alpha.18

### Added
- **P3b volumetric atmosphere**. Ray-marched clouds follow Minecraft's Off, Fast and Fancy cloud settings. A low-resolution cloud buffer shades the sky and a separate dome supplies off-screen water reflections. Quarter-resolution volumetric light marches the two shadow cascades and uses depth-aware upsampling during HDR compositing.
- **Surface weather**. Rain darkens exposed terrain, accumulates puddles, and adds raindrop ripples to water. Snow accumulates on open horizontal surfaces. Nearby lightning lights the sky and terrain and respects Hide Lightning Flashes.
- Native Test 2o exercises cloud lighting and transmittance, atmospheric light, baked weather noise, and HDR compositing on Metal 4 and Metal 3.

### Performance
- **Water**. Added an above-water shader variant and isolated glossy non-water shading. SSR shares coarse depth traversal across 2×2 quads and refines the hit per pixel. Above-water rays travel up to 144 blocks and fade to sky reflections on distant surfaces. The hierarchical SSR budget defaults to 24 intervals and accepts an optional `-Dcelestiametal.shade.water.ssrBudget=16` for comparison.
- Tiled waves now bake at 512². Detail ripples use seven wave trains, and mipmaps for all three textures share one encoder. Frames after a missed translucent capture reuse the last bake. Sea swell skips underwater bakes and fades out between 112 and 176 blocks.
- Native ABI 7 batches the optional wave, ripple and swell textures in a single mipmap call.

### Verified Performance
- **Owner beach overview, Vanilla 26.3, M1 Pro, Metal 4, 3024×1752**. **82 FPS** and **13.47 ms GPU** with Water SSR, Clouds and Volumetrics active.
- **Sodium 0.9.3-beta.1, M1 Pro, Metal 4, 3024×1742 pond fixture**. Sunset close-up improved from **46.06 to 34.19 ms** GPU with 24 SSR intervals and measured **29.57 ms** at 16. Underwater looking up improved from **11.31 to 10.68 ms** at 24 intervals.
- Vanilla 26.3 rendered the same water and weather scenes on Metal 4. Native Tests 2n and 2o passed on Metal 4 and Metal 3.

## 0.1.0-alpha.17

### Added
- **Native MSL Shader Suite Port — Phase P3a (`dev.celestia.metal.shade.water.*`)**:
  - **Realistic Water & Screen-Space Reflections (`water.metal`, `shade_water_terrain.metal`, `cm_water.m`, `CM_ABI_VERSION 6`)**:
    - Captures opaque world color + depth (`cm_water_capture`) when the main pass switches to translucent terrain (reopening with `MTLLoadActionLoad` so sky/terrain/entities stay intact) and builds a hazard-free 3-pass `RG16Float` hierarchical depth pyramid (`shade_water_pyr_fs` / `shade_water_pyr2_fs`) for exact SSR tracing.
    - Bakes mipmapped tiled wave (`1024×1024` `RGBA16Float`), fine-ripple detail (`256×256` `RGBA16Float`), and bi-frame open-sea swell (`256×256` `RGBA16Float`) textures with native `generateMipmapsForTexture` (`cm_water_generate_mipmaps`), plus previous-frame `RGBA16Float` HDR world history (`ShadeResources.prevScene`) for SSR hit colors and reflected sky/sun/stars.
    - Implements directional flowing water waves, Schlick Fresnel, depth-based Beer-Lambert underwater absorption, refraction, shoreline foam, animated bottom caustics, underwater Snell's window & TIR reflections (`WaterFrame.surfaceAbove`), and glossy dielectric reflections (`shadeGlossy`) for stained glass/ice/slime/honey.
    - **Sodium 0.9.x + Vanilla 26.3 support without hard Sodium dependency**: `ShadeShaderPatcher` patches both `minecraft:pipeline/translucent_terrain*` (excluding `oit`) and `sodium:pipeline/translucent_terrain`, extracting `minecraft:block/water_still` & `water_flow` atlas UV rectangles in `WaterFrame`.
    - Updated F3 `Celestia Shade:` status line (`P3a HDR ... | Water SSR`).
    - Added `ShadeP3aTest` (JUnit 5 + FFM) and native **Test 2n** (mid-pass scene+depth capture, 3-pass `RG16Float` depth pyramid, wave/detail/swell bake + mipmaps, reopened pass load-action preservation) plus 3024×1752 synthetic P3a water prep GPU benchmark in `tools/test_metal_backend.m` across Metal 4 and Metal 3.

### Verified Performance (Apple M1 Pro, 3024×1752 native, Metal 4)
- **In-game (Vanilla 26.3 terrain + Xaero's Minimap)**:
  - Beach day overview (`elev 25 deg`, `109k/821k q`): **77 FPS** (`14.10 ms` GPU)
  - Beach twilight (`elev -5 deg`, `146k/793k q`): **62–63 FPS** (`16.62–16.84 ms` GPU)
  - Sunset water close-up (waves + SSR): **43 FPS** (`23.30 ms` GPU)
  - Underwater looking up (Snell's window + TIR, `elev 29 deg`, `106k/1032k q`): **33 FPS** (`26.51 ms` GPU)
  - Visuals verified: animated ocean waves, SSR shoreline/tree/reed reflections, twilight/sky reflection, shoreline depth absorption, and underwater Snell's window + kelp TIR refraction. Known optimization follow-ups: register-pressure split (`SHADE_COLD` / above-water lean specialization + isolating non-water `shadeLit2`/`shadeGlossy`), lowering default `WAVE_SIZE` (`1024²` -> `512²`) and batching mipmap blits, skipping wave bakes on non-water frames, and tuning `SHADE_SSRH_BUDGET`.
- **Synthetic P3a Water Prep (`tools/test_metal_backend.m` @ 3024×1752, 1024² waves + 256² ripples/swell + mipmaps + scene/depth copy + 3-pass `RG16Float` pyramid)**: **1.993 ms** GPU (Metal 4) / **1.691 ms** GPU (Metal 3).

## 0.1.0-alpha.16

### Added
- **Native MSL Shader Suite Port — Phase P2 (`dev.celestia.metal.shade.shadow.*`)**:
  - **2-Cascade Sun/Moon Shadow Maps (`2048×2048×2` `Depth16Unorm` default, configurable via `-Dcelestiametal.shade.shadowRes` / `-Dcelestiametal.shade.shadowDepth=32`)**:
    - Implemented stable texel-snapped orthographic cascade fitting (`ShadowCascade`) with reversed-Z depth (`MTLCompareFunctionGreaterEqual`), depth clamping/pancaking (`MTLDepthClipModeClamp`), slope-scaled raster bias, adaptive sun angle quantization near the horizon, near cascade (32-block half-width shifted 40% ahead, updated every frame) and far cascade (128-block half-width updated every 4 frames or on camera/sun step).
    - **Sodium 0.9.x + Vanilla 26.3 support without hard Sodium dependency**: `SodiumShadowCasters` uses cached `MethodHandle` reflection to pull Sodium's compact 20-byte section vertices with per-facing culling and zero Sodium compile/link dependency; `VanillaShadowCasters` reads vanilla `ViewArea` + `SectionRenderDispatcher` 28-byte block vertices (`DefaultVertexFormat.BLOCK`).
    - Added native `cm_shadow_render_sodium` and `cm_shadow_render_vanilla` encoders (`src/main/native/cm_shadow.m`, `CM_ABI_VERSION 5`) supporting both Metal 4 (`MTL4RenderCommandEncoder` + explicit producer barriers) and Metal 3, encoded cleanly before `FrameGraphBuilder.execute` via `ShadeLevelRendererMixin` so main-pass encoder merging stays intact.
    - Updated F3 `Celestia Shade:` diagnostic line with live shadow resolution, active caster backend (`Sodium` / `Vanilla`), and near/far quad counts.
    - Added `ShadeP2Test` (JUnit 5 + FFM) and native **Test 2m** (2-cascade Vanilla + Sodium depth render & `sample_compare` verification) plus 2048×2048 P2 shadow cascade GPU benchmark in `tools/test_metal_backend.m` across Metal 4 and Metal 3.

### Fixed
- **Vanilla chunk upload `/ by zero` crash at transient block boundaries**: `CelestiaTransientMemory` and `CelestiaCommandEncoder.writeToBuffer` passed `0L, 0L` instead of `(minimumAllocation, step)` (`size, 1L`) into RenderPearl's `TransientBlockAllocator.allocate(...)`, triggering `ArithmeticException: / by zero` (`line 128`) whenever a 4 MiB shared transient block filled mid-frame during large initial vanilla section uploads. Fixed across all allocation paths and covered by `ShadeP2Test.transientBlockAllocatorBoundaryDoesNotDivideByZero`.

### Verified Performance (Apple M1 Pro, 3024×1752 native, Metal 4)
- **In-game (Sodium 0.9.4-beta.2 + Xaero's Minimap)**:
  - Day (`elev 24 deg`): **124 FPS** (`9.40 ms` GPU, `73k/419k q`)
  - Sunset (`elev 3 deg`): **97 FPS** (`11.87 ms` GPU, `102k/385k q`)
  - Night (`elev -34 deg`): **101 FPS** (`10.84 ms` GPU, `61k/421k q`)
- **In-game (Vanilla 26.3 terrain + Xaero's Minimap, no Sodium)**:
  - Day: **103 FPS** (`10.92 ms` GPU)
  - Sunset (`elev 2 deg`): **86–89 FPS** (`12.19 ms` GPU, `36k/343k q`)
  - Twilight: **90 FPS** (`11.42 ms` GPU)
- **Synthetic P2 Shadow Cascade Benchmark (`tools/test_metal_backend.m` @ 2048×2048 `D16`, 50k quads)**: **0.285 ms** GPU (Metal 4) / **0.321 ms** GPU (Metal 3).

## 0.1.0-alpha.15

### Added
- **Native MSL Shader Suite Port — Phase P1 (`dev.celestia.metal.shade.*`)**:
  - Ported the core HDR sky/atmosphere/bloom/auto-exposure/tonemapping pipeline from [Minecraft Metal Shaders](https://github.com/GaelQuinta/minecraft-metal-shaders) (`mcopt-shade`, Apache-2.0) onto Celestia's RenderPearl Metal 4 / Metal 3 backend (`src/main/resources/assets/celestiametal/shaders/ported/` and `src/main/native/cm_shade.m`).
  - **Both vanilla terrain and Sodium 0.9.x terrain work identically** without adding a Sodium dependency or loading Sodium classes (`ShadeShaderPatcher` inspects translated MSL signatures directly and supports both `UV2 / 240.0` vanilla lightmaps and `(a_LightAndData.xy - 8.0) / 240.0` Sodium lightmaps).
  - **HDR World Frame + Post Chain (`CelestiaShade`)**: Redirects world passes inside `WorldRenderScale` to an `RGBA16Float` HDR target (`ShadeFrame` 1024 B + `ShadeLook` 1136 B in 4-slot rings, `ShadeGpu`, `ShadeResources`), renders a 128×80 `RGBA16Float` Sky LUT (`sky_lut.metal`), replaces overworld sky/celestial/stars/sunrise/clouds stages, lights entities/items/blocks/particles/hand (`shade_entity.metal`), runs 6-level `RG11B10Float` bloom (`shade_bloom_down0` / `down` / `up`), GPU histogram + temporal exposure adaptation (`shade_histogram` + `shade_exposure`), and Lottes filmic tonemapping (`shade_final`) back into `mainRenderTarget` before GUI overlays and Xaero's Minimap draw.
  - Added F3 `Celestia Shade:` diagnostic line (`DebugScreenEntriesMixin`), flattened vanilla directional face shading during active P1 shading (`ShadeFaceShadeMixin`), and `CM_ABI_VERSION 4` (`cm_shade_*` C ABI).
  - Added `ShadeP1Test` (JUnit 5 + FFM) and native Test 2l + 3024×1752 synthetic P1 HDR post benchmark in `tools/test_metal_backend.m` across Metal 4 and Metal 3.

### Verified Performance (Apple M1 Pro, 3024×1752 native, Metal 4)
- **In-game (Sodium 0.9.4-beta.2 + Xaero's Minimap, 0 warnings/fallbacks)**:
  - Day (`elev 25 deg`): **144 FPS** (`8.37 ms` GPU)
  - Sunset (`elev 3 deg`): **101 FPS** (`10.27 ms` GPU)
  - Night (`elev -24 deg`): **115 FPS** (`9.92 ms` GPU)
  - Shaders toggled off (`K`): **356 FPS** (`4.06 ms` GPU)
- **Synthetic P1 HDR Post-Only Benchmark (`tools/test_metal_backend.m` @ 3024×1752)**: **1.754 ms** GPU (Metal 4) / **1.709 ms** GPU (Metal 3).

## 0.1.0-alpha.14

### Added
- **World render scale (Internal Render Scale / Auto Render Scale now work)**: these settings previously had no effect. The 3D world (vanilla and Sodium terrain, entities, post effects, entity outlines, the first-person hand) now renders into a scaled target and is upscaled into the full-size main target right before the GUI, so the HUD, chat, F3 and mod overlays such as Xaero's minimap stay at full resolution. `GameRendererMixin` swaps `GameRenderer.mainRenderTarget` / `hud3DTarget` from just before `preparePostEffects` until after `applyPostEffects`; `WorldRenderScale` owns the scaled targets, replays the frame clear onto them and keeps the level renderer's targets at the scaled size. Auto Render Scale (65%–max, driven by GPU frame time) now acts on it. This scaled target is also where native shader packs will render.
- **Upscalers**: `cm_upscale_to` with a bilinear pass or **MetalFX Spatial** (`MTL4FXSpatialScaler` on Metal 4, `MTLFXSpatialScaler` on Metal 3, written to an intermediate with the usage MetalFX requires and copied into the main target behind Metal 4 consumer/producer barriers); falls back to bilinear if MetalFX is unavailable. *MetalFX Temporal* currently uses Spatial (temporal needs motion vectors and jitter, planned with native shader packs).
- **Auto Render Scale only keeps a step that helps**: each step down is held for 90 frames and reverted if the frame did not get at least 3% faster, with a 15 s back-off before trying below that scale again (adapted from Pure Metal's Auto Render Scale behaviour). Needed because the upscaler has a fixed cost: measured ~2.0 ms GPU for MetalFX Spatial and ~0.7 ms for bilinear into 3024x1752 (`benchmark_upscale`), so on light (non-shader) scenes a lower scale can be slower. In-game on M1 Pro with Xaero's minimap: 100% 260 FPS, 75% 200 FPS, 50% 210 FPS with MetalFX Spatial. Render scale is meant for heavy scenes and shader packs; defaults stay 100% with Auto off.
- F3 shows the active upscale path and internal size (e.g. `Scale 75% (MetalFX Spatial 2268x1314)`).
- Native Test 2k (bilinear and MetalFX Spatial upscale: orientation, coverage, path used) on Metal 4 and Metal 3.

## 0.1.0-alpha.13

### Performance
- **Per-draw CPU overhead cut by ~33–47%** (new `benchmark_draw_overhead` in `tools/test_metal_backend.m`, 2000 draws on M1 Pro):

  | CPU per draw | Metal 4 before → after | Metal 3 before → after |
  |---|---|---|
  | draws only | 0.111 → 0.063–0.078 µs | 0.099 → 0.052 µs |
  | + push constants + UBO offset (Sodium-like) | 0.459 → 0.26 µs | 0.298 → 0.204 µs |
  | + texture switches (Xaero-like) | 0.493 → 0.285 µs | 0.326 → 0.218 µs |

- **One Metal 4 argument table for both render stages**: bindings are written once instead of twice, and the driver snapshots one table per draw instead of two.
- **Direct `CMContext` properties** (`objc_direct_members`): no `objc_msgSend` for the context state read on every draw/bind call.
- **No per-call `@available` checks** in the hot pass/draw/bind functions (`metal4Active` already implies macOS 26).
- **Push-constant dedup**: identical consecutive push constants reuse the already-bound bytes (Metal 4).
- **Java uniform dirty tracking**: `CelestiaRenderPass` only re-sends uniforms whose value changed since the last `setPipeline`, instead of every uniform on any change.

### Fixed
- **Fence polls blocked in the kernel**: profiling showed ~10% of the render thread in `waitSubmit` from Minecraft's `StagedVertexBuffer` polling fences with a zero timeout every frame. A zero-timeout `cm_wait_submit` now only reads `signaledValue`, `CelestiaFence` returns early for already-completed serials, and retired objects are only drained when the completed serial advances (not on every poll).
- **Crash when the window/surface is destroyed mid-stream** (non-blocking present, alpha.12): libdispatch traps when a semaphore is released below its initial value; the present-slot semaphore is now created at 0 and filled to the pool size. Reproduced in 2 of 5 native test runs before the fix, 0 of 11 after.
- **Present slots leaked on resize** (alpha.12): `cm_surface_configure` and `cm_surface_destroy` dropped a frame waiting for the screen without returning its slot, so each resize that landed while a frame was waiting shrank the pool; after a few resizes every frame could hit a 50 ms slot-wait timeout.

### Added
- Native Test 2j (push-constant dedup correctness, including a new encoder after identical bytes; fails with a naive dedup).
- F3 `Celestia CPU waits` line: milliseconds per second the render thread blocks on the in-flight frame cap, fences, and present slots.
- Test 2i now also resizes repeatedly while frames are in flight and tears the surface down with frames still queued.

## 0.1.0-alpha.12

### Performance
- **Non-blocking presentation with VSync off** (`cm_surface_set_nonblocking`, on by default): profiling showed the render thread spending about half of every frame blocked in `CAMetalLayer.nextDrawable`, capping the frame rate near twice the display refresh rate (~237 FPS on a 120 Hz panel) while the GPU sat 35% idle. Each frame is now rendered into one of four present slots in its own command buffer, and a serial present queue, woken by an `MTLSharedEventListener` when the GPU finishes, copies the newest finished frame into a drawable. At most two presents wait to be shown; until one is, a newer finished frame replaces the waiting one (MAILBOX semantics, no tearing). VSync-on presentation is unchanged. Approach adapted from Pure Metal's present credits / present queue.

### Added
- **Non-Blocking Present** toggle (Advanced tab and Sodium's Celestia Metal page, `appleSilicon.nonBlockingPresent`), applied live; `-Dcelestiametal.blockingPresent=true` forces the previous behaviour.
- F3 `Celestia Present` line: frames rendered, shown on screen, and dropped per second.
- Native Test 2i (non-blocking present: acquire never blocks, frames flow without on-screen feedback, reconfigure / mode switch / teardown).

### Changed
- Native ABI bumped to `CM_ABI_VERSION 3`; `CAMetalLayer.framebufferOnly` is now `NO` so the present queue can blit into drawables.

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
