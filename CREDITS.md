# Credits & Attributions

Celestia Metal is an independent, Apple Silicon-first Metal 4 / Metal 3 rendering engine and native MSL shader ecosystem for Minecraft: Java Edition 26.3. It builds on engineering breakthroughs discovered across the Minecraft Apple Silicon Metal open-source community.

We gratefully acknowledge and preserve attribution for the following projects and authors:

## Metal Rendering & Apple Silicon Architecture

- **[Pure Metal](https://github.com/imCinq/pure-metal)** by **imCinq** (`Apache-2.0`)
  - Clean `com.mojang.renderpearl` backend architecture, SPIRV-Cross MSL vertex Y-flip + slot-binding model, deferred resource retirement across in-flight submits, selective relaxed math for terrain shaders, MetalFX scaling architecture, StartupGuard crash-loop isolation, and the non-blocking MAILBOX-style present queue with present credits (adapted in `cm_surface.m`).
- **[mcopt](https://github.com/noahdunnagan/mcopt)** by **Noah Dunnagan** (`Apache-2.0`)
  - Pioneering Apple Silicon Metal rendering patterns, buffer pooling, native draw batching, chunk upload pacing, and macOS QoS/thermal tuning.
- **[Cadence](https://github.com/BattledGamerCF/Cadence)** by **BattledGamerCF** (`Apache-2.0`)
  - Metal 4 (`MTL4CommandQueue`, `MTL4Compiler`, `MTLResidencySet`) lifetime tracking and retirement discipline, combined backend + shader-loader ergonomics, and battery/thermal awareness concepts.
- **[Mine2Metal](https://github.com/HoshizoraAkira/Mine2Metal)** by **HoshizoraAkira** (`MIT`)
  - Metal 4 residency tracking patterns, G-buffer + deferred lighting + dual Kawase bloom + EDR/HDR highlight concepts in native MSL.
- **[Minecraft Metal Renderer](https://github.com/Kausik-Velaga/minecraft-metal-renderer)** by **Kausik Velaga** (`MIT`)
  - Clean separation between backend device layer and shader-pack loading/pass scheduling.
- **[Metallum](https://github.com/kokodio/metallum)** by **kokodio** (`MIT`) & **[Graft](https://github.com/korendotcs/Graft)** by **korendotcs** (`LGPL-3.0`)
  - Early RenderPearl Metal backend exploration and multi-version compatibility lessons.

## Native MSL Shaders & Shader Ecosystem

- **[Minecraft Metal Shaders](https://github.com/GaelQuinta/minecraft-metal-shaders)** by **GaelQuinta** & contributors (`Apache-2.0`)
  - Native MSL shader suite (`mcopt-shade`, upstream commit `dd32304d`) ported onto Celestia Metal's RenderPearl backend: `ShadeFrame` / `ShadeLook` / `ShadeGpu` / `ShadeResources` architecture, `dir.y = v²` sky-view LUT mapping avoiding `asin`, Lottes filmic tone curve + exact `shadeLdrToHdr` inverse, PCSS-lite shadows and reversed-Z cascade conventions, sky-light early-out skipping shadow samples in caves, water SSR/refraction/caustics, volumetric clouds/VL, and TAAU. Every ported file carries `// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): <original path>`.
  - Incorporates upstream MIT-licensed techniques/portions preserved in `NOTICE` and `LICENSES/MIT-Photon.txt`:
    - **[Photon Shaders](https://github.com/sixthsurge/photon)** by **Benjamin Stott ("sixthsurge")** (`MIT`, `LICENSES/MIT-Photon.txt`) — volumetric clouds, air-mode volumetric light, and golden-hour mist formulas.
    - **[SE Natural Bloom & Dirty Lens](https://github.com/sonicether/SE-Natural-Bloom-Dirty-Lens)** by **sonicether** (`MIT`) — energy-conserving bloom composite concept.
    - **5-tap Catmull-Rom bicubic filter** by **Matt Pettineo (MJP)** (`MIT`) — history/upscale tap pattern.
- **[Ciderlight](https://github.com/riccqi/ciderlight)** by **riccqi** (`Apache-2.0`)
  - Modular MSL shader passes, native binding cache deduplication, and automated MSL shader unit-check methodology.
- **[SiliconShaders](https://github.com/rellefnediew/SiliconShaders)** by **rellefnediew** (`Apache-2.0`)
  - Dual-view shader configuration architecture (Player Select vs Creator Edit, presets, live preview, categorized options).

## Interface & Design

- **[Reese's Sodium Options](https://github.com/FlashyReese/reeses-sodium-options)** by **FlashyReese** (`MIT`)
  - Tabbed, searchable video settings layout with contextual tooltips and performance impact indicators.
- **[CelestiaGlow](https://github.com/Homura8/celestiaglow)** by **Homura8**
  - Frosted observatory aesthetic, dark violet-slate surfaces (`#211e30`, `#2e283f`), lavender accents (`#c8b3e4`, `#e0cdef`), 1px glass rims, and star-sparkle `✦` visual identity.
- **[Iris Shaders](https://github.com/IrisShaders/Iris)** (`LGPL-3.0`) & **[Leadlight](https://github.com/simply-sunny/leadlight)** (`LGPL-3.0`)
  - OptiFine/Iris shader pack directory, `shaders.properties`, and `.zip.txt` option format conventions.
