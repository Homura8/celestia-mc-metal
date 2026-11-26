# Handoff Plan: Port Metal Shaders' MSL suite onto Celestia Metal

Audience: the next agent picking this up. Read `AGENTS.md` first (build/test commands, invariants), then this file.

## 0. Goal and constraints

Port the native MSL shading of **[Metal Shaders](https://github.com/GaelQuinta/minecraft-metal-shaders)** (GaelQuinta,
Apache-2.0, a fork of mcopt) onto Celestia Metal's RenderPearl backend, optimising where possible.

Hard requirements (from the project owner):
- **Sodium must stay optional.** Everything must work with vanilla terrain alone *and* with Sodium 0.9.x installed.
- Stay compatible with gameplay/map mods (e.g. Xaero's Minimap + World Map are in the owner's test instance).
- Performance-first, Metal-native MSL. Iris/OptiFine GLSL pack support is explicitly **not** a goal for now.
- Single-JAR, no extra setup, Apache-2.0 attribution kept correct.

Licensing: Metal Shaders is Apache-2.0 (same as us). Keep its `NOTICE` text, add a per-file header
`// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): <original path>` on every ported file, and update `NOTICE` +
`CREDITS.md`. Some of their files are under `LICENSES/MIT-Photon.txt` (MIT, Photon): keep that license file and header
for those. Mine2Metal (HoshizoraAkira, MIT) is a secondary source (voxel shadows, G-buffer patch idea); same treatment.

## 1. Current state of Celestia (as of 0.1.0-alpha.14)

- `main` has alpha.13 (merged PR #5). **alpha.14 (world render scale) is on branch `feat/render-scale-alpha.14` with an
  open PR**; make sure it is merged before starting P1 (`./gradlew clean build check runNativeTests` passes on it).
- Test machine: M1 Pro, 3024x1752, macOS 27, Metal 4. In-game (beach scene, Sodium, Xaero minimap on): ~260 FPS,
  GPU-bound at ~2.9 ms/frame with minimap off (~350 FPS). CPU encoding is no longer the bottleneck.
- Relevant infrastructure that already exists:
  - **World render scale** (`dev.celestia.metal.render.WorldRenderScale`, `GameRendererMixin`): between
    `preparePostEffects` (ordinal 0) and `applyPostEffects`, `GameRenderer.mainRenderTarget()` / `hud3DTarget` are a
    *scaled* target; afterwards `cm_upscale_to` (bilinear ~0.7 ms or MetalFX Spatial ~2.0 ms at 3024x1752) writes the
    full-size target, then the GUI draws. **Shader packs must render the world into `mainRenderTarget()` inside that window.**
  - Native backend: `src/main/native/*.m`, C ABI in `celestia_metal.h` (ABI 3), Java FFM in `MetalNative.java`
    (`Hot` holder for per-frame calls; `critical(false)` only for non-blocking calls).
  - Pipeline creation: `CelestiaPipeline` + `MetalShaderTranslator` (SPIR-V -> MSL via SPIRV-Cross). Slot model:
    uniform buffers 0-14, push constants 15, **vertex buffers 16-23**, textures 0-30, samplers 0-15.
    Metal 4 uses ONE argument table for vertex+fragment (`maxBufferBindCount = 31`, so buffer slots 24-30 are free).
  - Render pass merging + deferred clears (`cm_pass_finish`), non-blocking present, per-frame F3 counters
    (`Celestia Encoders`, `Celestia Present`, `Celestia CPU waits`).
  - Existing placeholder packs `celestia-native` / `celestia-minimal` (+ `ShaderPipelineManager`, `celestia_common.metal`,
    `SHADER_PACK_SPEC.md`) compile but **never render in-world**. They are superseded by this port; keep the
    pack/options UI (`CelestiaShaderPacksScreen`, `CelestiaShaderOptionsScreen`) and point it at the ported pack.

## 2. What Metal Shaders does (read these in their repo)

Shaders: `metal/src/main/resources/mcopt/shade/*.metal` (~40 files): `shade_common`, `shade_m2` (shading model,
`shadeLit2`), `shade_look` (look/tonemap params), `shade_entity`, `shade_shadow`/`shadow`, `sky_lut`, `sky.*`, `clouds*`,
`vl` (god rays), `water`, `weather*`, `colorlight`, `dynlight*`, `aurora`, `taa`, `shade_post`, `motion_blur`,
`terrain_own` (their own terrain renderer's shading), `vanilla_uniforms`.
Java: `metal/src/main/java/mcopt/metal/shade/**` (ShadeMsl, ShadeEntity, ShadePost, ShadeLook, taa/, vl/, shadow/ ...).
Design docs (very detailed, read before porting each module): `docs/dev/BASE.md`, `SHADOW.md`, `WATER.md`, `CLOUDS.md`,
`VL.md`, `TAAU.md`, `DYNLIGHTS.md`, `SKYDIMS.md`, `WEATHER.md`, `OPTIMIZATION_LOG.md`, `M2_INTEGRATION.md`.

Key architectural facts:
- **Forward shading in the terrain fragment shader** (not a fat G-buffer): terrain/entity pipelines get MSL replaced
  (`ShadeMsl.FORMAT_ADAPTER`, per-pipeline fragment patching) and write HDR radiance; full-screen passes add sky, clouds,
  god rays, water, post. Their early milestones (M1-M3) did this on **Sodium's** terrain pipeline
  (`sodium_terrain.fs.metal`), so it is not inherently tied to mcopt's own terrain renderer.
- Shared per-frame data: `ShadeFrame` / `ShadeLook` uniform structs and a `ShadeResources` argument buffer at
  **buffer(19)**. **Conflict:** our vertex buffers occupy 16-23. Remap their resource slots to 24-30 (or move them into
  an argument buffer at one free slot) when porting.
- **Sun shadows**: 2-cascade depth array (near every frame, far every 4 frames / on sun step / big camera move), stable
  texel-snapped fitting, sun-facing faces only, alpha-tested near cutout. Casters come from **reading Sodium's section
  render data directly** (`SectionRenderDataStorage`, per-facing vertex ranges) and replaying them from the light.
  `MetalDrawTap` = their backend hook to observe/redirect draws.

## 3. Architecture for Celestia (renderer-agnostic)

1. **Pipeline shading substitution in the backend** (renderer-agnostic): in `CelestiaPipeline.compileAsync`, identify
   terrain/entity/item/particle pipelines by *their shader identity* (SPIR-V/GLSL source hash + entry points, like Pure
   Metal's `TerrainShaderProof`, not just the pipeline name) for both vanilla `minecraft:core/terrain*`, `core/entity`,
   `core/item`, `core/particle` and Sodium's `sodium:blocks/block_layer_opaque` (and its cutout/translucent variants).
   Compile the ported MSL variant instead, with a fallback to the translated original if anything fails. The vertex input
   layout differs between vanilla and Sodium: write a small vertex adapter per format (Metal Shaders' `FORMAT_ADAPTER`
   does this for its formats).
   *Alternative hook*: patch GLSL at Minecraft's `GlslCompiler.compileToSpv` like Mine2Metal's `GbufferShaderPatch`.
   Prefer MSL substitution (no GLSL round-trip, full MSL features, half precision).
2. **Frame hooks** (mixins on `LevelRenderer` / `GameRenderer`, inside the render-scale window): before the level's
   frame graph, run the shadow pass (+ sky LUT, cloud/VL prep); after opaque terrain, the deferred-ish full-screen
   passes; water after translucent; post/tonemap before `applyPostEffects` returns; TAAU or MetalFX Temporal replaces
   `cm_upscale_to` when enabled.
3. **Shadow casters, per terrain renderer** behind one interface `ShadowCasterSource`:
   - `SodiumShadowCasters` (only class-loaded when Sodium is present: guard with `FabricLoader.isModLoaded("sodium")`),
     ported from Metal Shaders M1 (`SectionRenderDataStorage` ranges).
   - `VanillaShadowCasters`: vanilla compiled section buffers (`SectionRenderDispatcher` / `ChunkSectionsToRender`).
   - Fallback when neither is available: screen-space contact shadows, or Mine2Metal-style voxel DDA shadows (MIT,
     renderer-agnostic, built from `ClientLevel` block data).
4. **Native side**: new `cm_shade_*.m` (shadow pass encoder, full-screen pass helpers) following AGENTS.md rules:
   every new non-render GPU work calls `cm_flush_encoders`, Metal 4 barriers for every producer/consumer, every buffer
   GPU write calls `markGpuWrite`, track allocations for residency, ABI bump + `MetalConst` + `MetalNative` in sync.

## 4. Phases (each ends with a PR, version bump, CHANGELOG, tests)

| Phase | Scope | Done when |
|---|---|---|
| P0 | Confirm the alpha.14 PR is merged. Import Metal Shaders as a reference checkout outside the repo; add NOTICE/CREDITS skeleton. Inventory their uniforms/resources and map them to our slot model (write the table into this file). | PR merged; mapping table exists |
| P1 | Shading model + sky: `shade_common`/`shade_m2`/`shade_look`/`sky_lut`/`sky` on vanilla **and** Sodium terrain (solid/cutout), entities/items/hand; HDR world target (RGBA16F) + filmic tonemap into the main target; per-frame `ShadeFrame` upload. No shadows yet (shadow term = 1). | Looks right with and without Sodium; native compile test for every ported MSL file on Metal 4 + Metal 3; FPS measured |
| P2 | Sun shadows: shadow pass + casters (Sodium + vanilla adapters, contact-shadow fallback), receivers in terrain/entity shading. | Stable shadows both renderers; GPU cost logged (`Celestia` F3 + pass timings) |
| P3 | Water (`water.metal`: SSR, refraction, caustics), clouds, god rays (`vl`), weather. | Visual parity screenshots vs Metal Shaders |
| P4 | Temporal: jittered projection + motion vectors -> port `taa.metal` (TAAU) and/or wire **MetalFX Temporal** into `cm_upscale_to` (replaces the Spatial fallback for `METALFX_TEMPORAL`). | Render scale 67-75% looks close to native; stair-stepping gone |
| P5 | Settings: map their ~150 options onto our `ShaderOptionDef` UI (Shader Options screen), presets (Performance/Balanced/Quality/Ultra), live apply. Remove/replace the placeholder `celestia-native`/`celestia-minimal` packs. | Presets work live |
| P6 | Dynamic/coloured lights, aurora, Nether/End looks, labPBR, motion blur as time allows. | — |

## 5. Optimisation opportunities (beyond a straight port)

- **Render at scaled resolution** inside the existing render-scale window; with TAAU/MetalFX Temporal, 67-75% should be
  visually close to native. Budget: MetalFX Spatial costs ~2.0 ms and bilinear ~0.7 ms at 3024x1752 output on M1 Pro
  (`benchmark_upscale` in `tools/test_metal_backend.m`), so temporal/TAAU upscale must be measured the same way.
- **Tile memory / memoryless**: keep intermediates that never leave a pass `MTLStorageModeMemoryless`; merge full-screen
  passes into the world encoder where attachments match (our pass merging already merges compatible passes; avoid
  breaking it with standalone clears/blits). Use programmable blending / imageblocks for resolve passes on Apple GPUs.
- **Half precision** for colour/normal/BRDF math; `float` only for positions/depth (Metal Shaders and Mine2Metal agree).
- **Fast math**: compile ported terrain shading with `MTLMathModeRelaxed` (Pure Metal's measured ~40% terrain GPU win;
  we currently use `MTLMathModeFast` for name-matched terrain pipelines in `cm_compile_msl_library`). Keep sky/water/post
  strict where precision matters.
- **Shadow cost**: far cascade every N frames, sun-facing faces only, Depth16 option, opaque far cutout (their SHADOW.md).
- **Metal 4 vs Metal 3**: measure both; Pure Metal reports Metal 3 faster for them. Our M4 state-change cost was cut in
  alpha.13 but remains ~25% above M3 per draw.
- Avoid `MTLTextureUsageShaderWrite` on large render targets unless needed (it can disable lossless compression).
- Reuse their `OPTIMIZATION_LOG.md` findings; do not re-derive what they already measured.

## 6. Testing and verification

- Native: extend `tools/test_metal_backend.m` with a compile check of every ported MSL file + a synthetic G-buffer/HDR
  benchmark per preset at 3024x1752 (pattern: `benchmark_native_pipelines`), on Metal 4 and Metal 3.
- JUnit: shader identity detection (vanilla + Sodium sources), uniform struct layout sizes/offsets vs MSL
  (`static_assert(sizeof(ShadeFrame) == ...)` in MSL + Java constants), option mapping.
- In-game (owner tests; ask for screenshots + F3): beach test scene, with and without Sodium, with Xaero's minimap,
  day/sunset/night/cave/underwater, render scale 100/75/67. Record FPS + GPU ms per preset. Use JFR + `xcrun xctrace`
  (Metal System Trace) for profiling (see how it was done: render-thread JFR at 1 ms, `metal-gpu-intervals` table).
- Never modify the owner's PrismLauncher instance; read logs only.

## 7. Known pitfalls

- Mixin hooks must use exact descriptors from `javap -v` of MC 26.3 (see AGENTS.md); `defaultRequire = 1` crashes at
  startup on a bad target (good: fails loudly).
- Buffer slot 19 conflict (section 2). Argument-table caches are per encoder (`reset_pass_cache`).
- Sodium classes must never load when Sodium is absent (separate classes + `isModLoaded` guard).
- Reversed-Z in MC 26.3 (depth 1 near, 0 far); MC render targets are Vulkan-layout (Y flipped vs Metal, present flips).
- Keep `checkPrivacy` passing (no absolute home paths in committed files).
