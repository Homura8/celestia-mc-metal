package dev.celestia.metal.mixin;

import com.llamalad7.mixinextras.sugar.Local;
import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.renderpearl.api.commands.CommandEncoder;
import com.mojang.renderpearl.api.textures.GpuTexture;
import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.perf.PerformanceEngine;
import dev.celestia.metal.render.TemporalUpscaler;
import dev.celestia.metal.render.WorldRenderScale;
import dev.celestia.metal.shade.CelestiaShade;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.GameRenderer;
import net.minecraft.client.renderer.state.OptionsRenderState;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.state.level.PlayerRenderState;
import org.joml.Matrix4f;
import org.joml.Vector4fc;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Mutable;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Per-frame telemetry, frame uniforms for the Metal shader runtime, and world render scale
 * (see {@link WorldRenderScale}).
 */
@Mixin(GameRenderer.class)
public final class GameRendererMixin {
    @Shadow @Final @Mutable private RenderTarget mainRenderTarget;
    @Shadow @Final @Mutable private RenderTarget hud3DTarget;
    @Shadow @Final private Minecraft minecraft;

    @Unique private long celestiametal$frameStartNs;
    @Unique private RenderTarget celestiametal$fullMain;
    @Unique private RenderTarget celestiametal$fullHud;

    @Inject(method = "render", at = @At("HEAD"))
    private void celestiametal$onFrameBegin(CallbackInfo ci) {
        // Never start a frame with the scaled targets still installed (e.g. an exception last frame).
        celestiametal$restoreTargets();
        celestiametal$frameStartNs = System.nanoTime();
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            dev.shade().onFrameEnd();
            ShaderPipelineManager.get().uploadFrameUniforms(dev);
        }
    }

    @Redirect(method = "render", at = @At(value = "INVOKE",
        target = "Lcom/mojang/renderpearl/api/commands/CommandEncoder;clearColorAndDepthTextures(Lcom/mojang/renderpearl/api/textures/GpuTexture;Lorg/joml/Vector4fc;Lcom/mojang/renderpearl/api/textures/GpuTexture;D)V"))
    private void celestiametal$recordFrameClear(CommandEncoder encoder, GpuTexture color, Vector4fc clear,
                                                GpuTexture depth, double depthValue) {
        encoder.clearColorAndDepthTextures(color, clear, depth, depthValue);
        WorldRenderScale.rememberClear(clear, depthValue);
    }

    @Inject(method = "render", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/GameRenderer;preparePostEffects(Ljava/util/List;)V", ordinal = 0))
    private void celestiametal$beginScaledWorld(CallbackInfo ci) {
        RenderTarget[] scaled = WorldRenderScale.begin(minecraft, mainRenderTarget, hud3DTarget);
        if (scaled == null) return;
        celestiametal$fullMain = mainRenderTarget;
        celestiametal$fullHud = hud3DTarget;
        mainRenderTarget = scaled[0];
        if (scaled[1] != null) hud3DTarget = scaled[1];
    }

    @Inject(method = "render", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/GameRenderer;applyPostEffects()V", shift = At.Shift.AFTER))
    private void celestiametal$endScaledWorld(CallbackInfo ci) {
        if (celestiametal$fullMain == null) return;
        RenderTarget full = celestiametal$fullMain;
        celestiametal$restoreTargets();
        WorldRenderScale.end(full);
    }

    @Inject(method = "resize", at = @At("TAIL"))
    private void celestiametal$onResize(int width, int height, CallbackInfo ci) {
        WorldRenderScale.onWindowResize(width, height);
    }

    @Inject(method = "renderLevel", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/ProjectionMatrixBuffer;getBuffer(Lorg/joml/Matrix4f;)Lcom/mojang/renderpearl/api/buffers/GpuBufferSlice;"))
    private void celestiametal$shadeProjection(CallbackInfo ci, @Local Matrix4f projectionMatrix,
                                                @Local CameraRenderState camera) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        TemporalUpscaler taau = dev != null && WorldRenderScale.isActive() ? dev.temporalUpscaler() : null;
        boolean jittered = taau != null && taau.jitter(projectionMatrix, camera);
        CelestiaShade.recordProjection(projectionMatrix, jittered ? taau.jitterNdcX() : 0f, jittered ? taau.jitterNdcY() : 0f);
    }

    @Inject(method = "render3dHud", at = @At("HEAD"))
    private void celestiametal$captureWorldDepth(CameraRenderState camera, PlayerRenderState player, OptionsRenderState options,
                                                 boolean hasPostEffects, CallbackInfo ci) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null && WorldRenderScale.isActive()) {
            dev.temporalUpscaler().captureDepth(mainRenderTarget, hasPostEffects ? hud3DTarget : mainRenderTarget);
        }
    }

    @Inject(method = "renderLevel", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/GameRenderer;render3dHud(Lnet/minecraft/client/renderer/state/level/CameraRenderState;Lnet/minecraft/client/renderer/state/level/PlayerRenderState;Lnet/minecraft/client/renderer/state/OptionsRenderState;Z)V"))
    private void celestiametal$shadeBeforeHand(CallbackInfo ci) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) dev.shade().beforeHand(this.mainRenderTarget);
    }

    @Inject(method = "renderLevel", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/GameRenderer;render3dHud(Lnet/minecraft/client/renderer/state/level/CameraRenderState;Lnet/minecraft/client/renderer/state/level/PlayerRenderState;Lnet/minecraft/client/renderer/state/OptionsRenderState;Z)V",
        shift = At.Shift.AFTER))
    private void celestiametal$shadeAfterHand(CallbackInfo ci) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) dev.shade().afterHand();
    }

    @Inject(method = "renderLevel", at = @At("RETURN"))
    private void celestiametal$shadeRenderLevelEnd(CallbackInfo ci) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            dev.shade().finishWorld(this.mainRenderTarget);
            dev.shade().afterHand();
        }
    }

    @Inject(method = "render", at = @At(value = "INVOKE",
        target = "Lnet/minecraft/client/renderer/fog/FogRenderer;endFrame()V"))
    private void celestiametal$shadeFallbackFinish(CallbackInfo ci) {
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            dev.shade().finishWorld(this.mainRenderTarget);
        }
    }

    @Inject(method = "render", at = @At("RETURN"))
    private void celestiametal$onFrameEnd(CallbackInfo ci) {
        celestiametal$restoreTargets();
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        if (dev != null) {
            dev.shade().onFrameEnd();
        }
        if (celestiametal$frameStartNs != 0L) {
            double ms = (System.nanoTime() - celestiametal$frameStartNs) / 1_000_000.0;
            PerformanceEngine.get().onFrameEnd(ms);
        }
    }

    @Unique
    private void celestiametal$restoreTargets() {
        if (celestiametal$fullMain != null) {
            mainRenderTarget = celestiametal$fullMain;
            celestiametal$fullMain = null;
        }
        if (celestiametal$fullHud != null) {
            hud3DTarget = celestiametal$fullHud;
            celestiametal$fullHud = null;
        }
    }
}
