# Handoff Plan: Port Metal Shaders' MSL suite onto Celestia Metal

Audience: the next agent picking this up. Read `AGENTS.md` first (build/test commands, invariants), then this file.

## Start here (state on 2026-11-28, after PR #35)

Sections 1–9 below are the original port plan and history; their "current state" notes are dated. This block is current.
Read `AGENTS.md` first, then this block, then `docs/QA.md`.

- **Releases and PRs:**
  - The latest release is `0.1.0-alpha.25` (`mod_version`). Everything since is under `## Unreleased` in `CHANGELOG.md`.
  - `main` includes, through PR #35:
    - multi-pack world packs; the chunk-edge fix; labPBR;
    - the renderer audit, with working MetalFX Temporal (#31);
    - the Balanced look and a gentler swell (#32);
    - QA defaulting to the village suite (#33);
    - faster water reflections (#34);
    - the sunset fixes for glowing grass edges and shadow acne (#35).
- **The owner, their machine and how they play:**
  - An M1 Pro MacBook Pro whose game window is 3024 × 1744.
  - Prism Launcher instance `26.3 Celestia Metal`: Quality preset, 100% render scale (native), 12 chunks, Metal 4, VSync off.
    Read it only, never modify it.
  - A 4K 144 Hz external monitor, where they plan to use MetalFX Temporal.
  - Their own install keeps the Pastel look and swell 1.3; Balanced is the default for everyone else.
- **Goals:**
  1. 60 FPS in usual play at native resolution on the Mac screen, including built-up areas on servers.
  2. Better looks at the same or lower cost.
- **Benchmarks** (window in front; Quality, native 3024 × 1744, M1 Pro, 300 frames under a 0.14°/frame pan, 2026-11-28):

  | Scene | FPS | p99 |
  | --- | --- | --- |
  | village-noon | 73.3 | 16.3 ms |
  | village-sunset | 63.5 | 18.0 ms |
  | village-night | 65.6 | 17.4 ms |
  | village-high | 53.3 | 21.2 ms |
  | village-shore | 48.5 | 23.2 ms |
  | village-shore-sunset | 42.1 | 27.0 ms |
  | beach | 35.5 | 30.0 ms |
  | village-rain | 51.5 | 22.5 ms |
  | nether | 137.8 | 13.1 ms |
  | end | 168.6 | 6.8 ms |

  Land views clear 60 FPS. Water fills `beach` and `village-shore`, and that is where frames are lost: the water pass costs
  9–10 ms, of which the reflection march is ~2.8 ms (§11 has the per-stage prices). The Performance preset row is in the
  README.
- **Next candidates** (confirm with the owner before starting any of them):
  - **Water reflection march:** apply the same exact skip to its 128/16-pixel per-lane reads, and remove the crossing re-reads.
  - **Water shading after the march** (~4 ms): price its stages with `DEV_*` early returns, then optimise without changing the image.
  - **Shore-aware waves:** see "Future features" in §10.
  - **Tile-memory shading for cutout foliage:** the owner supports Apple-GPU-specific work.
- **Standing decisions:**
  - Native MSL packs only; Iris stays hidden.
  - The pink-lavender haze stays.
  - Physically correct options default on (Snell's window is on).
  - Port Photon code only from MIT commit `26c2906e`; v1.4 is a visual reference only.
- **Workflow:**
  - Ask before committing, pushing or opening a PR.
  - After a merge, look at what's next and confirm with the owner.
  - Ask before any big visual change, and show A/B crops or a GIF.
  - The owner often works over Remote Control: send images with the file tool, and end with one clear question.
  - Measure before building: price a change with dev switches first (§11 shows why).
- **Verify:**
  - Run `JAVA_HOME=/opt/homebrew/opt/openjdk@25 ./gradlew build check runNativeTests`.
  - Then run the QA harness in the village (`tools/qa/run.sh shots`, `perf`, `profile`), with the window in front.
  - Compare variants A/B/A in one session. For image A/B, use `celestiametal.shade.freezeTime=true`, and crop the full-resolution
    captures in `build/qa/run/screenshots/`; exports are 1100 px.
  - `clean` wipes `build/qa`. Keep each `/fill` under 32k blocks.
- **Known open items:**
  - The first compile of a new world pack pauses the game ~7 s.
  - Packs can't change engine-side passes yet.
  - A glass-specific underwater flash still needs a reproducer.
  - The Nether and End `shadeLdrToHdr` fallback cost hasn't been measured.

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

---

## 8. P0 Inventory & Celestia Slot Mapping

Reference checkout: `GaelQuinta/minecraft-metal-shaders` at commit `dd32304de37257808c19793ea504d3c2f1f650a2` (`2026-11-26`, kept outside this repo at `~/minecraft-metal-shaders-ref`).

### 8.1 Celestia Backend Slot Budget vs. Upstream Metal Shaders

Celestia's `MTL4ArgumentTableDescriptor` (`src/main/native/cm_device.m`) uses one unified render argument table across `MTLRenderStageVertex | MTLRenderStageFragment` with:
- `maxBufferBindCount = 31` (indices `0..30`, Apple Silicon Metal 4 limit)
- `maxTextureBindCount = 32` (indices `0..31`)
- `maxSamplerStateBindCount = 16` (indices `0..15`)

| Resource Type | Upstream Metal Shaders (World Passes) | Celestia Existing Allocation (`celestia_metal.h`) | Celestia Port Mapping |
|---|---|---|---|
| **Buffers `0..14`** | Game uniform blocks (`0..N`) | Game `UNIFORM_BUFFER` slots (`CM_MAX_UNIFORM_BUFFERS = 15`) | **Unchanged (`0..14`)** |
| **Buffer `15`** | — | Push constants (`CM_PUSH_CONSTANT_SLOT = 15`) | **Unchanged (`15`)** |
| **Buffers `16..23`** | `16` `ShadeFrame`, `17` `ShadeLook`, `18` `ShadeGpu`, `19` `ShadeResources`, `23` `ShadeWaterParams`/`Head` | Vertex buffers (`CM_VERTEX_BUFFER_BASE = 16`, `CM_MAX_VERTEX_BUFFERS = 8`) | **Conflict resolved** — vertex buffers stay at `16..23`; shade globals move to `24..30` |
| **Buffers `24..30`** | `24` `ShadeDynLights`, `28..30` own-terrain | **Free** (7 slots) | `24` `ShadeFrame`, `25` `ShadeLook`, `26` `ShadeGpu`, `27` `ShadeResources`, `28` `ShadeWaterParams` (P3), `29` `ShadeDynLights` (P6), `30` reserved |
| **Textures `0..15`** | Game textures (`0..N`) | Game `COMBINED_IMAGE_SAMPLER` & `TEXEL_BUFFER` (`0..15`, typically `0..3`) | **Unchanged (`0..15`)** |
| **Textures `16..30`** | `16` `shadowMap`, `17` `skyLut`, `18..22` water, `23..25` dynlights, `29..30` water ripple history | **Free** (`CM_MAX_TEXTURES = 31`, indices `0..30`) | **Kept 1:1 (`16..30`)** (`16` shadowMap, `17` skyLut, `18..22` water, `23..25` dynlights, `29..30` ripple history) |
| **Texture `31`** | Optional debug `waterCoarse` (`hz`) | `CM_MAX_TEXTURES = 31` guards `< 31` (`maxTextureBindCount = 32`) | Unused in P1–P6; bump `CM_MAX_TEXTURES` to `32` if ever needed |
| **Samplers `0..11`** | Game samplers (`0..N`) | Game `COMBINED_IMAGE_SAMPLER` samplers (`0..11`, typically `0..3`) | **Unchanged (`0..11`)** |
| **Samplers `12..15`** | `12` `shadowCompare`, `13` `skyLutSmplr` | **Free** (`CM_MAX_SAMPLERS = 16`, indices `0..15`) | **Kept 1:1 (`12..15`)** (`12` shadowCompare, `13` skyLut/linear, `14..15` spare) |

> [!IMPORTANT]
> **Uniform Slot Defines (`MCOPT_SLOT_*` vs. RenderPearl `SlotBinding`)**: Upstream `MetalShaderRegistry.slotDefines` assigns a single unified index `i` across buffers and textures (`MCOPT_SLOT_Sampler0 = i`). Celestia's `MetalShaderTranslator.buildBindings` assigns **independent** counters per resource type (`bufferSlot`, `textureSlot`, `samplerSlot`). Replaced stages in Celestia (e.g. `sky`, `celestial`) must emit separate buffer/texture/sampler defines from `celestiaBindings` (`CELESTIA_BUF_<name>`, `CELESTIA_TEX_<name>`, `CELESTIA_SAMP_<name>`).

### 8.2 Global Buffer & Resource Struct Inventory

| Struct / Buffer | Size (Bytes) | Update Frequency & Ringing | Consuming Stages | Celestia Slot | Phase |
|---|---|---|---|---|---|
| `ShadeFrame` (`shade_common.metal`) | **1024 B** (`0..1008`) | CPU per-frame in shared ring (`RING = CM_INFLIGHT_SLOTS + 1 = 5`) | World VS/FS, Sky LUT, Post, Shadow, VL, Clouds, Water | **`buffer(24)`** (`CM_SHADE_BUF_FRAME`) | P1 |
| `ShadeLook` (`shade_look.metal`) | **1136 B** (`0..1120`) | CPU per-frame in same ring slot (`offset 1024`, slot stride `2304 B`) | World VS/FS, Sky LUT, Post, Water, Clouds, VL, Motion Blur | **`buffer(25)`** (`CM_SHADE_BUF_LOOK`) | P1 |
| `ShadeGpu` (`shade_look.metal`) | **512 B** (`468 B` used) | GPU-written (`exposure` at `176`, `scene` at `192`, `histogram[64]` at `208`, `xdrHot` at `464`); single shared buffer | World FS, Sky, Bloom down0, Histogram, Exposure, TAA | **`buffer(26)`** (`CM_SHADE_BUF_GPU`) | P1 |
| `ShadeResources` (`shade_look.metal`) | **128 B** (`16 x uint64_t`) | CPU per-frame ring (`RING = 5`); holds `MTLResourceID` of 16 textures | World FS, Sky, Celestial, Post, VL, Water | **`buffer(27)`** (`CM_SHADE_BUF_RESOURCES`) | P1 |
| `ShadeWaterParams` / `Head` (`water.metal`) | `float4` block | CPU per-frame | Translucent terrain / water (`ShadeWaterHead` in opaque UW caustics) | **`buffer(28)`** (`CM_SHADE_BUF_WATER`) | P3 |
| `ShadeDynLights` (`dynlight.metal`) | Dynamic ring | CPU per-frame ring | World VS/FS, Compute `shade_dl_irr` | **`buffer(29)`** (`CM_SHADE_BUF_DYNLIGHTS`) | P6 |
| `ShadeColorLights` (`colorlight.metal`) | **80 B** (256 B ring slots) | CPU per-frame header ring; volumes `texture(26)` fine / `texture(27)` coarse | Terrain / water / entity FS, compute `shade_cl_flood` / `shade_cl_clear` | **`buffer(30)`** (`CM_SHADE_BUF_COLORLIGHT`) | P6b |

### 8.3 `ShadeResources` Argument Buffer Entries (`buffer(27)`)

| Index | Field | Format & Size | Producer | Phase |
|---|---|---|---|---|
| `0` | `milkyWay` | `RGBA16F` (baked once; alpha holds fbm noise in P6) | `shade_milkyway_bake` | P1 |
| `1` | `prevScene` | `RGBA16F` / `RG11B10F` (last frame HDR world or TAA history) | `ShadePost` / TAAU | P1 (dummy), P3/P4 |
| `2` | `scene` | `RGBA16F` / `RG11B10F` (this frame HDR world; dummy during world pass) | World pass | P1 |
| `3` | `bloom` | `RGBA16F` (quarter-res bloom accumulation) | `shade_bloom_up` | P1 |
| `4` | `weatherNoise` | `RG16F` `1024x1024` (puddle/snow tile, baked once) | Weather init | P3 |
| `5` | `prevDepth` | `R16F` (linear view depth of `prevScene`) | TAAU / Depth copy | P3 / P4 |
| `6` | `shadowTint` | `RGBA16F` (near-cascade translucent caster tint) | Shadow tint pass | P3 |
| `7..8` | `pbrNormal`, `pbrSpecular` | `RGBA8` / `float` | Resource pack PBR | P6 |
| `9` | `waterOpen` | `RGBA8` `128x128` toroidal open-water map | `WaterOpenScan` | P3 |
| `10` | `reflPano` | `RGBA16F` `2048x512` directional reflection panorama | `shade_water_pano_fs` | P3 |
| `11` | `aurora` | `RGBA16F` scaled | `shade_aurora_pass` | P6 |
| `12` | `cloudShadow` | `R8` / `R16F` `256x256` | `cloud_shadow` | P3 |
| `13` | `cloudDome` | `RGBA16F` upper hemisphere dome | `cloud_dome` | P3 |
| `14` | `cloudScreen` | `RGBA16F` screen-reconstructed cloud history | `cloud_resolve` | P3 |
| `15` | `waterSwell` | `RGBA16F` `256x256` mipmapped baked sea swell | `shade_water_bake_swell_fs` | P3 |

### 8.4 Pass-Local Uniforms & Dedicated Encoder Passes

All standalone shade passes (`sky_lut`, `shadow`, `vl`, `clouds`, `taa`, `shade_post`, `motion_blur`, `dynlight`) run in their own render or compute encoders with **no RenderPearl vertex buffers bound** (full-screen triangle via `vertex_id`, vertex pulling in `shadow.metal`, or compute `thread_position_in_grid`). Therefore, pass-local inputs cleanly use `buffer(0..4)` and `texture(0..6)` while keeping global shade bindings at `buffer(24..27)`, `texture(16..17)`, and `sampler(12..13)`:

| Pass / Module | Pass-Local Buffers | Pass-Local Textures | Notes | Phase |
|---|---|---|---|---|
| **Sky LUT** (`sky_lut.metal`) | `buffer(24..25)` (`ShadeFrame`, `ShadeLook`) | Out: `skyLut` (`128x80 RGBA16F`) | No pass-local inputs | P1 |
| **Post Chain** (`shade_post.metal`) | `buffer(0)` (`float4` / `ShadeBloomUp` / `ShadeFinalParams` 96 B), `buffer(24..27)` | `texture(0..6)` (`scene`, `bloom`, `depth`, `bloom0`, `vlT`, `vlD`, `taaDepth`) + `texture(17)` `skyLut` | `shade_histogram` & `shade_exposure` run as compute dispatches on `buffer(26)` (`ShadeGpu`) | P1 |
| **Sun Shadows** (`shadow.metal`) | `buffer(0..4)` (`arena`, `chunks`, `regions`, `ShadowCascade` 80 B, `EntityCast` 32 B / `ShadowTintParams` 48 B) | `texture(0)` + `sampler(0)` (atlas/entity texture for cutout/tint); Out: `depth2d_array<float>` (2 slices) | Separate shadow pass; rebinds globals afterward | P2 |
| **Water** (`water.metal`) | `buffer(28)` (`ShadeWaterParams`) in world translucent pass; `buffer(0)` in `hz`/`pyr`/`bake`/`pano` passes | `texture(18..22, 29..30)` in world pass; `texture(0)` in pre/capture passes | Scene copy splits world pass; requires `cm_flush_encoders` + Metal 4 barriers | P3 |
| **Volumetric Light** (`vl.metal`) | `buffer(0)` (`VlParams`), `buffer(1)` (`VlState` 16 B) + `buffer(24..27)` | `texture(0..4)` (`depth`, `prevSky`, `shadeGrid`, `history`, `veil`/`od`) + `texture(16..17)` | Compute (`canopy` + `shade_grid`) + fragment (`march`, `fold`, `veil`, `composite`) | P3 |
| **Clouds** (`clouds.metal`) | `buffer(0)` (`CloudParams` / `mode`) + `buffer(24..26)` | `texture(0..3)` (`weather`, `noise`, `cur`/`hist`, `depth`) + `texture(17)` | Compute bake (`noise`/`weather`) + fragment (`march`, `resolve`, `over`, `dome`, `shadow`) | P3 |
| **TAAU** (`taa.metal`) | `buffer(0)` (`TaaParams`), `buffer(1)` (`exposure` / `ShadeGpu + 176`), `buffer(2)` (`TaaMovers`) | `texture(0..4)` (`cur`, `curDepth`, `hist`, `histDepth`, `reactive`) | Or MetalFX Temporal via `cm_upscaler_encode` inside `cm_upscale_to` | P4 |

### 8.5 Metal 4 Residency, Barriers, and Native Helper Contract (for P1+)

1. **Residency (`MTLResidencySet`)**: Every buffer and texture backing `ShadeFrame`/`ShadeLook` rings, `ShadeGpu`, `ShadeResources` (and every texture placed inside `ShadeResources`), `skyLut`, HDR world target, bloom mip chain, and `dummyShadow`/`dummyTexture` must be registered with `cm_track_allocation(ctx, obj)` on creation and retired via `cm_retire_object(ctx, obj, serial)` on destruction/resize. On Metal 3, encoders reading `ShadeResources` call `[enc useResources:list count:n usage:MTLResourceUsageRead stages:MTLRenderStageVertex | MTLRenderStageFragment]` (skipping any texture bound as an active render attachment).
2. **Metal 4 Argument Table & Encoder Re-binding**: `cm_pass_begin` / merged pass continuation binds `ctx.m4VertexArgTable` (`buffers 0..30`, `textures 0..30`, `samplers 0..15`). Any native shade helper (`cm_shade_bind`, `cm_shade_lut_render`, `cm_shade_post_*`) that updates slots `24..27`, textures `16..17`, or samplers `12..13` must either go through `ctx`'s dedup caches or reset the relevant cache entries when switching between shade-owned encoders and RenderPearl world encoders.
3. **Encoders & Barriers**: Every non-render-pass GPU operation (Sky LUT render pass, bloom chain, compute histogram/exposure, blit copies) **must** call `cm_flush_encoders(ctx)` first so soft-ended RenderPearl passes and deferred clears are never reordered, and emit explicit Metal 4 producer/intra-pass barriers (`emit_m4_render_producer_barrier` / compute `barrierAfterEncoderStages:`) between producer and consumer stages.
4. **Native ABI & `checkPrivacy`**: Any new `cm_shade_*` entry points in `src/main/native/cm_shade.m` (or `cm_shade_*.m`) must bump `CM_ABI_VERSION` in `celestia_metal.h` + `MetalConst.ABI_VERSION` and wire matching `FunctionDescriptor`s in `MetalNative.java`. Note: `LICENSES/` only needs to be added to `build.gradle`'s `processResources` / `jar` outputs once Photon-derived shaders (P3) are bundled into the JAR.

## 9. P6 progress log (update as you go)

P6 is split: **P6a dynamic lights** (moving sources: hands, mobs holding lights, dropped items, burning entities, blazes,
projectiles, TNT, ...; upstream `docs/dev/DYNLIGHTS.md`), then **P6b** coloured block lights (upstream `ColorLights`, which
samples in *own-terrain's vertex stage* at textures 33/34 + vertex bytes 15: needs a fragment-side redesign for
vanilla/Sodium terrain using free texture slots 26-28), Nether/End looks, aurora, motion blur, labPBR.

P6a status (branch `feat/shader-port-p6a-alpha.21`, based on main after the P5 merge):
- [x] Native `cm_dynlight.m` (port of upstream `mcdynlight.m` dynamic half): rings for lights + occupancy, visibility /
      irradiance 3D textures, zeroed fallback, `cm_dl_*` C ABI (ABI 8), bound per render encoder at buffer 29 / textures
      23-25 via `cm_dynlight_bind_render_encoder`. Removed dead `CM_SHADE_BUF_BLOOM` (it collided with slot 29). Metal 4
      compute has no `setBytes`: kernel parameters go through a per-ring-slot params buffer + producer barriers.
- [x] MSL: `dynlight.metal`, `dynlight_vis.metal` in `shaders/ported/` (now `shaders/engine/`) (upstream's `shade_dynlight.metal` m3 seam is not
      needed: `ShadeShaderPatcher` appends `DynLightMsl.module()` and passes `CEL_DL_PARAMS` / `CEL_DL_ARGS`).
- [x] Java in `dev.celestia.metal.shade.light`: `DynLightNative` on `cm_dl_*` via `MetalNative.shadeDowncall`, config as
      `celestiametal.shade.dynLights.*` + `applyLive`, occupancy through vanilla `PalettedContainer.get` (Sodium optional),
      `ShadeCompile` / `ColorLights` dropped, mixins (`DynLightEntityRendererMixin`, `DynLightClientLevelMixin`) verified
      against 26.3 with javap.
- [x] CelestiaShade: `DynLights.frame` (gather + vis/irr compute) in `beginWorld`, fallback bindings at init,
      `DynLights.disable` when the option is off, `close` in `close`.
- [x] Shading: terrain, water (above-water only) and entities (not the first-person hand) add
      `shadeDynamicLightsVol(...) * ambientBlock`; the hand takes its held light through the packed-light mixin.
- [x] Options: `DYNAMIC_LIGHTS`, `DYNAMIC_LIGHT_STRENGTH`, `DYNAMIC_LIGHT_COUNT` (preset 16/32/48/64),
      `DYNAMIC_LIGHT_ENTITIES` -> `ShadeSettings.Lights`; F3 `| Lights N`; native Test 2q (M4/M3); 0.1.0-alpha.21.
- [ ] In-game check by the owner (vanilla + Sodium): held torch, blaze, dropped glowstone, burning mob, light behind walls.
- [ ] Later (optimization pass): the water specular glint (`shadeDynamicLightsSpec`), entity vertex-stage lights
      (`DynLightMsl.patch`), visibility volume count per preset (startup switch today, 16).

P6b status (branch `feat/shader-port-p6b-alpha.22`, stacked on P6a / PR #13):
- [x] Coloured block light, the fragment-side redesign: upstream sampled `shadeColorLightAt` in own terrain's vertex stage
      (vertex textures 33/34, vertex bytes 15). Here `shadeColorLightFrag` evaluates it per fragment from
      `ShadeFrame.cameraBlock + cameraFract + p` (exact integer world block, no float drift far out) in terrain, water (above)
      and entities (not the hand), bound at buffer 30 (header ring: Metal 4 has no `setBytes`) / textures 26-27.
- [x] Native `cm_colorlight.m` (ABI 9): fine 256x128x256 + coarse 192x64x192 RGBA8 toroidal volumes, shared block-id buffer,
      list ring, header ring, fallback; Metal 4 intra-encoder barriers between dependent flood dispatches.
- [x] Java `ColorLights` on vanilla `PalettedContainer.forEachInPalette` / `getAll` (Sodium optional), fed by the same
      block / section mixin as the dynamic lights; options `COLORED_LIGHTS`, `COLORED_LIGHT_STRENGTH`, `COLORED_LIGHT_GLOW`;
      F3 `| Colour N` (slots spreading); idles outside the Overworld (vanilla shading there until the Nether / End looks).
- [x] Native Test 2r (M4/M3): fallback, soul-fire spread blocked by a wall, strength 0; warm step ~0.2 ms / 8 sections.
- [x] In-game QA (isolated clients + scripted probe, vanilla / Sodium / the 110-mod Create + Alex's Caves list): colours show
      after fixing the section reader (`PalettedContainer.getAll` visits palette entries, not cells) and sampling half a block
      in front of the face (no orange inside corners). alpha.23.
- [x] Smooth block light (alpha.23, `SMOOTH_BLOCK_LIGHT`): vanilla's per-face smooth lighting left block-aligned patches the HDR
      torch curve amplified (debug view 9 vs 10 showed the vertex block light, not AO). The client light engine's per-block
      levels go into an RG8 fine-window volume (texture 28; R = level where open, G = open) via `shade_bl_upload`, refreshed on
      `ClientChunkCache.onLightUpdate`; terrain and water filter it per pixel half a block in front of the face, normalised
      over open cells, falling back to the vertex value outside the window. Known: a hard switch to vertex light at the
      window edge (128 blocks out); could fade over the last section.
- [x] Follow-up features covered in §10.

## 10. Photon look pass and roadmap (alpha.25 on)

Visual target: Photon v1.4's look, with Celestia's own Pastel colour grade on top. Port code and assets only from Photon's last
MIT commit, `26c2906e`; v1.4 and every later release use a different licence and serve only as a visual reference. Every
feature must stay cheap on Apple Silicon: profile it with `CELESTIA_GPU_PROFILE=1` and compare against a clear-sky or
feature-off run.

Done (alpha.25):
- [x] Volumetric cumulus, altocumulus and cirrus/cirrocumulus layers, with Photon's 12-day weather cycle (`ShadeWeather`).
- [x] Water absorption and scattering, and physical underwater fog. Underwater is now clearer than Photon at the owner's request.
- [x] The Pastel colour look with a Pastel Strength slider.

Follow-up:
- [x] Calmer water surface verified in a fixed-camera pond comparison with Photon. The broader swells and finer ripples ship in alpha.25.
- [x] Chunk-edge blending fades distant Overworld terrain and water into the directional sky. Terrain and water keep continuous
      depth coverage at the outer edge, and water reflection hits fade toward the sky along the reflected ray. Use the QA profile
      tokens `s32,s0` to compare the previous border fog with chunk-edge blending.
- [x] Underwater sunlight shafts reuse the quarter-resolution volumetric pass and stop at the visible terrain or water surface.
      Snell's window uses physical refraction and Fresnel reflection; the Water > Snell's Window option (on by default, the owner's choice) can switch to Photon's see-through default, which is cheaper. Test 2o checks the critical angle and underwater occlusion on Metal 3 and 4.
      Follow-up QA: profile `s128,s0` in the underwater scene to isolate the shafts, and compare the same camera views against Photon.

Next, in order:
- [x] Underwater sunlight ported from Photon's MIT `water_fog_vl.glsl`: shadow-mapped shafts banded along the refracted sun,
      surface to floor, about 0.8-1.0 ms. The material fog drops its sun term while the pass runs. Check animated effects with
      `celestiaqa.repeat` bursts in `underwater` and `underwater-noon`. Open question: the shafts take the warm low sun and the
      Pastel grade's rose (lilac at morning), where Photon's read cyan-white.
Owner priorities (2026-11-28), in order:
- [x] Multiple native MSL shader packs (Unreleased, `feat/multi-pack`). `"kind": "world"` packs override Celestia Native's
      `shaders/*.metal` by file name over the engine ABI in `shaders/engine/` (`shade_api.metal`: ShadeFrame / ShadeLook /
      ShadeGpu / ShadeResources / ShadeWaterParams; slots; light and TAA kernels), with `"recompile"` options as `#define`s and
      live switching (`ShadeShaderPatcher.epoch`). Iris/OptiFine packs hidden. Spec: `SHADER_PACK_SPEC.md` section 5; example:
      `examples/shaderpacks/celestia-example-world`; QA: `tools/qa/run.sh packs`. Open: the first compile of a new pack
      stalls the game ~7 s on an M1 Pro (a loading overlay or background compile would hide it); a pack can't yet change
      the engine-side passes (pass list, targets, bindings) or the dynamic-light shading.
- [x] Nether and End looks.
- [x] Aurora.
- [x] Motion blur.
- [x] A real cumulus congestus layer (replaces the thicker-cumulus stand-in on weather days 2 and 4).
- [x] labPBR 1.3 terrain materials from Minecraft resource packs (vanilla and Sodium), with a live `LAB_PBR` option.

Settled: the pink-lavender distant haze stays, as part of the Pastel look (owner).

Future features (owner, look-polish pass):
- [ ] **Shore-aware waves.** Every wave set (the baked near waves and the swell) travels one fixed world direction, so on beaches
      facing the other way they roll out to sea. Plan: a CPU distance-to-shore map around the player (upstream's WaterOpenScan
      idea: 256² texels at 2 blocks, rebuilt in the background), read once per water pixel. The swell turns so its crests
      run parallel to the shoreline and move toward it, and sheltered water calms. Estimated ~0.05 ms GPU. Until then the swell
      default is 0.6 (was 1.3): about a quarter less open-water motion in `beach` (frame-to-frame change 0.35 -> 0.27).

## 11. Renderer audit (2026-11-28)

- The renderer now alternates HDR world targets for previous-frame reflections. A same-process A/B/A on an M1 Pro compared
  the full-frame copy with alternating targets over 90 Metal 4 submits per sample at 3024 × 1744. Savings were 0.50–1.20 ms
  per submit across the pond, underwater, vista, Nether and End scenes. The reopened water pass was the largest cost in the pond.
- The 180-frame QA descent reproduced a dry-looking pond floor when the near plane clipped the still-water surface. The water
  path now contributes fog for rays that intersect that local surface before the near plane.
- The underwater upward pan reproduced narrow reflection streaks with SSR enabled. The resolve now verifies that hits are on
  submerged geometry and rejects nearby isolated depth samples.
- A live render-scale change left the sky pass drawing into the previous target. The sky pass now uses the active target,
  restoring the sun and the continuous haze around distant chunks with both TAAU and MetalFX Spatial.
- The performance HUD and settings measure average FPS and 1% lows over the same 120-frame window, including frame pacing
  and GPU waits between renders.
- With the sky restored, Balanced and 65% TAAU averaged 61.4–178.5 FPS across ten scenes on the M1 Pro, at 1966 × 1134
  internal resolution and 3024 × 1744 output. Heavy rain averaged 61.4 FPS with an 18.01 ms 99th-percentile frame time.
  The noon and sunset pond views averaged 70.1 and 64.0 FPS respectively.
- Under a 42-degree camera pan, nine of twelve scenes averaged at least 60 FPS at 65% TAAU. At 60% TAAU with the same
  output resolution, the three slower scenes averaged 61.6 FPS at the sunset pond, 65.9 at the night pond and 63.3 in
  heavy rain. Their 99th-percentile frame times were 18.06–19.09 ms.
- World-pack switching and the coloured and dynamic light rooms passed in-game QA. The first compilation of the example pack
  and its recompile option took 7.2–7.5 s. Warm switches drew three frames in 0.14–0.20 s.
- **Native resolution (100% render scale, 3024 × 1744, M1 Pro, 300 frames under a 0.14°/frame pan):**

  | Preset | Pond (noon / sunset / night) | Underwater noon | Heavy rain |
  | --- | --- | --- | --- |
  | Quality (the owner's preset) | 51.9 / 44.0 / 42.1 | 46.4 | 52.4 |
  | Balanced | 47.3 / 41.4 / 45.3 | 44.8 | 52.1 |
  | Performance | 80.5 / 64.6 / 64.0 | 94.9 | 61.8 |

  On Quality, the land views ran at 68–92 FPS and the Nether and End at 138–162. Performance clears 60 FPS because Sky Only
  reflections and zero swell and caustics compile those paths out of the water shader.
- **Where Quality's water frame goes** (pond sunset, 22.4 ms per submit):
  - The water pass (`CelestiaWater.ReopenedWorld`) takes 8.9 ms, the sky pass 3.8 ms and the final pass 1.3 ms.
  - Switching off swell, caustics or foam alone saves almost nothing, because their code stays compiled in.
  - Sky Only reflections save 3.5 ms in the water pass, although the SSR march itself is only ~1.25 ms (`devSsr=1`). The rest is
    register pressure: the water shader is register-bound, so code behind a branch still costs on every water pixel.
  - Procedural stars cost ~1.9 ms of the sky pass at sunset and night, and they are visible there.
- **Next step towards 60 FPS at native Quality without visual loss:** move the SSR march out of the water fragment into its own
  pass over water pixels, writing hits to a texture the water shader reads. This would cut the main water shader's register
  pressure while keeping the same reflections. It is the largest image-preserving saving found (up to ~3 ms) but a sizeable
  rewrite. The Fast Sky reflection choice exists for players who prefer frame rate, and no preset uses it.
- **Real-play scenes** (plains village on the coast, Quality, native 3024 × 1744, 300 frames under a 0.14°/frame pan):

  | Scene | FPS | p99 |
  | --- | --- | --- |
  | village-noon | 73.2 | 16.5 ms |
  | village-sunset | 63.3 | 18.4 ms |
  | village-night | 65.3 | 17.8 ms |
  | village-high (over the bay) | 52.2 | 21.6 ms |
  | village-shore | 48.2 | 23.5 ms |
  | village-shore-sunset | 43.5 | 25.6 ms |
  | village-rain | 51.5 | 22.5 ms |

  On land the village clears 60 FPS. With the bay in view, the water pass takes 9–10 ms of a ~23 ms frame (village-shore
  profile), the same as on the test pond. Rain spends ~4.1 ms in `Main` and ~2.9 ms unlabelled. This confirms water as the
  native-Quality blocker in real play, and the SSR-split pass above as the next step.
- **MetalFX Temporal** (`TemporalUpscaler` METALFX_TEMPORAL mode and `cm_upscale_temporal`; it used to fall back to Spatial):
  - **Inputs:** TAAU's Halton jitter in input pixels (the `++` sign is verified: sharpest and closest to native), D32 depth, and
    RG16F camera motion from `taa_motion` (previous − current UV, scaled to pixels natively).
  - **Cost on the M1 Pro at 3024 × 1744 output:** MetalFX takes ~5.5 ms (pre 1.3, mid 2.3, post 1.8) plus 0.4 ms for motion.
  - **Village timings, Quality:**

    | Scale | Noon | Sunset | Night | Over the bay | Waterfront | Waterfront sunset | Rain |
    | --- | --- | --- | --- | --- | --- | --- | --- |
    | 75% | 62.8 | 58.2 | 59.6 | 51.2 | 50.2 | 46.5 | 49.0 |
    | 85% | 50.9 | 48.7 | 51.4 | 44.0 | 42.7 | 39.5 | 43.9 |

    Both are slower than native on this screen, because the upscaler's cost follows the output size.
  - **When to use it:** on the laptop's Retina screen, native or TAAU gives more FPS. For a 4K output, use a lower input scale
    (≤ 67%), where the saved world shading outweighs MetalFX's ~8 ms (extrapolated, not measured: QA can't drive a 4K window).
  - **Water and rain are the frame-rate limit, not upscaling.** Real-play land views clear 60 FPS at native Quality.
    Waterfront and rain need ~6 ms that no image-preserving change found here provides. Pricing the water features one at a time
    by compiling each out (`-Dcelestiametal.shade.water.devUndef=…`) on `village-shore`: detail 1.25 ms, swell 1.2, foam 1.15,
    caustics 1.07, glitter 0.77, glossy 0.38, rain ripples 0.13. The cost is spread across the shader's register pressure.
- **Splitting SSR into its own pass doesn't pay** (measured, Quality, native):
  - **Measurement:** the "normal + march" stage a separate pass would run costs 5.0 ms on `village-shore`, against 5.3 ms for
    the SSR-free shader and 9.5 ms for the full one. Split total: ~9.4 ms (no gain) on the waterfront, 6.1 vs 6.3 ms over the bay.
  - **Where the cost is:** the march itself (~2.8 ms), mostly the full-resolution search (~2.2 ms), not register pressure.
  - **Next lossless step:** a finer conservative Hi-Z level (4 or 8 px min/max; `Pyr8` is already built and thrown away), so the
    full-resolution search skips empty stretches before reading depth.
- **Done (perf/apple-gpu): `SHADE_SSRH_L2`.** A dilated 8-px level (`Pyr8Ring`, rows below the 128-px blocks) lets the fine
  march skip a half 16-px interval's 4 depth reads when the lane's ray is in front of it. It is exact. Water pass −0.5 ms at the
  waterfront and −0.25 ms over the bay; waterfront FPS +1.6 (noon) and +2.4 (sunset) A/B. The behind case can't be skipped
  (foreground-occluder rule). Next in the march: the 128/16 levels' per-lane reads, and the crossing re-reads (`zk`, `zp`).
- `celestiametal.shade.freezeTime=true` stops the water, sky and cloud clocks for image A/B comparisons. Two identical runs
  still differ by ~0.2–0.8/255 (villagers, foliage), which is the noise floor.

