# Changelog

## Unreleased

- Add underwater sunlight shafts with wave focusing and shadow occlusion. Looking up through water uses physical refraction
  and Fresnel reflection, with a directional sky fallback when the refracted view leaves the screen.
- **Daytime sky light on blocks is cooler, closer to Photon's.**
  - **Change:** the daytime ambient tint keeps the sky's blue, `{0.86, 1, 1.14}` (was a warm `{1.05, 1, 0.84}`), and the sky irradiance is no longer desaturated (was 0.2).
  - **Effect:** shaded faces now read cool against warm sunlit faces. On the test pond's sandstone pillars at noon, the shaded faces go from (120, 128, 109) to (111, 128, 125), where Photon gives (85, 126, 137).
  - **Unchanged:** sunlit surfaces and the Pastel grade. There is no GPU cost.
- **Underwater sunlight is now Photon's volumetric light.** It's adapted from Photon's MIT-licensed `water_fog_vl.glsl` (commit 26c2906e).
  - **Shafts:** they converge toward the sun and run from the surface to the floor, brightest near the surface, and they drift with the water.
  - **Shadows:** the shadow map shadows them, so pillars and walls cut dark shafts through the water.
  - **How:** a smooth noise projected along the refracted sun ray bands them, using Photon's `linear_step(0.4, 0.5)` plus a base of 0.15. Photon's four multiple-scattering octaves are included.
  - **Fog:** the march now carries all underwater sunlight. The material fog keeps only skylight while it runs.
  - **Optimisations:** the octaves' phase terms are computed once per ray, and the march takes 16–20 steps on Ultra.
  - **Cost:** about 0.8–1.0 ms at 3024×1742 on an M1 Pro.
  - **QA:** a new `underwater-noon` scene, and a `celestiaqa.repeat` burst option for capturing animated effects.
- New **Water > Snell's Window** option (on by default). On keeps the physical view from underwater: the world above shows only
  inside the 97-degree cone, and the surface mirrors the water outside it. Off matches Photon's default: the sky, clouds and
  the world above show through the whole surface, shifted slightly by the waves. Off is also cheaper, because the underside
  skips its SSR march: underwater on Ultra at 3024×1742 drops from 24.8 to 15.3 ms on an M1 Pro.
- Fade distant Overworld terrain and water into the directional sky at chunk borders. The fade also applies to depth coverage
  and screen-space water reflections.

## 0.1.0-alpha.25

### Changed
- **Volumetric clouds rebuilt in the style of Photon.** The old layer was a 32-block slab of very coarse noise, sampled about every 24 blocks, so it rendered as a blurry overcast smear. It is now a cumulus layer that starts at vanilla's cloud height and is as thick as that height above sea level (about 130 blocks).
  - **Detail and lighting:** individual clouds have lit tops, grey-blue undersides, wispy bottoms and fine eroded edges, and the water reflects them.
  - **Light:** the sun or moon lights the clouds as seen from cloud altitude, so low suns turn them golden rather than red, and the zenith sky fills the shadowed sides.
  - **Rain:** rain spreads the layer toward overcast stratus.
  - **Source:** the density model, light and sky marches, multiple-scattering octaves, powder term and phase lobes are adapted from Photon's last MIT-licensed commit (26c2906e). Its three noise textures ship unmodified. Photon v1.4 itself is under a different licence and was used only as a visual reference.
- **Built for Apple GPUs.**
  - **Noise:** the 3D noises are tiled 2D atlases, read with two bilinear taps.
  - **Tracing:** rays are traced for a quarter of the half-resolution pixels each frame, in a 2×2 checkerboard. A resolve pass rebuilds the half-resolution image from the reprojected history, clamped to the new traces so cloud edges don't smear.
  - **Light marches:** they skip the fine noise octave and the curl warp, and run on every other in-cloud sample.
  - **Cost:** on Ultra at 3024×1742 on an M1 Pro, all cloud passes together cost about 1.2–1.7 ms. The clouds are also sharper than before, since they used to be traced at quarter resolution with no history.
- **Three cloud layers and daily weather, like Photon.**
  - **New layers:** a thin altocumulus deck at 8/3 of the cumulus height and a planar cirrus and cirrocumulus layer at 5×. Both are adapted from Photon's MIT commit, and layers blend by distance.
  - **Daily weather:** `ShadeWeather` hashes each Minecraft day to one of Photon's twelve skies, blends into the next around dawn, and moves toward overcast in rain. It runs on the CPU, once per frame.
  - **Congestus days:** Photon's days 2 and 4 use a tall cumulus congestus layer, which isn't ported yet. Those days draw a thicker, denser cumulus instead.
  - **Testing:** `-Dcelestiametal.shade.weatherDay=N` fixes the sky to day N.
  - **Apple GPU path:** a layer with no coverage today is skipped. The altocumulus marches half the cumulus steps with shorter light marches. The cirrus swirl comes from the curl texture instead of hashed gradient noise, and its light march uses a lighter density.
  - **Cost:** all clouds together cost about 2 ms on Ultra at 3024×1742 on an M1 Pro, and about 3.4 ms on the heaviest overcast day. That is measured against a clear-sky run, so overlap into the following passes is counted.
- **Calmer water surface, closer to Photon:** the fine ripples are a third as strong (0.30 → 0.10) and fade out within about 110 blocks instead of reaching the horizon. The long waves are stronger (0.6 → 1.0), so the water reads as calm with gentle visible swells.
- **Water now looks like Photon's: deep, clear and mirror-like** instead of milky azure.
  - **Coefficients:** water now uses Photon's absorption (0.39, 0.14, 0.07 per block), its biome term (a third of the biome tint's absorption, relative to forest water) and its scattering of 0.01, which used to be 0.022. In-scattering gets Photon's multiple-scattering energy term.
  - **Result:** reflections stand out over a darker body of water, oceans stay deep blue and swamps turn murky green.
- **Underwater fog is now real water fog, not vanilla's blue wall.**
  - **How:** every surface seen from inside water is attenuated per channel, with sun and sky light scattered toward the eye. Vanilla's fog-colour blend is off while the camera is in water.
  - **Clearer than Photon:** absorption is (0.11, 0.040, 0.022) and scattering 0.010, where Photon uses (0.20, 0.08, 0.04) and 0.03. That gives clean ocean and river water with roughly 60 blocks of blue-green visibility, while reds still fade within about 10 blocks.
  - **Underside of the surface:** where it mirrors the water below, it now shows the same water colour.
  - **Cost:** the same frame time as before.
- **New default colour look: Pastel.** It aims for "realistic and vibrant like Leica Vibrant, but more pastel and cuter".
  - **Brightness:** it is a bright, high-key grade, with +0.3 EV.
  - **Tone:** contrast is soft (0.84), shadows are milky and rosy (a display lift of about 3 % red and blue, 2 % green), and highlights whiten sooner (inset 0.34) and carry a pink gain (green 0.93, blue 0.965).
  - **Colour:** a rose white-balance tint runs through the midtones, and the vibrance step is strong, so muted colours still pop.
  - **Sunsets and bloom:** sunsets are pinker and bloom is dreamier.
  - **Pastel Strength slider:** 0 is the Epic grade, 1 is the default and 1.5 is dreamier still. Every look parameter blends between Epic and Pastel.
  - **How:** lift, gain and tint are per look. `ShadeLook.ldrToHdr` and `display()` invert them exactly, so fog and clear colours stay correct.
  - **Presets:** presets no longer set the look, because a look is a matter of taste, not of cost. Choose Epic, Storybook or Natural under Color Look.
  - **Existing installs:** an instance that already saved a look keeps it until Pastel is picked.
- The **Cloud Layer Thickness** option is replaced by **Cloud Coverage** (0–1.6, default 1.0). Cloud Samples still sets the march: that many steps at the zenith and twice as many at the horizon.

### Added
- Each fullscreen pass now reports its own pipeline name in the GPU profiler and in GPU captures, for example `shade_cloud_trace`. The exposure and blit encoders are labelled too.
- `-Dcelestiametal.shade.cloudDev` is a live switch for pricing the cloud layers: 1 turns off the altocumulus, 2 the cirrus, 4 the cumulus, and 8 skips tracing.
- A JUnit test compiles every atmosphere entry point on the GPU. It also checks the noise atlases' wrap gutters and that the noise PNG's alpha channel is read as raw data.

## 0.1.0-alpha.24

### Performance
- **Underwater and fog frames are faster.** Every sky, terrain and water pixel used to convert the vanilla fog colour into HDR itself, whenever fog applied. That colour is the same for the whole frame, and the conversion runs the tonemap backwards: an sRGB decode, two colour matrices and three Newton steps, about 13 `pow` calls per pixel. It is now done once per frame on the CPU (`ShadeLook.ldrToHdr`) and passed in `ShadeFrame.fogColorHdr`, which reuses the unused `skyColor` slot. Measured underwater on Ultra at 3024×1742 on an M1 Pro, the sky pass alone fell from 10.2 ms to 2.0 ms and the whole frame from 46.5 ms to 39.1 ms. The image is unchanged (median difference 1/255).
- **The Performance preset now uses sky-only water reflections.** Screen-space water reflections are the most expensive feature: 9 ms of a 25.5 ms frame over the test pond and 15 ms underwater. The Performance preset barely changed water cost before. Now it is 10.3 ms faster than Ultra at the pond (was 3.0 ms) and 15.8 ms faster underwater (was 3.0 ms). Ultra, Quality and Balanced keep screen-space reflections.

### Added
- **Opt-in Metal 4 GPU pass profiler** (`cm_profiler.m`), switched on with `CELESTIA_GPU_PROFILE=1` in the environment (`CELESTIA_GPU_PROFILE_EVERY` sets the report interval, 240 submits by default).
  - **How:** it timestamps every encoder a command buffer opens and prints the average milliseconds per encoder label to stderr as `[GPU] …`.
  - **Labels:** while profiling, RenderPearl's pass names (Sky, Main and so on) are sent as encoder labels. Add `-Dcelestiametal.noPassMerge=true` for a per-pass split.
  - **When off:** nothing changes.
- `-Dcelestiametal.shade.water.devSsr` is now read live, every frame, and also applies to the underwater reflection:
  - 1: no march.
  - 2: only the coarsest level.
  - 3: no resolve or panorama.
  - 4: no panorama.
- Water debug views:
  - 12: which water fragments draw and how coplanar they are with the opaque surface.
  - 13: water-pass overdraw, one quarter of white per layer over a black scene.
  - 14: which water shading runs on the front layer.
- Terrain debug view 11: red where a solid block's derived normal isn't axis-aligned.

## 0.1.0-alpha.23

### Added
- **Smooth Block Light** (on by default, in Lighting & Shadows). Torchlight now fades smoothly across walls and floors.
  - **Before:** vanilla's smooth lighting works out each face separately, so neighbouring faces disagree at their edges. That leaves block-sized patches, strongest beside walls, and the HDR torch curve made every step visible.
  - **How:** Celestia now copies each section's block light from the client light engine into a 256×128×256-block volume around the camera and filters it per pixel. Only open cells are counted, so walls never darken the corners next to them.
  - **Coverage:** vanilla terrain, Sodium terrain and water. Outside the volume, the vertex light is used as before.
  - **Light changes:** a new `ClientChunkCache.onLightUpdate` hook keeps the volume current when a torch is placed or broken.

### Fixed
- **Coloured block light didn't show in-game.** Section reads used `PalettedContainer.getAll`, which in 26.3 visits each palette entry once rather than every cell. The volume got only a few block IDs per section, so placed lights rarely landed where they belonged. Sections are now read cell by cell, with the last block's ID reused for runs of the same block. Soul lanterns, redstone, copper, amethyst and sea lanterns now light their surroundings in their colour, on vanilla terrain and with Sodium.
- **Orange stripes along inside corners under coloured light.** The volume is now read half a block in front of each face, in the open cell vanilla's own light comes from. Before, it was read on the surface, where the filter blended in cells inside the block.
- **Coloured light edges.** The boosted lights, such as redstone and amethyst, spread further than vanilla's own light so their colour shows. Their glow is no longer cut off where vanilla's light reaches 0; that cut showed as a hard contour. The coloured volume is now also filtered over lit cells only, which removes the small orange patches where two walls meet the floor.
- F3 `Colour N` now counts the volume sections near coloured lights. It used to count only sections still spreading, which reads 0 once the light settles.

### Added
- Terrain debug views (`ShadeFrame.debug`):
  - 7: the coloured volume's light level, with red where the bound header is off.
  - 8: the colour shift the volume adds.
  - 9: the block light the shading uses.
  - 10: the vertex colour (vanilla AO).
- Native ABI 10 adds `cm_cl_levels` and smooth-light uploads in `cm_cl_frame`. The volume is bound at texture 28.
- Native Test 2r also covers the in-game window layout (16×8×16 fine sections at world coordinates near 1000, with a 12×4×12 coarse window) and the smooth block light filter. Halfway between levels 10 and 6 it reads 8/15, and beside an opaque row it reads 10/15.

### Verified in-game
- Isolated QA clients with a scripted probe mod ran through closed test rooms lit only by block light.
- **Vanilla 26.3 and Sodium 0.9.3-beta.1:** coloured lights show their colours, and so do the held torch, the blaze and dropped glowstone. Every preset rendered, and Dynamic Lights and Coloured Block Lights switch on and off live.
- **Heavily modded instance (110 mods, including Create and Alex's Caves):** a copy of the mod list with this build loads on Metal 4 with no resource-reload failure, and every scripted scene renders.

## 0.1.0-alpha.22

### Added
- **P6b coloured block light**. Placed lights tint their surroundings in their own colour: soul fire and soul lanterns blue, redstone red, copper torches and lanterns green, nether portals, crying obsidian and amethyst purple, froglights green and pink, and sea lanterns and conduits cyan. Light spreads block by block through a 256×128×256-block volume around the camera, with a coarser volume beyond it out to the render distance. Opaque blocks stop it, and where two colours meet they mix.
- Terrain, water seen from above, and entities take the colour. Each pixel reads the volume at its exact world block, so the colour stays stable far from the world origin.
- New Lighting & Shadows options: Coloured Block Lights, Coloured Light Strength, and Coloured Light Glow, which gives dim coloured lights such as redstone more reach. They apply live. Turning the module off frees its roughly 50 MB of volumes.
- F3 shows how many volume sections are still spreading as `Colour N` in the Celestia shader status line.
- Native Test 2r checks the fallback bindings, the soul-fire colour in front of a wall, no light behind it, and strength 0 on Metal 4 and Metal 3.

### Changed
- Native ABI 9 adds the `cm_cl_*` entry points. Buffer slot 30 and texture slots 26–27 now carry the coloured light.

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
