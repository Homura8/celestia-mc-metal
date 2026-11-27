# Handoff: in-game QA harness (work in progress)

**Status:** partly moved into the repo. It is **not wired into Gradle yet**, so it doesn't affect the build.

## Done
- **Engine hooks** in `CelestiaShade`:
  - `requestSnap()`: the next frame snaps exposure, atmosphere and temporal histories.
  - `setDebugView(int)`.
- **Probe mod sources** in `tools/qa/probe/src/main/java/celestiaqa/`:
  - `mixin/TickHook`, `mixin/FrameHook`: Minecraft tick and renderFrame hooks.
  - `Qa`: step engine with condition-based `settle()`, QA world creation (seed 20261128) and the floating pond scene.
  - `CelestiaHooks`: the only class that touches Celestia types, so the probe also runs under Iris for Photon reference shots.
  - `Shots`: nine scenes; rain is last.
  - Resources: `fabric.mod.json`, `celestiaqa.mixins.json`.

## To do
1. **Write `celestiaqa/Modes.java`**, used by `Qa`, with `profile`, `perf`, `lights`, `frames` and `onFrame`. Port them from the old session-scratchpad probe (`qarun/PerfRunner.java`, `qa/LightProbe.java`), with these behaviours:
   - **perf:** A/B/A windows. Settle 70 ticks after each option change, sample the GPU time for 100 ticks, take the median. Keep the `[PERF] scene name ultra X this Y delta Z` line format.
   - **profile:** print `[QA] profile <scene> <dev>` before each dev switch, then wait `2*every+5` frames. Parse the last `[GPU]` report before the next marker (the old parser mislabelled reports that straddled a switch).
   - **dev tokens:**
     - `N` sets `celestiametal.shade.water.devSsr`.
     - `bN` sets `ssrBudget`.
     - `sN` sets `celestiametal.shade.dev`.
     - `cN` sets `celestiametal.shade.cloudDev`.
   - **lights:** the coloured and dynamic light rooms near 1000,140,1000. Keep the original waits, because light spread needs them.
   - **frames:** capture every frame while lowering the camera underwater, 180 frames by default.
2. **Write `tools/qa/qa.gradle`** and `apply from` it in `build.gradle`. It needs:
   - A `qa` source set (sources and resources under `tools/qa/probe`), compiled against `main` output plus main's compile classpath.
   - A `qaProbeJar` task.
   - A `qaClient` JavaExec task: KnotClient main class, jvmArgs `-XstartOnFirstThread --enable-native-access=ALL-UNNAMED -Xmx6G`, window `--width 1512 --height 900`, assets from `~/.gradle/caches/fabric-loom/assets` with index `26.3-34`.
   - Properties: `qaDir`, `qaJvm` (k=v,...), `qaLoader` and `qaMixin` (newer Fabric Loader and Mixin jars for Iris), and `qaProfile` (sets env `CELESTIA_GPU_PROFILE=1` and `CELESTIA_GPU_PROFILE_EVERY`, plus `-Dcelestiametal.noPassMerge=true`).
3. **Write `tools/qa/run.sh <modes>`.**
   - **Run folder:** create `build/qa/run/` with `mods` (the mod jar and the probe), plus `options.txt` and `config/celestia-metal.json` from `tools/qa/template/`.
   - **Keep between runs:** `config/celestia-metal-pipelines.metallibcache`, a big startup speed-up that the old scripts deleted every run, and a world template under `build/qa/world/`.
   - **Launch:** pass `--quickPlaySingleplayer CelestiaQA` when the world exists, else `-Dcelestiaqa.create=true`.
   - **Outputs:** resize screenshots with `sips -Z 1100` into `build/qa/<label>/`.
   - **Profile tables:** parse the `[GPU]` lines into a per-scene table.
   - **Daemon:** use the Gradle daemon, not `--no-daemon`.
4. **Templates.** `tools/qa/template/` is empty. Add:
   - `options.txt`: `enableVsync:false`, `maxFps:260`, `inactivityFpsLimit:"minimized"`, `renderDistance:12`, `simulationDistance:5`, `guiScale:2`, `soundCategory_master:0.0`, `onboardAccessibility:false`.
   - `config/celestia-metal.json`: Celestia defaults, `activePreset` Balanced.
5. **Docs.** Write `docs/QA.md` (how to run each mode, outputs, how to add scenes, the Photon reference run via Iris) and add a "QA harness" section to `AGENTS.md`. Then delete this file.
6. **Verify each mode end to end.** Compare shots against fixed-240-tick settles to confirm the condition-based settle loses nothing.

## Rules learned
- **Never `/fill` huge volumes.** A ~175k-block fill froze the client. Keep each fill under 32k blocks.
- **Keep the privacy check passing:** no home paths in committed files.
- **Respect Photon's licence:** use only commit 26c2906e (MIT). v1.4 is a visual reference only.

## Look work state (branch `feat/photon-look-alpha.25`, not pushed)
- **Done:** clouds (3 layers + daily weather), water, Pastel look.
- **Roadmap:** `docs/SHADER_PORT_PLAN.md` section 10. Owner-requested items there include chunk-edge blending.
