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
| `shots` | Nine fixed views of the pond and landscape across time of day, underwater and rain. Rain runs last. | One PNG per scene, with the wait and GPU time in the log. |
| `profile` | Metal 4 per-encoder timing for each scene and debug token. The runner disables pass merging for these measurements. | `profile.tsv` with the last full `[GPU]` report from each marker window. |
| `perf` | Ultra versus 12 feature overrides, the other three presets and pack off. Each option change settles for 70 ticks, followed by 100 GPU samples. | `perf.txt` with the comparison median, the average of the surrounding Ultra medians and the signed delta, plus an Ultra PNG per scene. |
| `lights` | Six coloured block emitters, a held torch, blaze and dropped glowstone, light toggles, debug views and preset comparisons in sealed rooms. | `lights-*.png` and FPS, average GPU time and active light counts in the log. |
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
```

Use `celestiaqa.scenes` to select comma-separated scene names in their declared order. The nine names are `pond-morning`, `pond-noon`, `pond-sunset`, `underwater`, `vista-noon`, `vista-sunset`, `vista-up`, `vista-night` and `vista-rain`. Other JVM properties include `celestiaqa.preset` (default Ultra), `celestiaqa.pack=off`, `celestiaqa.debug=<view>` and `celestiaqa.prefix=<name>`. Pass shader overrides with a dedicated Gradle property, for example `-PqaOptions=GOD_RAYS=false,BLOOM_ENABLED=false`.

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
