package dev.celestia.metal.ui;

import net.minecraft.client.gui.Font;
import net.minecraft.client.gui.GuiGraphicsExtractor;

/**
 * Frosted observatory design language derived from Homura8/celestiaglow:
 * quiet violet-slate glass surfaces, 1px frosted glass rims, lavender accents, and starlight typography.
 */
public final class CelestiaTheme {
    // Backdrop & Frosted Glass Surfaces (dark observatory tokens)
    public static final int BACKDROP_TOP = 0xD8252132;
    public static final int BACKDROP_BOTTOM = 0xE620273A;
    public static final int SURFACE_GLASS = 0xD42E283F;
    public static final int SURFACE_CARD = 0xCC302A3D;
    public static final int SURFACE_HOVER = 0xE03C3450;
    public static final int SURFACE_ACTIVE = 0xEB463B5E;

    // Borders & Dividers
    public static final int GLASS_RIM = 0x2EEDDEFF;
    public static final int GLASS_RIM_STRONG = 0x66C8B3E4;
    public static final int LINE_DIVIDER = 0x29D7C5EF;

    // Typography & Accents
    public static final int TEXT_MAIN = 0xFFEEE8F5;
    public static final int TEXT_MUTED = 0xFFBCB2C9;
    public static final int ACCENT_LAVENDER = 0xFFC8B3E4;
    public static final int ACCENT_BRIGHT = 0xFFE0CDEF;
    public static final int ORB_ROSE = 0xFFE9BCCD;
    public static final int ORB_GOLD = 0xFFE7CDE1;
    public static final int BADGE_GREEN = 0xFF9ED4B8;
    public static final int TRACK_BG = 0xFF1D1928;

    private CelestiaTheme() {}

    public static void drawBackdrop(GuiGraphicsExtractor gui, int w, int h) {
        gui.fillGradient(0, 0, w, h, BACKDROP_TOP, BACKDROP_BOTTOM);
        // Subtle ambient top wash
        gui.fillGradient(0, 0, w, Math.min(h, 110), 0x22C8B3E4, 0x00211E30);
    }

    public static void drawGlassPanel(GuiGraphicsExtractor gui, int x, int y, int w, int h, boolean elevated) {
        gui.fill(x, y, x + w, y + h, elevated ? SURFACE_CARD : SURFACE_GLASS);
        gui.outline(x, y, w, h, GLASS_RIM);
        // Crisp 1px top inner highlight like frosted glass
        if (w > 4) {
            gui.horizontalLine(x + 1, x + w - 2, y + 1, 0x18FFFFFF);
        }
    }

    public static int badgeWidth(Font font, String text) {
        return font.width(text) + 10;
    }

    public static void drawBadge(GuiGraphicsExtractor gui, Font font, String text, int x, int y, int accentColor) {
        drawBadgeClipped(gui, font, text, x, y, Integer.MAX_VALUE, accentColor);
    }

    public static int drawBadgeClipped(GuiGraphicsExtractor gui, Font font, String text, int x, int y, int maxW, int accentColor) {
        String shown = maxW == Integer.MAX_VALUE ? text : font.plainSubstrByWidth(text, Math.max(8, maxW - 10));
        int bw = Math.min(maxW, font.width(shown) + 10);
        int bh = 14;
        int bg = (accentColor & 0x00FFFFFF) | 0x26000000;
        int rim = (accentColor & 0x00FFFFFF) | 0x77000000;
        gui.fill(x, y, x + bw, y + bh, bg);
        gui.outline(x, y, bw, bh, rim);
        gui.text(font, shown, x + 5, y + 3, accentColor, false);
        return bw;
    }

    public static void drawSearchFieldChrome(GuiGraphicsExtractor gui, int x, int y, int w, int h, boolean focused) {
        gui.fill(x, y, x + w, y + h, 0xCC1A1626);
        gui.outline(x, y, w, h, focused ? ACCENT_LAVENDER : GLASS_RIM);
        if (w > 4) {
            gui.horizontalLine(x + 1, x + w - 2, y + 1, 0x12FFFFFF);
        }
    }

    public static void drawScrollbar(GuiGraphicsExtractor gui, int x, int y, int h, double scrollOffset, int maxScroll, int totalH) {
        if (maxScroll <= 0 || h <= 8) return;
        gui.fill(x, y, x + 3, y + h, 0x441A1626);
        int denom = Math.max(h + maxScroll, totalH);
        int thumbH = Math.max(18, Math.min(h, (int) Math.round((double) h * h / denom)));
        int thumbY = y + (int) Math.round((h - thumbH) * (scrollOffset / maxScroll));
        gui.fill(x, thumbY, x + 3, thumbY + thumbH, 0xCC9C84C9);
        gui.horizontalLine(x, x + 2, thumbY, ACCENT_LAVENDER);
    }

    public static void drawScrollFades(GuiGraphicsExtractor gui, int x, int y, int w, int h, double scrollOffset, int maxScroll) {
        int fadeH = Math.min(8, h / 4);
        if (fadeH <= 0 || maxScroll <= 0) return;
        if (scrollOffset > 0.5) {
            gui.fillGradient(x, y, x + w, y + fadeH, SURFACE_GLASS, 0x002E283F);
        }
        if (scrollOffset < maxScroll - 0.5) {
            gui.fillGradient(x, y + h - fadeH, x + w, y + h, 0x002E283F, SURFACE_GLASS);
        }
    }

    public static void drawProgressBar(GuiGraphicsExtractor gui, int x, int y, int w, int h, double frac, int fillColor) {
        double clamped = Math.max(0.0, Math.min(1.0, frac));
        gui.fill(x, y, x + w, y + h, TRACK_BG);
        int fillW = (int) Math.round(w * clamped);
        if (fillW > 0) {
            gui.fill(x, y, x + fillW, y + h, fillColor);
        }
        gui.outline(x, y, w, h, GLASS_RIM);
    }
}
