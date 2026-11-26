// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/mixin/shade/ShadeFaceShadeMixin.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.mixin;

import com.llamalad7.mixinextras.injector.ModifyReturnValue;
import dev.celestia.metal.shade.CelestiaShade;
import net.minecraft.client.renderer.chunk.RenderSectionRegion;
import net.minecraft.world.level.CardinalLighting;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;

/**
 * Neutralizes vanilla directional cardinal face shading while CelestiaShade P1 lights terrain faces natively,
 * working identically for both vanilla meshing and Sodium 0.9.x without referencing Sodium types.
 */
@Mixin(RenderSectionRegion.class)
public abstract class ShadeFaceShadeMixin {
    @Unique
    private static volatile CardinalLighting celestiametal$flat;

    @ModifyReturnValue(method = "cardinalLighting", at = @At("RETURN"))
    private CardinalLighting celestiametal$flattenFaceShade(CardinalLighting lighting) {
        if (!CelestiaShade.shouldFlattenVanillaFaceShade() || lighting == null) return lighting;
        CardinalLighting flat = celestiametal$flat;
        float up = lighting.up();
        if (flat == null || flat.up() != up) {
            celestiametal$flat = flat = new CardinalLighting(up, up, up, up, up, up);
        }
        return flat;
    }
}
