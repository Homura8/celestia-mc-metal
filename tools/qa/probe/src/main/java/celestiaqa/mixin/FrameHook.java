package celestiaqa.mixin;

import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Per rendered frame (frame capture mode, frame-counted waits). */
@Mixin(Minecraft.class)
public abstract class FrameHook {
    @Inject(method = "renderFrame(Z)V", at = @At("TAIL"))
    private void celestiaqa$frame(CallbackInfo ci) {
        celestiaqa.Qa.frame((Minecraft) (Object) this);
    }
}
