package dev.celestia.metal.mixin;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.perf.PerformanceEngine;
import dev.celestia.metal.render.WorldRenderScale;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import net.minecraft.client.gui.components.debug.DebugScreenDisplayer;
import net.minecraft.client.gui.components.debug.DebugScreenEntries;
import net.minecraft.client.gui.components.debug.DebugScreenEntry;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.chunk.LevelChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Registers the Celestia Metal diagnostic line on Minecraft 26.3's F3 debug screen.
 */
@Mixin(DebugScreenEntries.class)
public abstract class DebugScreenEntriesMixin {
    @Unique
    private static final Identifier CELESTIA_DEBUG_ID = Identifier.fromNamespaceAndPath("celestiametal", "status");

    @Shadow
    private static Identifier register(Identifier id, DebugScreenEntry entry) {
        throw new AssertionError();
    }

    @Inject(method = "<clinit>", at = @At("TAIL"))
    private static void celestiametal$registerDebugEntry(CallbackInfo ci) {
        register(CELESTIA_DEBUG_ID, new DebugScreenEntry() {
            @Override
            public void display(DebugScreenDisplayer displayer, Level level, LevelChunk clientChunk, LevelChunk serverChunk) {
                CelestiaMetalDevice dev = CelestiaMetalDevice.current;
                if (dev == null) return;
                PerformanceEngine perf = PerformanceEngine.get();
                String api = dev.isMetal4() ? "Metal 4" : "Metal 3";
                String shader = ShaderPipelineManager.get().activeDisplayName();
                displayer.addLine(String.format(
                    "Celestia Metal: %s (%s) | GPU %.2f ms | Scale %d%% (%s) | %s | Shader: %s",
                    api, dev.probeInfo().gpuName(), perf.ewmaGpuMs(),
                    perf.effectiveRenderScalePercent(), WorldRenderScale.statusLabel(),
                    perf.thermalLabel(), shader
                ));
                long[] st = dev.lastFrameStats();
                displayer.addLine(String.format(
                    "Celestia Encoders: %d passes -> %d render encoders (%d merged) | %d blit | clears %d folded / %d flushed | %d draws",
                    st[MetalConst.STAT_PASSES_BEGUN], st[MetalConst.STAT_RENDER_ENCODERS], st[MetalConst.STAT_PASSES_MERGED],
                    st[MetalConst.STAT_BLIT_ENCODERS], st[MetalConst.STAT_CLEARS_FOLDED], st[MetalConst.STAT_CLEARS_FLUSHED],
                    st[MetalConst.STAT_DRAWS]
                ));
                long[] pr = dev.presentRates();
                displayer.addLine(String.format(
                    "Celestia Present: %d frames/s rendered | %d/s shown | %d/s dropped (newer frame ready)",
                    pr[0], pr[1], pr[2]));
                double[] wr = dev.waitRates();
                displayer.addLine(String.format(
                    "Celestia CPU waits (ms/s): in-flight cap %.0f | fences %.0f | present slots %.0f",
                    wr[0], wr[1], wr[2]));
            }
        });
    }
}
