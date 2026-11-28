# In-game QA

Run the probe on an Apple Silicon Mac with Java 25 and a graphical login session. The examples below use Homebrew’s Java 25. Loom uses the Minecraft 26.3 assets in the Gradle user home. If the assets are missing, run `./gradlew downloadAssets` first. The runner uses the Gradle daemon and launches the built Fabric mod JAR in an isolated game directory.

```sh
export JAVA_HOME="$(brew --prefix openjdk@25)"
tools/qa/run.sh shots
tools/qa/run.sh shots,frames
```

The first launch creates the `CelestiaQA` world with seed `20261128` and builds the floating pond. The runner saves a world template in `build/qa/world/` and restores a copy before each later launch. It resets the game options and Celestia settings from `tools/qa/template/`, and retains `build/qa/run/config/celestia-metal-pipelines.metallibcache` for warm starts. `./gradlew clean` clears `build/qa/` along with the rest of the build output.

Set `QA_LABEL` to name the output directory under `build/qa/`. The default label includes the modes and a timestamp. Each output directory contains `client.log` and any PNGs resized to a maximum of 1100 pixels on the long edge. The game directory retains its capture PNGs until the next launch. On Retina displays, descent frames can be downsampled before PNG encoding while still meeting the exported resolution. The runner waits for screenshot writes and checks the number of files before exporting. Keep the game window visible for rendering and frame capture.

## Reviewing results with agents

The runner prints a compact summary and saves it to `summary.txt`. Set `QA_VERBOSE=1` when you need the live client log. When visual inspection is needed, open the single `review.jpg` contact sheet. Use its labels to open individual PNGs for specific findings. The full capture sequence, pass breakdowns and client log are available for targeted follow-up.

## Modes

| Mode | Coverage | Output |
| --- | --- | --- |
| `shots` | Twenty-two fixed views: the test pond, landscape, underwater, a real plains village on the coast (houses, paths, grass, trees, docks and the bay), Nether and End. Rain runs last in the Overworld. | One PNG per scene, with the wait and GPU time in the log. |
| `profile` | Metal 4 per-encoder timing for each scene and debug token. The runner disables pass merging for these measurements. | `profile.tsv` with the last full `[GPU]` report from each marker window. |
| `perf` | Ultra versus 12 feature overrides, the other three presets and pack off. Each option change settles for 70 ticks, followed by 100 GPU samples. | `perf.txt` with the comparison median, the average of the surrounding Ultra medians and the signed delta, plus an Ultra PNG per scene. |
| `lights` | Six coloured block emitters, a held torch, blaze and dropped glowstone, light toggles, debug views and preset comparisons in sealed rooms. | `lights-*.png` and FPS, average GPU time and active light counts in the log. |
| `packs` | Live world-pack switching on `vista-up` with clouds off: Celestia Native, then the example world pack (`examples/shaderpacks/celestia-example-world`, copied into the run's `shaderpacks/`), a `recompile` option change, back to Native, and one more round once Metal's cache is warm. Fails if the world renderer is not ready after any switch. | `packs-*.png` and `[PACKS]` lines with each switch's rebuild time in the log. |
| `scales` | On the same sunset camera, switch from native to TAAU, to MetalFX Spatial, and back to native. Verify the active upscale path and the sky gradient after each switch. | Four `scales-*.png` captures and sky gradient measurements in the log. |
| `frames` | Spectator descent from above the pond surface, lowering the camera 0.012 blocks per rendered frame. | 180 sequential PNGs by default. |

`profile` defaults to pond morning, underwater and vista sunset, as does `perf`. Profiling waits `2 * every + 5` rendered frames per token. The first report can include submits from before the switch, so the table uses the last report before the next marker. Run `perf` separately for production timing with normal encoder settings. Adjacent A/B/A comparisons share the intervening Ultra window. Both sides of every comparison still use locally measured Ultra medians.

```sh
QA_LABEL=fast tools/qa/run.sh shots
QA_LABEL=fixed tools/qa/run.sh shots -PqaJvm=celestiaqa.fixedShots=true
QA_LABEL=clouds tools/qa/run.sh profile -PqaProfile=120 \
  -PqaJvm=celestiaqa.scenes=vista-sunset,celestiaqa.devs=0,c1,c2,c4,c8
QA_LABEL=water-perf tools/qa/run.sh perf -PqaJvm=celestiaqa.scenes=underwater
QA_LABEL=light-rooms tools/qa/run.sh lights
QA_LABEL=descent tools/qa/run.sh frames -PqaJvm=celestiaqa.frames=180
QA_LABEL=packs tools/qa/run.sh packs
```

Use `QA_RESOURCE_PACK` to stage and enable a resource-pack directory containing `pack.mcmeta`. For labPBR, capture `pond-noon`
with a compatible resource pack and repeat with `-PqaOptions=LAB_PBR=false`. Include `profile` in both runs to compare GPU
pass timings with the same pack and camera.

Use `celestiaqa.repeat=N` (and `celestiaqa.repeatTicks`, default 10) for a burst of N shots per scene, for animated effects such as waves, caustics and underwater shafts. Use `celestiaqa.scenes` to select comma-separated scene names in their declared order. The twenty-two names are `pond-morning`, `pond-noon`, `pond-sunset`, `pond-night`, `underwater`, `underwater-noon`, `underwater-up`, `ground-noon`, `village-noon`, `village-sunset`, `village-night`, `village-high`, `village-shore`, `village-shore-sunset`, `vista-noon`, `vista-sunset`, `vista-up`, `vista-night`, `vista-rain`, `village-rain`, `nether` and `end`. Other JVM properties include `celestiaqa.preset` (default Ultra), `celestiaqa.pack=off`, `celestiaqa.debug=<view>` and `celestiaqa.prefix=<name>`. Pass shader overrides with a dedicated Gradle property, for example `-PqaOptions=GOD_RAYS=false,BLOOM_ENABLED=false`.

Set `celestiaqa.showHud=true` to capture the detailed Celestia performance HUD with FPS and GPU time. Add
`celestiaqa.measureFrames=N` to time N frames at each settled camera. The log records mean FPS,
99th-percentile frame time and the render and output dimensions. Use `celestiaqa.renderScale=70` to render the world at
70% scale with TAAU and keep the HUD and final image at the window's full resolution. Use
`celestiaqa.upscaler=METALFX_SPATIAL` to compare spatial upscaling, or `celestiaqa.frameLimit=60` to check the HUD under a frame cap.
Set `celestiaqa.timedPanYaw=0.14` to turn 0.14 degrees per measured frame without capturing a PNG on every frame.
Set `celestiaqa.renderScale=100` to verify native rendering and `celestiaqa.weatherRadius=N` to override Minecraft's rain
and snow draw radius for the isolated run.

```sh
QA_LABEL=retina tools/qa/run.sh shots \
  -PqaJvm=celestiaqa.scenes=pond-noon,underwater-up,celestiaqa.preset=Balanced,celestiaqa.showHud=true,celestiaqa.measureFrames=300,celestiaqa.renderScale=70
QA_LABEL=underwater-pan tools/qa/run.sh shots,frames \
  -PqaJvm=celestiaqa.scenes=underwater-up,celestiaqa.showHud=true,celestiaqa.panScene=underwater-up,celestiaqa.panYaw=0.45
QA_LABEL=native-retina tools/qa/run.sh shots \
  -PqaJvm=celestiaqa.scenes=pond-noon,pond-sunset,vista-rain,celestiaqa.preset=Performance,celestiaqa.renderScale=100,celestiaqa.weatherRadius=4,celestiaqa.showHud=true,celestiaqa.measureFrames=300,celestiaqa.timedPanYaw=0.14
```

**Real-play performance:** use the `village-*` scenes, not the bare test pond.
- The pond is a worst case: half the screen is water with little else around it.
- The village sits at (-352, 256), 435 blocks from spawn, so add `celestiaqa.fixedShots=true` to give its chunks 240 ticks to load.
- `celestiaqa.commands="cmd1;cmd2"` runs server commands before the modes, 60 ticks apart, with their replies in `client.log`. Use it to find new scene locations in the seed, for example `locate structure minecraft:village_plains`, or `execute positioned X 0 Z positioned over motion_blocking_no_leaves run tp @a ~ ~ ~` after a teleport to read the ground height.

```sh
QA_LABEL=village tools/qa/run.sh shots \
  -PqaJvm=celestiaqa.preset=Quality,celestiaqa.renderScale=100,celestiaqa.fixedShots=true,celestiaqa.measureFrames=300,celestiaqa.timedPanYaw=0.14,celestiaqa.scenes=village-noon,village-sunset,village-night,village-high,village-shore,village-shore-sunset,village-rain
```

Repeat the underwater pan with `-PqaOptions=WATER_REFLECTIONS=SKY_ONLY` to compare against the sky-only reflection path.

The profile tokens are `N` for `celestiametal.shade.water.devSsr`, `bN` for `celestiametal.shade.water.ssrBudget`, `sN` for `celestiametal.shade.dev`, and `cN` for `celestiametal.shade.cloudDev`. The default is `0`. Each token applies one override to the launch settings. Use `s32,s0` to compare the previous chunk-border fog with the directional fade.

For underwater comparisons, `s64` restores the previous Snell window, `s128` disables underwater shafts, and `s192` applies both overrides. Profile `s128,s0,s128` in `underwater` to isolate shaft cost with Volumetric Light Shafts enabled.

## Adding scenes

Add a named scene to `Shots.SCENES` under `tools/qa/probe/` with its time, weather and spectator pose. Keep wet scenes at the end. The normal settle waits for visible section meshes, target rain intensity and a minimum history warm-up. Use `celestiaqa.fixedShots=true` to compare against a 240-tick wait at the same camera angles. Keep each `/fill` below 32,000 blocks. If you change the pond geometry, update the pond marker and regenerate the saved QA world template.

`./gradlew qaProbeJar` builds the standalone probe under `build/qa/probe/`. `check` compiles it without starting Minecraft. `qaClient` can also launch a manually staged instance with `-PqaDir=<game directory>`, including the probe and renderer under its `mods/`. The runner handles staging, templates, world reuse and collecting output automatically.

## Photon reference via Iris

Prepare a reference directory with compatible Iris, Sodium and Fabric API JARs in `mods/`, the Photon ZIP in `shaderpacks/`, and `config/iris.properties` with `enableShaders=true` and `shaderPack=<ZIP filename>`. Supply the Fabric Loader and Sponge Mixin JARs required by that Iris build. The runner stages these files into its own game directory and shares the same world template and camera script.

```sh
QA_REFERENCE_DIR="$reference_dir" QA_LABEL=photon tools/qa/run.sh shots \
  "-PqaLoader=$loader_jar" "-PqaMixin=$mixin_jar" \
  -PqaJvm=celestiaqa.prefix=photon,celestiaqa.fixedShots=true
```

On macOS, check `client.log` for Iris shader pipeline errors. If Photon v1.4 exceeds the OpenGL sampler limit, add `SHADOW_COLOR=false` and `SH_SKYLIGHT=false` to `shaderpacks/photon_v1.4.zip.txt` in the reference directory. Any Photon code or assets incorporated into Celestia must come from MIT commit `26c2906e`. The look roadmap is in [Shader Port Plan §10](SHADER_PORT_PLAN.md#10-photon-look-pass-and-roadmap-alpha25-on).
