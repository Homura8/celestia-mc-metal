# Celestia Metal

**An independent, single-JAR, Apple Silicon-first Metal 4 / Metal 3 rendering engine and native MSL shader ecosystem for Minecraft: Java Edition 26.3 (Fabric).**

Celestia Metal replaces Minecraft's legacy OpenGL path with Apple's native **Metal 4** (`MTL4CommandQueue`, `MTL4ArgumentTable`, `MTL4Compiler`, `MTLResidencySet`) on macOS 26+ and **Metal 3** on macOS 15+, paired with an extensible **native Metal Shading Language (MSL) shader pack system**, **MetalFX Spatial & Temporal upscaling**, **HDR / EDR (Display P3)** support, **120 Hz ProMotion** awareness, and a **CelestiaGlow**-inspired frosted observatory UI.

---

## Key Features

- **Single-JAR Installation**: Drop one JAR into `mods/` — no external toolchains, no manual JVM arguments, no Fabric API dependency required, and compatible with Sodium.
- **Metal 4 & Metal 3 Backend (`com.mojang.renderpearl`)**:
  - Java 25 Foreign Function & Memory (`java.lang.foreign`) bridge to `libcelestiametal.dylib`.
  - Unified-memory (`MTLStorageModeShared`) transient ring allocators and size-bucketed buffer pooling.
  - Native multi-draw batching, indirect draws, persistent `MTLBinaryArchive` pipeline caching, and deferred resource retirement tied to `MTLSharedEvent` completion.
  - Automatic SPIR-V → MSL 3.1 translation via LWJGL SPIRV-Cross for vanilla & modded RenderPearl pipelines, with selective relaxed IEEE math for terrain shaders.
- **Apple Silicon Hardware Features**:
  - **MetalFX Spatial & Temporal Upscaling** (`MTL4FXSpatialScaler` / `MTL4FXTemporalScaler` on Metal 4, `MTLFX*` on Metal 3) with optional **Auto Render Scale** (65%–100%).
  - **HDR / EDR Highlights**: `RGBA16Float` Extended Linear Display P3 swapchain with configurable peak luminance.
  - **ProMotion & Thermal / Battery Awareness**: Detects 120 Hz ProMotion displays, macOS thermal state, and Low Power Mode.
  - **Startup Crash Guard**: Protects against crash loops without falsely locking the game into OpenGL if a crash wasn't caused by Metal.
- **Extensible Native MSL Shader Pack Ecosystem (API v1)**:
  - Bundled **`Celestia Native`** (Rayleigh/Mie sky LUT, 2-cascade hardware PCF shadows with cave early-out, SSAO, held-item dynamic lights, Fresnel/SSR water with Beer-Lambert absorption & caustics, half-res volumetric clouds, dual Kawase bloom, AgX/ACES/Filmic HDR tonemapping).
  - Bundled **`Celestia Minimal`** (ultra-lightweight 120 Hz ProMotion & battery-friendly pack).
  - Load third-party native MSL packs or **Iris / OptiFine GLSL packs** from `shaderpacks/` (with `shaders.properties`, `.lang` labels, and `.txt` config compatibility).
  - Hotkeys in-game: **`O`** (Shader Packs), **`K`** (Pause/Resume Shaders), **`R`** (Hot-Reload Shaders).
- **CelestiaGlow Frosted Observatory UI**:
  - Replaces Vanilla Video Settings with a Reese's Sodium Options–inspired tabbed, searchable screen (`General`, `Quality`, `Performance`, `Apple Silicon`, `Shaders`, `Advanced`), integrates cleanly into Sodium 0.9+ / Reese's Sodium Options via Sodium's Config API when Sodium is installed, and includes dedicated Shader Packs and Shader Options screens plus a live Performance HUD pill.

---

## Requirements

- **Mac**: Apple Silicon (`M1` / `M2` / `M3` / `M4` or newer, `Apple7+` GPU family)
- **macOS**: macOS 15+ (Metal 3) or macOS 26+ (Metal 4)
- **Minecraft**: Java Edition **26.3**
- **Loader**: Fabric Loader **0.19.5+**
- **Java**: ARM64 **Java 25** (not x86_64/Rosetta)

---

## Installation

1. Install **Fabric Loader 0.19.5+** for **Minecraft 26.3**.
2. Download `celestia-metal-0.1.0-alpha.12.jar` from Releases (or build with `./gradlew build`).
3. Place the JAR in your instance's `mods/` folder.
4. Launch Minecraft. Celestia Metal activates automatically when **Graphics API** is set to **Default** (press **F3** to check the `Celestia Metal` debug entry).

---

## Measured Apple Silicon GPU Benchmarks (Synthetic Post + Lighting Frame)

Measured via `tools/test_metal_backend.m` (`./gradlew runNativeTests`) on an **Apple M1 Pro (macOS 27.2.1, 120 Hz ProMotion, 16.00x EDR headroom)** rendering full **3024 × 1752** offscreen frames (20 measured iterations after 4 warmup frames, averaging GPU timestamps from `MTL4CommitFeedback` / `MTLCommandBuffer`):

| Shader Pack & Preset | Metal API | Resolution | Avg GPU Time | Post + Lighting Ceiling |
| --- | --- | --- | --- | --- |
| **Celestia Native (Balanced)** | **Metal 4** | 3024 × 1752 | **3.363 ms** | **297.3 FPS** |
| **Celestia Native (Balanced)** | Metal 3 | 3024 × 1752 | 3.486 ms | 286.9 FPS |
| **Celestia Minimal (Crisp)** | **Metal 4** | 3024 × 1752 | **2.474 ms** | **404.2 FPS** |
| **Celestia Minimal (Crisp)** | Metal 3 | 3024 × 1752 | 2.567 ms | 389.6 FPS |

> **Benchmark Scope Note:** These measurements time the full multi-pass compute + fullscreen shader pipeline (sky LUT, deferred lighting with 2-cascade PCF + SSAO, water reflections/refraction, half-res volumetric clouds, bloom downsample, and HDR tonemap composite) on synthetic G-buffer targets. Full in-game frame rates also depend on CPU chunk meshing, terrain vertex throughput, entity count, and render distance.

---

## Building & Testing from Source

Requires ARM64 **JDK 25** and Xcode / Command Line Tools (`clang` with macOS SDK):

```sh
# Build native dylib + single mod JAR + run JUnit 5 tests + privacy check
JAVA_HOME=/opt/homebrew/opt/openjdk@25 ./gradlew build check

# Run live Apple Silicon Metal 4 / Metal 3 GPU verification & 3024x1752 benchmarks
JAVA_HOME=/opt/homebrew/opt/openjdk@25 ./gradlew runNativeTests
```

The output single JAR is written to `build/libs/celestia-metal-0.1.0-alpha.11.jar`.

---

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — Native Metal 4/3 backend, RenderPearl integration, memory & lifetime model, and Phase 2 roadmap.
- [DEVELOPMENT.md](DEVELOPMENT.md) — Engineering retrospective, design rationale, and debugging postmortems across `0.1.0-alpha.1`–`0.1.0-alpha.8`.
- [AGENTS.md](AGENTS.md) — Practical guide for AI agents and contributors (commands, invariants, FFM & Metal 4 pitfalls).
- [SHADER_PACK_SPEC.md](SHADER_PACK_SPEC.md) — Celestia Shader Pack API v1 guide for writing and porting native MSL shader packs (including Celestia Shaders).
- [CREDITS.md](CREDITS.md) — Explicit attributions and licenses for the Apple Silicon Minecraft Metal ecosystem.
- [CHANGELOG.md](CHANGELOG.md) — Release history.

---

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
