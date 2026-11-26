package dev.celestia.metal.render;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.pipeline.TextureTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.renderpearl.api.textures.GpuTexture;
import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.CelestiaTexture;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.perf.PerformanceEngine;
import net.minecraft.client.Minecraft;
import org.joml.Vector4f;
import org.joml.Vector4fc;

/**
 * Renders the 3D world at a lower internal resolution and upscales it into the full-size main target before the GUI
 * is drawn, so the HUD, chat, F3 and mod overlays (e.g. Xaero's minimap) stay sharp.
 *
 * <p>{@code GameRendererMixin} swaps {@code GameRenderer.mainRenderTarget} / {@code hud3DTarget} for the scaled targets
 * from just before {@code preparePostEffects} (inside {@code shouldRenderLevel}) until after {@code applyPostEffects},
 * then calls {@link #end}. Everything that renders the world in between (vanilla, Sodium via
 * {@code GameRenderer.mainRenderTarget()}, post effects, entity outlines, the first-person hand) uses the scaled
 * targets. The same scaled target is where native shader packs will render.
 */
public final class WorldRenderScale {
    private static RenderTarget worldTarget;
    private static RenderTarget hudTarget;
    private static final Vector4f clearColor = new Vector4f(0f, 0f, 0f, 1f);
    private static double clearDepth = 0.0;
    private static boolean haveClear;
    private static boolean active;
    private static int levelTargetsW = -1;
    private static int levelTargetsH = -1;
    private static volatile int lastPathUsed = -1;   // -1 native, 0 bilinear, 1 MetalFX Spatial, 2 TAAU
    private static volatile int lastWidth, lastHeight;

    private WorldRenderScale() {}

    /** The vanilla frame clear of the main target; replayed onto the scaled world target. */
    public static void rememberClear(Vector4fc color, double depth) {
        clearColor.set(color);
        clearDepth = depth;
        haveClear = true;
    }

    /** Vanilla resized the main target and the level renderer's targets to the full window size. */
    public static void onWindowResize(int width, int height) {
        levelTargetsW = width;
        levelTargetsH = height;
    }

    public static boolean isActive() {
        return active;
    }

    /**
     * Decides whether this frame's world renders scaled and prepares the scaled targets.
     *
     * @return the scaled {world, hud3D} targets to install, or {@code null} to render at full resolution
     */
    public static RenderTarget[] begin(Minecraft mc, RenderTarget main, RenderTarget hud3D) {
        active = false;
        CelestiaMetalDevice device = CelestiaMetalDevice.current;
        int percent = device != null ? PerformanceEngine.get().effectiveRenderScalePercent() : 100;
        if (percent >= 100 || main == null || main.getColorTexture() == null) {
            lastPathUsed = -1;
            if (device != null) device.temporalUpscaler().disable();
            restoreLevelTargets(mc, main);
            return null;
        }
        int w = Math.max(1, Math.round(main.width * percent / 100f));
        int h = Math.max(1, Math.round(main.height * percent / 100f));
        worldTarget = ensure(worldTarget, "Celestia World", main, w, h);
        hudTarget = hud3D != null ? ensure(hudTarget, "Celestia World Hand", hud3D, w, h) : null;
        if (levelTargetsW != w || levelTargetsH != h) {
            // Entity outlines and other level-renderer targets are composited onto the world target: same size.
            mc.levelRenderer.resize(w, h);
            levelTargetsW = w;
            levelTargetsH = h;
        }
        if (haveClear) {
            RenderSystem.getDevice().createCommandEncoder().clearColorAndDepthTextures(
                worldTarget.getColorTexture(), clearColor, worldTarget.getDepthTexture(), clearDepth);
        }
        if (CelestiaConfig.get().appleSilicon.upscaler == CelestiaConfig.UpscalerMode.TAAU) {
            device.temporalUpscaler().begin(worldTarget, main, mc.level);
        } else {
            device.temporalUpscaler().disable();
        }
        lastWidth = w;
        lastHeight = h;
        active = true;
        return new RenderTarget[] { worldTarget, hudTarget };
    }

    /** Upscales the finished world (after post effects) into the full-size main target. */
    public static void end(RenderTarget main) {
        if (!active) return;
        active = false;
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        GpuTexture src = worldTarget.getColorTexture();
        GpuTexture dst = main.getColorTexture();
        if (dev == null || !(src instanceof CelestiaTexture s) || !(dst instanceof CelestiaTexture d)) return;
        if (dev.temporalUpscaler().resolve(s, d)) {
            lastPathUsed = 2;
            return;
        }
        int mode = CelestiaConfig.get().appleSilicon.upscaler == CelestiaConfig.UpscalerMode.BILINEAR ? 0 : 1;
        lastPathUsed = MetalNative.upscaleTo(dev.handle(), s.handle(), d.handle(), mode);
    }

    private static void restoreLevelTargets(Minecraft mc, RenderTarget main) {
        if (main != null && (levelTargetsW != main.width || levelTargetsH != main.height) && levelTargetsW != -1) {
            mc.levelRenderer.resize(main.width, main.height);
            levelTargetsW = main.width;
            levelTargetsH = main.height;
        }
    }

    private static RenderTarget ensure(RenderTarget existing, String label, RenderTarget like, int w, int h) {
        if (existing == null) {
            GpuTexture color = like.getColorTexture();
            GpuTexture depth = like.getDepthTexture();
            return new TextureTarget(label, w, h, color != null ? color.getFormat() : null,
                depth != null ? depth.getFormat() : null);
        }
        if (existing.width != w || existing.height != h) existing.resize(w, h);
        return existing;
    }

    /** F3 label for the upscale path of the last frame. */
    public static String statusLabel() {
        return switch (lastPathUsed) {
            case 2 -> "TAAU " + lastWidth + "x" + lastHeight;
            case 1 -> "MetalFX Spatial " + lastWidth + "x" + lastHeight;
            case 0 -> "Bilinear " + lastWidth + "x" + lastHeight;
            default -> "native";
        };
    }
}
