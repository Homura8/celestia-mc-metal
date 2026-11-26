package dev.celestia.metal.mixin;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.perf.PerformanceEngine;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Updates per-frame telemetry and uploads frame uniforms to the Metal shader runtime.
 */
@Mixin(GameRenderer.class)
public final class GameRendererMixin {
    @Unique
    private long celestiametal$frameStartNs;

    @Inject(method = "render", at = @At("HEAD"))
    private void celestiametal$onFrameBegin(CallbackInfo ci) {
        celestiametal$frameStartNs = System.nanoTime();
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            ShaderPipelineManager.get().uploadFrameUniforms(dev);
        }
    }

    @Inject(method = "render", at = @At("RETURN"))
    private void celestiametal$onFrameEnd(CallbackInfo ci) {
        if (celestiametal$frameStartNs != 0L) {
            double ms = (System.nanoTime() - celestiametal$frameStartNs) / 1_000_000.0;
            PerformanceEngine.get().onFrameEnd(ms);
        }
    }
}
