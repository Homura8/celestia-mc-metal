package celestiaqa.mixin;

import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Drives the QA script once per client tick. The logic lives in celestiaqa.Qa (Mixin forbids non-mixin code here). */
@Mixin(Minecraft.class)
public abstract class TickHook {
    @Inject(method = "tick()V", at = @At("TAIL"))
    private void celestiaqa$tick(CallbackInfo ci) {
        celestiaqa.Qa.tick((Minecraft) (Object) this);
    }
}
