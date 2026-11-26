package dev.celestia.metal.mixin;

import dev.celestia.metal.perf.PerformanceHud;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.Hud;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Draws the CelestiaGlow Performance HUD pill on the live HUD layer.
 */
@Mixin(Hud.class)
public final class HudMixin {
    @Inject(method = "extractRenderState", at = @At("TAIL"))
    private void celestiametal$renderPerfHud(GuiGraphicsExtractor gui, DeltaTracker delta, CallbackInfo ci) {
        PerformanceHud.render(gui);
    }
}
