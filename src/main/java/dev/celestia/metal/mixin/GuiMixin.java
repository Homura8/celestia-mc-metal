package dev.celestia.metal.mixin;

import dev.celestia.metal.ui.CelestiaVideoSettingsScreen;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.Gui;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.VideoSettingsScreen;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

/**
 * Replaces vanilla {@link VideoSettingsScreen} with {@link CelestiaVideoSettingsScreen} unless
 * explicitly bypassed from the Advanced tab.
 */
@Mixin(Gui.class)
public abstract class GuiMixin {
    @Shadow @Final private Minecraft minecraft;
    @Shadow private Screen screen;

    @ModifyVariable(method = "setScreen", at = @At("HEAD"), argsOnly = true)
    private Screen celestiametal$replaceVideoSettings(Screen nextScreen) {
        if (nextScreen instanceof VideoSettingsScreen) {
            if (this.screen instanceof CelestiaVideoSettingsScreen cv && cv.shouldBypassReplacement()) {
                return nextScreen;
            }
            return new CelestiaVideoSettingsScreen(this.screen, this.minecraft.options);
        }
        return nextScreen;
    }
}
