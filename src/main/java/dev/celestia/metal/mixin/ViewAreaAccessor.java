package dev.celestia.metal.mixin;

import net.minecraft.client.RotatingSectionStorage;
import net.minecraft.client.renderer.ViewArea;
import net.minecraft.client.renderer.chunk.SectionRenderDispatcher;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Exposes vanilla {@link ViewArea}'s section storage for shadow caster culling when Sodium is absent. */
@Mixin(ViewArea.class)
public interface ViewAreaAccessor {
    @Accessor("sections")
    RotatingSectionStorage<SectionRenderDispatcher.RenderSection> celestiametal$sections();
}
