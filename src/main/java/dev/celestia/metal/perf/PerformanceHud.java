package dev.celestia.metal.perf;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import dev.celestia.metal.ui.CelestiaTheme;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.Font;
import net.minecraft.client.gui.GuiGraphicsExtractor;

/**
 * Compact CelestiaGlow frosted pill HUD showing live FPS, GPU frame time, Metal 4 status,
 * active shader pack, and thermal/scale state.
 */
public final class PerformanceHud {
    private PerformanceHud() {}

    public static void render(GuiGraphicsExtractor gui) {
        CelestiaConfig.AppleSiliconSection cfg = CelestiaConfig.get().appleSilicon;
        if (cfg.performanceHud == CelestiaConfig.HudMode.OFF) return;

        Minecraft mc = Minecraft.getInstance();
        if (mc.debugEntries.isOverlayVisible()) return;

        Font font = mc.font;
        PerformanceEngine perf = PerformanceEngine.get();
        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        String api = dev != null && dev.isMetal4() ? "Metal 4" : (dev != null ? "Metal 3" : "OpenGL");
        double fps = perf.averageFps();
        String packName = ShaderPipelineManager.get().activeDisplayName();

        String line1 = String.format("✦ %.0f FPS  ·  %.2f ms GPU  ·  %s", fps, perf.ewmaGpuMs(), api);
        if (cfg.performanceHud == CelestiaConfig.HudMode.COMPACT) {
            String full = packName.equals("Off") ? line1 : (line1 + "  ·  " + packName);
            int w = font.width(full) + 14;
            drawPill(gui, 8, 8, w, 16);
            gui.text(font, full, 15, 12, CelestiaTheme.TEXT_MAIN, false);
        } else {
            String line2 = String.format("1%% Low: %.0f  ·  Scale: %d%%  ·  Thermal: %s  ·  Shader: %s",
                perf.onePercentLowFps(), perf.effectiveRenderScalePercent(), perf.thermalLabel(), packName);
            int w = Math.max(font.width(line1), font.width(line2)) + 16;
            drawPill(gui, 8, 8, w, 28);
            gui.text(font, line1, 16, 12, CelestiaTheme.TEXT_MAIN, false);
            gui.text(font, line2, 16, 23, CelestiaTheme.TEXT_MUTED, false);
        }
    }

    private static void drawPill(GuiGraphicsExtractor gui, int x, int y, int w, int h) {
        gui.fill(x, y, x + w, y + h, 0xCC211E30);
        gui.outline(x, y, w, h, CelestiaTheme.GLASS_RIM);
    }
}
