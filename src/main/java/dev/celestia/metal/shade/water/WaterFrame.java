// Adapted from Metal Shaders (GaelQuinta, Apache-2.0): metal/src/main/java/mcopt/metal/shade/water/WaterFrame.java
//
// Copyright 2026 mcopt-shade contributors
//
// Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
// License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable
// law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
// OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and
// limitations under the License.
package dev.celestia.metal.shade.water;

import java.util.Arrays;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.block.FluidModel;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;

/**
 * Extracts block-atlas UV bounds for still and flowing water sprites and scans the column above
 * the camera when underwater to supply {@link ShadeWaterParams} with the water surface height.
 */
public final class WaterFrame {
    private WaterFrame() {}

    public static boolean sprites(float[] stillOut, float[] flowOut) {
        try {
            Minecraft mc = Minecraft.getInstance();
            if (mc == null || mc.getModelManager() == null) {
                Arrays.fill(stillOut, 0f);
                Arrays.fill(flowOut, 0f);
                return false;
            }
            FluidModel model = mc.getModelManager().getFluidStateModelSet().get(Fluids.WATER.defaultFluidState());
            if (model == null || model.stillMaterial() == null || model.flowingMaterial() == null) {
                Arrays.fill(stillOut, 0f);
                Arrays.fill(flowOut, 0f);
                return false;
            }
            rect(model.stillMaterial().sprite(), stillOut);
            rect(model.flowingMaterial().sprite(), flowOut);
            return stillOut[2] > 0f;
        } catch (RuntimeException e) {
            Arrays.fill(stillOut, 0f);
            Arrays.fill(flowOut, 0f);
            return false;
        }
    }

    private static void rect(TextureAtlasSprite sprite, float[] out) {
        if (sprite == null) {
            Arrays.fill(out, 0f);
            return;
        }
        out[0] = sprite.getU0();
        out[1] = sprite.getV0();
        out[2] = sprite.getU1();
        out[3] = sprite.getV1();
    }

    /** Camera-relative height of the water surface above the eye (up to 32 blocks). */
    public static float surfaceAbove(ClientLevel level, double x, double y, double z) {
        if (level == null) return 0f;
        BlockPos.MutableBlockPos pos = BlockPos.containing(x, y, z).mutable();
        float top = (float) y;
        for (int i = 0; i < 32; i++) {
            FluidState fluid = level.getFluidState(pos);
            if (!fluid.getType().isSame(Fluids.WATER)) break;
            top = pos.getY() + fluid.getHeight(level, pos);
            pos.move(0, 1, 0);
        }
        return (float) (top - y);
    }

    /** Distance to the still surface in the eye's block when it can intersect the camera's near plane. */
    public static float surfaceJustBelow(ClientLevel level, BlockPos eyeBlock, double eyeY) {
        if (level == null) return 0f;
        FluidState fluid = level.getFluidState(eyeBlock);
        if (!fluid.isSource() || !fluid.getType().isSame(Fluids.WATER)) return 0f;
        double distance = eyeY - ((double) eyeBlock.getY() + fluid.getHeight(level, eyeBlock));
        return distance >= 0.0 && distance <= 0.125 ? Math.max((float) distance, 1e-5f) : 0f;
    }
}
