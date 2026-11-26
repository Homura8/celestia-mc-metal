// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/light/DynLightConfig.java
//
/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package dev.celestia.metal.shade.light;

import dev.celestia.metal.shade.ShadeShaderPatcher;

/**
 * Dynamic light flags. Celestia: system properties {@code celestiametal.shade.dynLights.*} (upstream {@code mcopt.shade.*}),
 * read once at startup; the live values (strength, hand, others, range, max, flicker) are set every frame from the
 * Celestia Native settings by {@link #applyLive} (upstream read them through its {@code Live} properties).
 * (1.1) max, range, strength, spec, entity, hand, others and flicker are read live (every frame, through Live; the startup
 * value below is the default and the clamp is the same); the module, the volumes, the occlusion and the entities' vertex
 * stages stay startup switches (they decide the shaders and the buffers).
 * <ul>
 * <li>{@code mcopt.shade.dynLights} (true): the module. false = M2.1's shaders byte for byte (no define, no bindings).</li>
 * <li>{@code mcopt.shade.dynLights.max} (64): lights per frame (the nearest / strongest win; the local player's hands first).
 * (1.1) live 1..64: a cap only, the buffers stay sized for 64.</li>
 * <li>{@code mcopt.shade.dynLights.range} (48): blocks around the camera lights are gathered from.</li>
 * <li>{@code mcopt.shade.dynLights.volumes} (preset: 8 / 16 / 24 / 32): lights that get a visibility volume (no light through
 * walls); the rest light without occlusion (they are the weakest or farthest).</li>
 * <li>{@code mcopt.shade.dynLights.occlusion} (true): visibility volumes and the block occupancy behind them.</li>
 * <li>{@code mcopt.shade.dynLights.occBudgetUs} (300): CPU time per frame for refreshing the block occupancy.</li>
 * <li>{@code mcopt.shade.dynLights.strength} (1): overall strength; {@code .spec} (1) the glint on water; {@code .entity} (1)
 * the strength on entities, items, block entities and particles.</li>
 * <li>{@code mcopt.shade.dynLights.entities} (true): the game's own vertex stages (entities, items, block entities, particles,
 * text) get the lights in the HDR world target (DynLightMsl).</li>
 * <li>{@code mcopt.shade.dynLights.hand} (true): the local player's first-person hand and body take the light of what it holds.</li>
 * <li>{@code mcopt.shade.dynLights.others} (true): light from other entities (mobs, items, projectiles...); false = only the
 * local player's hands.</li>
 * <li>{@code mcopt.shade.dynLights.flicker} (true): gentle flicker for fire-like lights.</li>
 * <li>{@code mcopt.shade.dynLights.log} (false): a line every 2 s (lights, volumes, occupancy, CPU time).</li>
 * </ul>
 */
public final class DynLightConfig {
	public static final boolean ENABLED = flag("celestiametal.shade.dynLights", true);
	public static final int MAX = clamp(Integer.getInteger("celestiametal.shade.dynLights.max", 64), 1, 64);
	public static final float RANGE = floatFlag("celestiametal.shade.dynLights.range", 48f, 8f, 60f);
	public static final boolean OCCLUSION = flag("celestiametal.shade.dynLights.occlusion", true);
	public static final int VOLUMES = OCCLUSION ? clamp(Integer.getInteger("celestiametal.shade.dynLights.volumes", 16), 1, 64) : 0;
	/** Lights farther than this from the camera get no visibility volume (their volume must fit the occupancy window). */
	public static final float VOLUME_RANGE = 40f;
	public static final int OCC_BUDGET_US = clamp(Integer.getInteger("celestiametal.shade.dynLights.occBudgetUs", 300), 20, 20000);
	public static final float STRENGTH = floatFlag("celestiametal.shade.dynLights.strength", 1f, 0f, 4f);
	public static final float SPEC = floatFlag("celestiametal.shade.dynLights.spec", 1f, 0f, 4f);
	public static final float ENTITY = floatFlag("celestiametal.shade.dynLights.entity", 1f, 0f, 4f);
	public static final boolean ENTITIES = flag("celestiametal.shade.dynLights.entities", true);
	public static final boolean HAND = flag("celestiametal.shade.dynLights.hand", true);
	public static final boolean OTHERS = flag("celestiametal.shade.dynLights.others", true);
	public static final boolean FLICKER = flag("celestiametal.shade.dynLights.flicker", true);
	public static final boolean LOG = flag("celestiametal.shade.dynLights.log", false);

	private DynLightConfig() {
	}

	static boolean flag(String key, boolean fallback) {
		String v = System.getProperty(key);
		return v == null ? fallback : Boolean.parseBoolean(v.trim());
	}

	static float floatFlag(String key, float fallback, float min, float max) {
		try {
			String v = System.getProperty(key);
			return v == null ? fallback : Math.max(min, Math.min(max, Float.parseFloat(v.trim())));
		} catch (NumberFormatException e) {
			return fallback;
		}
	}

	private static int clamp(int v, int min, int max) {
		return Math.max(min, Math.min(max, v));
	}

	// Live values (upstream: Live properties read every frame). Defaults = the startup flags; CelestiaShade.beginWorld
	// overwrites them from the Celestia Native settings each frame through applyLive.
	private static volatile int liveMax = MAX;
	private static volatile float liveRange = RANGE, liveStrength = STRENGTH, liveSpec = SPEC, liveEntity = ENTITY;
	private static volatile boolean liveHand = HAND, liveOthers = OTHERS, liveFlicker = FLICKER;

	/** Applies this frame's settings (all clamped exactly like the startup flags). */
	public static void applyLive(int max, float range, float strength, boolean hand, boolean others, boolean flicker) {
		liveMax = clamp(max, 1, 64);
		liveRange = Math.max(8f, Math.min(60f, range));
		liveStrength = Math.max(0f, Math.min(4f, strength));
		liveHand = hand;
		liveOthers = others;
		liveFlicker = flicker;
	}

	static int max() {
		return liveMax;
	}

	static float range() {
		return liveRange;
	}

	static float strength() {
		return liveStrength;
	}

	static float spec() {
		return liveSpec;
	}

	static float entity() {
		return liveEntity;
	}

	static boolean hand() {
		return liveHand;
	}

	static boolean others() {
		return liveOthers;
	}

	static boolean flicker() {
		return liveFlicker;
	}

	static String describe() {
		return "max " + MAX + ", range " + RANGE + ", volumes " + VOLUMES + ", entities " + ENTITIES + ", hand " + HAND + ", others " + OTHERS
			+ (STRENGTH != 1f ? ", strength " + STRENGTH : "");
	}

	/** dynlight.metal's kernels + dynlight_vis.metal, the module's own library (DynLights.init). */
	public static String source() {
		return "#define SHADE_DL_KERNELS\n" + ShadeShaderPatcher.resource("dynlight.metal") + "\n" + ShadeShaderPatcher.resource("dynlight_vis.metal");
	}
}
