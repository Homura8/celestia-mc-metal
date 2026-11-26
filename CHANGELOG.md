# Changelog

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
