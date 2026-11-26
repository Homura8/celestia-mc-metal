package dev.celestia.metal.mixin;

import java.util.Map;
import net.minecraft.client.gui.components.debug.DebugScreenEntryList;
import net.minecraft.client.gui.components.debug.DebugScreenEntryStatus;
import net.minecraft.resources.Identifier;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Shows the Celestia Metal F3 entry by default.
 *
 * <p>Minecraft 26.3 only displays debug entries listed in the active {@code DebugScreenProfile} or the
 * user's saved custom F3 layout; anything else defaults to {@code NEVER}. Both paths populate statuses
 * through {@code resetStatuses}, so the entry is added there as {@code IN_OVERLAY} unless the user
 * already chose a status for it (e.g. hid it via F3+F6), which is preserved.
 */
@Mixin(DebugScreenEntryList.class)
public abstract class DebugScreenEntryListMixin {
    @Unique
    private static final Identifier CELESTIA_DEBUG_ID = Identifier.fromNamespaceAndPath("celestiametal", "status");

    @Shadow
    @Final
    private Map<Identifier, DebugScreenEntryStatus> allStatuses;

    @Inject(method = "resetStatuses", at = @At("TAIL"))
    private void celestiametal$showByDefault(Map<Identifier, DebugScreenEntryStatus> statuses, CallbackInfo ci) {
        allStatuses.putIfAbsent(CELESTIA_DEBUG_ID, DebugScreenEntryStatus.IN_OVERLAY);
    }
}
