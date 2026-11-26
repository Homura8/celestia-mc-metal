# Celestia Shader Pack Specification (API v1)

Celestia Metal allows shader authors to distribute **native Metal Shading Language (MSL)** shader packs as either a folder or a `.zip` inside Minecraft's `shaderpacks/` directory — independently of the renderer JAR.

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
