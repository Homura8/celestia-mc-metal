package dev.celestia.metal.mixin;

import dev.celestia.metal.backend.StartupGuard;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import java.io.File;
import net.minecraft.client.GameLoadCookie;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Handles startup guard completion and initial shader pack compilation once the client finishes loading.
 */
@Mixin(Minecraft.class)
public abstract class MinecraftMixin {
    @Shadow @Final public File gameDirectory;

    @Inject(method = "onGameLoadFinished", at = @At("TAIL"))
    private void celestiametal$onLoaded(GameLoadCookie cookie, CallbackInfo ci) {
        StartupGuard.markStartupSuccess(gameDirectory.toPath());
        CelestiaConfig.get();
        ShaderPipelineManager.get().refreshPacks();
        ShaderPipelineManager.get().compileActivePackIfNeeded(false);
    }
}
