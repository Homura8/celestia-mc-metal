package dev.celestia.metal.mixin;

import dev.celestia.metal.shade.light.ColorLights;
import net.minecraft.client.multiplayer.ClientChunkCache;
import net.minecraft.core.SectionPos;
import net.minecraft.world.level.LightLayer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Block-light changes from the client light engine into the smooth block light volume (ColorLights): a torch placed or broken
 * relights neighbouring sections without any block in them changing, so the block / section hooks alone would miss them.
 */
@Mixin(ClientChunkCache.class)
abstract class ColorLightChunkCacheMixin {
	@Inject(method = "onLightUpdate", at = @At("HEAD"))
	private void celestiametal$blockLightChanged(LightLayer layer, SectionPos pos, CallbackInfo ci) {
		if (layer == LightLayer.BLOCK) ColorLights.lightChanged(pos.x(), pos.y(), pos.z());
	}
}
