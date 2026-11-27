# Celestia Shader Pack Specification (API v1)

Celestia Metal allows shader authors to distribute **native Metal Shading Language (MSL)** shader packs as either a folder or a `.zip` inside Minecraft's `shaderpacks/` directory — independently of the renderer JAR.

A pack is one of two kinds, chosen by the manifest's `"kind"`:

- **World packs** (`"kind": "world"`) replace the world renderer's own MSL: sky, terrain, water, clouds, lighting and post. The bundled **Celestia Native** is a world pack, and any folder or `.zip` in `shaderpacks/` can be one. See [section 5](#5-world-packs-kind-world).
- **Pass packs** (`"kind": "post"`, the default for user packs) add the fullscreen/compute `passes` described in sections 1–4.

Only native MSL packs are listed. Iris/OptiFine GLSL packs are hidden until the GLSL bridge is mature (`-Dcelestiametal.irisPacks=true` lists them for bridge development).
---

## 1. Directory Layout

```text
shaderpacks/
  MyCelestiaPack/              # or MyCelestiaPack.zip
    celestia-shader.json       # Required manifest
    sky_lut.metal              # Modular MSL kernels & fragment shaders
    deferred_lighting.metal
    water_surface.metal
    tonemap_composite.metal
```

---

## 2. Manifest Format (`celestia-shader.json`)

```json
{
  "apiVersion": 1,
  "name": "My Celestia Pack",
  "author": "AuthorName",
  "version": "1.0.0",
  "description": "Short summary shown in the Shader Packs screen.",
  "categories": ["Lighting & Shadows", "Atmosphere", "Water", "Post-Processing"],
  "presets": {
    "Balanced": {
      "SHADOWS_ENABLED": "true",
      "EXPOSURE": "1.05"
    }
  },
  "options": [
    {
      "id": "SHADOWS_ENABLED",
      "label": "Real-Time Shadows",
      "description": "Tooltip text displayed in the right-hand inspector.",
      "category": "Lighting & Shadows",
      "type": "TOGGLE",
      "default": "true",
      "impact": "HIGH"
    }
  ],
  "passes": [
    {
      "name": "sky_lut",
      "stage": "COMPUTE",
      "shader": "sky_lut.metal",
      "entryPoint": "my_sky_lut_cs",
      "scale": 1.0,
      "format": "RGBA16_FLOAT",
      "threadgroupX": 8,
      "threadgroupY": 8
    },
    {
      "name": "tonemap",
      "stage": "FULLSCREEN",
      "shader": "tonemap.metal",
      "entryPoint": "my_tonemap_fs",
      "scale": 1.0,
      "format": "RGBA16_FLOAT"
    }
  ]
}
```

### Supported Option Types
- `TOGGLE`: Emits `#define <ID> 1` or `0`.
- `ENUM`: Emits `#define <ID> <index>` plus `#define <ID>_<VALUE> <index>` for clean `#if` branching.
- `INT_SLIDER`: Emits `#define <ID> <int>` (`min`, `max`, `step`).
- `FLOAT_SLIDER`: Emits `#define <ID> <float>f` (`min`, `max`, `step`).

### Impact Badges
`"NEGLIGIBLE"`, `"LOW"`, `"MEDIUM"`, `"HIGH"`.

---

## 3. Common Prelude (`celestia_common.metal`)

Every native `.metal` pass compiled by Celestia Metal automatically receives:
1. Generated user option `#define` macros at the top.
2. `celestia_common.metal`, providing:
   - `CelestiaFrameUniforms` bound at **`[[buffer(14)]]`** (`viewProj`, `invViewProj`, `prevViewProj`, `shadowViewProjNear`, `shadowViewProjFar`, `cameraPosTime`, `sunDirDaylight`, `weatherState`, `skyColorFrame`, `fogColorElevation`, `fogRanges`, `resolutionParams`, `qualityFlags`).
   - Built-in fullscreen triangle vertex shader **`celestia_fullscreen_vs`** (`CelestiaFullscreenOut`).
   - Reversed-Z world reconstruction: `celestia_reconstruct_world(uv, depth, u)` and `celestia_is_sky(depth)`.
   - Octahedral normal helpers: `celestia_encode_octahedral`, `celestia_decode_octahedral`.
   - `dir.y = v²` Sky LUT sampler: `celestia_sample_sky_lut(lut, samp, dir, sunDir)` (avoids `asin()` in pixel loops).
   - 2-cascade hardware PCF shadow lookup with cave sky-light early-out: `celestia_sample_shadow_pcf(worldPos, skyLight, shadowMap, shadowSamp, u)`.
   - HDR tonemapping helpers: `celestia_tonemap_aces`, `celestia_tonemap_agx`, `celestia_tonemap_filmic`, `celestia_linear_to_srgb`.

---

## 4. Apple Silicon Best Practices (Porting GLSL / Celestia Shaders)

1. **Prefer `half` / `half3` / `half4`** for lighting colors, normals, sky LUT values, bloom, and tonemapping — Apple GPUs execute `half` arithmetic at double throughput with lower register pressure.
2. **Use reversed-Z depth (`near = 1.0`, `far = 0.0`)**: Test sky via `celestia_is_sky(depth)` (`depth <= 1e-5f`) rather than `depth >= 1.0f`.
3. **Early-out underground**: Check `skyLight < 0.02h` before sampling `depth2d_array` shadow cascades.
4. **Compute passes for LUTs & half-res effects**: Run sky scattering LUTs (`64×32`), volumetric clouds (`0.5×`), and dual Kawase bloom in compute kernels (`MTL4ComputeCommandEncoder`) with `access::write` on `RGBA16Float` targets.
5. **Respect EDR headroom**: Read `u.resolutionParams.w` (`edrHeadroom`) to expand specular & sky highlights smoothly on XDR displays without blowing out SDR screens.


---

## 5. World Packs (`"kind": "world"`)

A world pack supplies the MSL the world renderer compiles: what Celestia Native ships in
`src/main/resources/assets/celestiametal/shaderpacks/celestia-native/shaders/`. The engine keeps the Java side (render
passes, buffers, textures, shadow maps, dynamic and coloured light volumes, MetalFX/TAAU) and the ABI the shaders read.
[`examples/shaderpacks/celestia-example-world`](examples/shaderpacks/celestia-example-world) is a minimal, complete
example: Celestia Native with its own `sky.fs.metal` and two compiled-in options.

### Layout

```text
shaderpacks/
  MyWorldPack/                 # or MyWorldPack.zip
    celestia-shader.json       # "kind": "world"
    shaders/
      sky.fs.metal             # any of Celestia Native's file names: replaces that file
      water.metal
```

- **Override by file name.** For each world shader file, the engine reads `shaders/<name>` from the active pack. If the pack does not provide it, the engine uses Celestia Native's. A pack can change one file or all of them.
- **A replaced file keeps its contract.** It must define the functions and entry points the other files and the engine call. The safest start is a copy of Celestia Native's file. Entry points the engine looks up by name:

  | File | Entry points |
  | --- | --- |
  | `sky_lut.metal` | `shade_lut_vs`, `shade_lut_fs` |
  | `shade_post.metal` | `shade_fs_vs`, `shade_bloom_down0`, `shade_bloom_down`, `shade_bloom_up`, `shade_final`, `shade_histogram`, `shade_exposure`, `shade_milkyway_bake`, `shade_ambient_occlusion` |
  | `clouds.metal`, `vl.metal`, `weather_surface.metal` | `shade_cloud_trace`, `shade_cloud_resolve`, `shade_cloud_dome`, `shade_vl_march`, `shade_wx_noise_fs` |
  | `water.metal` | `shade_water_bake_fs`, `shade_water_bake_detail_fs`, `shade_water_bake_swell_fs`, `shade_water_pyr_fs`, `shade_water_pyr2_fs` |
  | `shadow_vanilla.metal` / `shadow_sodium.metal` | `shadow_vanilla_vs`, `shadow_vanilla_cutout_vs`, `shadow_vanilla_cutout_fs` / `shadow_vs`, `shadow_cutout_vs`, `shadow_cutout_fs` |
  | `sky.*`, `celestial.*`, `stars.vs`, `sunrise_sunset.vs`, `clouds.fs` | `main0` (they replace RenderPearl's stages for those pipelines) |
  | `shade_terrain.metal`, `shade_water_terrain.metal`, `shade_entity.metal` | `shadeTerrainShade`, `shadeWaterTerrainShade` / `shadeWaterTerrainOther`, `shadeEntityShade` / `shadeEntityOut` (called from patched RenderPearl terrain, water and entity shaders) |

  Shared helpers live in `shade_look.metal`, `shade_common.metal` and `shade_m2.metal`, which every world source includes.
  The terrain fragment sources also include `shade_material.metal`.
- **Engine-owned files cannot be overridden.** These live in `assets/celestiametal/shaders/engine/`, and a pack copy is ignored:
  - `shade_api.metal`: the buffer layouts the engine writes (`ShadeFrame`, `ShadeLook`, `ShadeGpu`, `ShadeResources`, `ShadeWaterParams`).
  - `shade_slots.metal`: buffer, texture and sampler slots.
  - `vanilla_uniforms.metal`: vanilla uniform blocks.
  - `dynlight*.metal`, `colorlight.metal`: the light-volume kernels and sampling.
  - `taa.metal`: TAAU.

  `CELESTIA_WORLD_API` (currently `1`) names this ABI's version.

### labPBR materials

Celestia Native uses [labPBR 1.3](https://shaderlabs.org/wiki/LabPBR_Material_Standard) companion textures in active Minecraft
resource packs. Place `_n.png` and `_s.png` alongside a block's diffuse texture, for example `textures/block/stone_n.png`
and `textures/block/stone_s.png`. A resource pack can supply either map independently. **Materials > labPBR Materials**
(`LAB_PBR`) is on by default. The material atlases use the block atlas's UVs and reload with the resource packs.

Celestia Native supports tangent-space normals, material AO, smoothness, linear dielectric reflectance, albedo-tinted metals,
emission, wetness porosity and backlighting from subsurface data. Direct specular and sky reflections run in the Overworld.
The renderer uses the first frame of animated companion maps. Height remains available in the normal texture's alpha channel.

World shaders can read `ShadeResources.pbrNormal` and `pbrSpecular` when the corresponding `SHADE_FEATURE_PBR_NORMAL` or
`SHADE_FEATURE_PBR_SPECULAR` bit is set. Empty atlas regions contain zero. A `shadeTerrainShade` override can opt into the
additional `float2 uv` parameter after the pixel position by defining `CELESTIA_TERRAIN_MATERIAL_UV`.

### Options

World pack options use the schema of section 2, with one extra field:

- **Engine options** keep Celestia Native's ids (for example `SHADOWS_ENABLED`, `SHADOW_RES`, `WATER_REFLECTIONS`, `COLOR_LOOK`; see its `celestia-shader.json`). They are read every frame into the engine's settings, with no recompile. Declare one to show it in your pack's options screen. Undeclared engine options keep Celestia Native's defaults.
- **`"recompile": true`** options are compiled into every world shader as `#define`s, generated like section 3's (an `ENUM` gives `ID` = index and `ID_VALUE` = each index). Changing one rebuilds the world shaders. Guard them with `#ifndef` defaults so the file still compiles on its own.

```json
{ "id": "SKY_TINT", "type": "ENUM", "values": ["ROSE", "MINT", "GOLD"], "default": "ROSE", "recompile": true }
```

### Switching and reloading

- Selecting a world pack, changing one of its `recompile` options, or **Reload** (for a user world pack, to pick up edited `.metal` files) rebuilds the world renderer on the next frame:
  - every world library and pipeline is recompiled from the new sources;
  - the old ones are retired, never freed while a frame still uses them;
  - GPU-side state (exposure, sky irradiance) carries over, so the picture does not flash.
- **First switch:** compiling a pack's shaders for the first time takes a few seconds; the game pauses meanwhile. Later switches hit Metal's shader cache and take about 0.1 s on an M1 Pro.
- **Compile errors:** a pack that fails to compile leaves the world on standard rendering, and `latest.log` shows the compiler's message. Switch packs, or fix the file and reload.
- **Testing:** `tools/qa/run.sh packs` switches between Celestia Native and the example pack in game (see [docs/QA.md](docs/QA.md)).
