package dev.celestia.metal.mixin;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import com.mojang.blaze3d.pipeline.RenderTarget;
import dev.celestia.metal.backend.CelestiaMetalDevice;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.SkyRenderer;
import org.objectweb.asm.Opcodes;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;

@Mixin(SkyRenderer.class)
public abstract class SkyRendererMixin {
    @ModifyExpressionValue(method = "render", at = @At(value = "FIELD",
        target = "Lnet/minecraft/client/renderer/SkyRenderer;renderTarget:Lcom/mojang/blaze3d/pipeline/RenderTarget;",
        opcode = Opcodes.GETFIELD), require = 2)
    private RenderTarget celestiametal$useCurrentWorldTarget(RenderTarget original) {
        // SkyRenderer retains its construction-time target across live render-scale changes.
        return CelestiaMetalDevice.current == null ? original : Minecraft.getInstance().gameRenderer.mainRenderTarget();
    }
}
