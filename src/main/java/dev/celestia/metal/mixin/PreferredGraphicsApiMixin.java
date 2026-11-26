package dev.celestia.metal.mixin;

import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.device.GpuBackend;
import dev.celestia.metal.backend.CelestiaMetalBackend;
import dev.celestia.metal.backend.StartupGuard;
import java.util.concurrent.atomic.AtomicBoolean;
import net.minecraft.client.PreferredGraphicsApi;
import org.slf4j.Logger;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Prefers Celestia Metal when Graphics API is set to Default, leaving Vulkan and OpenGL as fallbacks.
 */
@Mixin(PreferredGraphicsApi.class)
public final class PreferredGraphicsApiMixin {
    @Unique
    private static final Logger CELESTIA_LOGGER = LogUtils.getLogger();
    @Unique
    private static final AtomicBoolean LOGGED_NON_DEFAULT = new AtomicBoolean();

    @Inject(method = "getBackendsToTry", at = @At("RETURN"), cancellable = true)
    private void celestiametal$preferMetal(CallbackInfoReturnable<GpuBackend[]> cir) {
        PreferredGraphicsApi self = (PreferredGraphicsApi) (Object) this;
        StartupGuard.begin(self, null);
        if (self != PreferredGraphicsApi.DEFAULT) {
            if (LOGGED_NON_DEFAULT.compareAndSet(false, true)) {
                CELESTIA_LOGGER.info("Celestia Metal skipped because Graphics API is set to {} in Video Settings", self);
            }
            return;
        }
        String unsupported = CelestiaMetalBackend.unsupportedReason();
        if (unsupported != null) {
            CELESTIA_LOGGER.info("Celestia Metal unavailable ({}); falling back to vanilla backend", unsupported);
            return;
        }
        GpuBackend[] vanilla = cir.getReturnValue();
        GpuBackend[] merged = new GpuBackend[vanilla.length + 1];
        merged[0] = new CelestiaMetalBackend();
        System.arraycopy(vanilla, 0, merged, 1, vanilla.length);
        cir.setReturnValue(merged);
    }
}
