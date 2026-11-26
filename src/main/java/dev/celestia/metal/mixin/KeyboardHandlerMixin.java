package dev.celestia.metal.mixin;

import com.mojang.blaze3d.platform.InputConstants;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import dev.celestia.metal.ui.CelestiaShaderPacksScreen;
import net.minecraft.client.KeyboardHandler;
import net.minecraft.client.Minecraft;
import net.minecraft.client.input.KeyEvent;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Provides zero-dependency hotkeys for shaders:
 * - O: Open Celestia Shader Packs screen
 * - K: Toggle active shader pack on/off
 * - R: Hot-reload active shader pack from disk
 */
@Mixin(KeyboardHandler.class)
public final class KeyboardHandlerMixin {
    @Shadow @Final private Minecraft minecraft;

    @Inject(method = "keyPress", at = @At("HEAD"), cancellable = true)
    private void celestiametal$handleShaderHotkeys(long window, int action, KeyEvent event, CallbackInfo ci) {
        if (action != InputConstants.PRESS || minecraft.gui.screen() != null || minecraft.level == null) {
            return;
        }
        int key = event.key();
        if (event.modifiers() == 0) {
            if (key == InputConstants.KEY_O) {
                minecraft.gui.setScreen(new CelestiaShaderPacksScreen(null));
                ci.cancel();
            } else if (key == InputConstants.KEY_K) {
                ShaderPipelineManager.get().toggleShaders();
                ci.cancel();
            } else if (key == InputConstants.KEY_R) {
                ShaderPipelineManager.get().reloadActivePack();
                ci.cancel();
            }
        }
    }
}
