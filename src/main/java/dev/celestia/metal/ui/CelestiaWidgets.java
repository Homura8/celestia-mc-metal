package dev.celestia.metal.ui;

import net.minecraft.client.gui.Font;
import net.minecraft.client.gui.GuiGraphicsExtractor;

/**
 * Stateless drawing and hit-testing primitives for CelestiaGlow rows and buttons.
 */
public final class CelestiaWidgets {
    public static final int ROW_HEIGHT = 28;
    public static final int HEADER_HEIGHT = 20;

    private CelestiaWidgets() {}

    public static void drawButton(GuiGraphicsExtractor gui, Font font, int x, int y, int w, int h,
                                  String label, boolean hovered, boolean selected, boolean enabled) {
        int bg = !enabled ? 0x80241F32
            : selected ? CelestiaTheme.SURFACE_ACTIVE
            : hovered ? CelestiaTheme.SURFACE_HOVER
            : CelestiaTheme.SURFACE_CARD;
        int rim = !enabled ? CelestiaTheme.LINE_DIVIDER
            : selected ? CelestiaTheme.ACCENT_LAVENDER
            : hovered ? CelestiaTheme.GLASS_RIM_STRONG
            : CelestiaTheme.GLASS_RIM;
        int textColor = !enabled ? 0xFF6B627A
            : selected ? CelestiaTheme.ACCENT_BRIGHT
            : CelestiaTheme.TEXT_MAIN;

        gui.fill(x, y, x + w, y + h, bg);
        gui.outline(x, y, w, h, rim);
        if (selected && enabled) {
            gui.horizontalLine(x + 2, x + w - 3, y + h - 2, CelestiaTheme.ACCENT_LAVENDER);
        }
        int tw = font.width(label);
        gui.text(font, label, x + Math.max(4, (w - tw) / 2), y + (h - 8) / 2, textColor, false);
    }

    public static void drawOptionRow(GuiGraphicsExtractor gui, Font font, OptionEntry entry,
                                     int x, int y, int w, boolean hovered) {
        if (entry instanceof OptionEntry.Header h) {
            gui.text(font, "✦ " + h.label(), x + 4, y + 6, CelestiaTheme.ACCENT_LAVENDER, false);
            gui.horizontalLine(x + 4, x + w - 4, y + HEADER_HEIGHT - 2, CelestiaTheme.LINE_DIVIDER);
            return;
        }

        int bg = hovered ? CelestiaTheme.SURFACE_HOVER : CelestiaTheme.SURFACE_CARD;
        int rim = hovered ? CelestiaTheme.GLASS_RIM_STRONG : CelestiaTheme.GLASS_RIM;
        gui.fill(x, y, x + w, y + ROW_HEIGHT - 2, bg);
        gui.outline(x, y, w, ROW_HEIGHT - 2, rim);

        int controlW = Math.min(136, Math.max(96, w / 3));
        int ctrlX = x + w - controlW - 8;
        int ctrlY = y + 4;
        int ctrlH = ROW_HEIGHT - 10;

        String clipped = font.plainSubstrByWidth(entry.label(), Math.max(40, ctrlX - x - 16));
        gui.text(font, clipped, x + 10, y + 9, CelestiaTheme.TEXT_MAIN, false);

        switch (entry) {
            case OptionEntry.Toggle t -> {
                boolean on = Boolean.TRUE.equals(t.getter().get());
                int pillW = 46;
                int px = x + w - pillW - 10;
                int py = y + 6;
                gui.fill(px, py, px + pillW, py + 14, on ? 0xAA75608A : CelestiaTheme.TRACK_BG);
                gui.outline(px, py, pillW, 14, on ? CelestiaTheme.ACCENT_LAVENDER : CelestiaTheme.GLASS_RIM);
                int knobX = on ? (px + pillW - 12) : (px + 2);
                gui.fill(knobX, py + 2, knobX + 10, py + 12, on ? CelestiaTheme.ACCENT_BRIGHT : CelestiaTheme.TEXT_MUTED);
                String valTxt = on ? "ON" : "OFF";
                gui.text(font, valTxt, px - font.width(valTxt) - 8, y + 9,
                    on ? CelestiaTheme.BADGE_GREEN : CelestiaTheme.TEXT_MUTED, false);
            }
            case OptionEntry.IntSlider s -> {
                int val = s.getter().getAsInt();
                double frac = s.max() > s.min() ? (double) (val - s.min()) / (s.max() - s.min()) : 0.0;
                CelestiaTheme.drawProgressBar(gui, ctrlX, ctrlY, controlW, ctrlH, frac, 0x88C8B3E4);
                String txt = s.formatter().apply(val);
                gui.text(font, txt, ctrlX + (controlW - font.width(txt)) / 2, ctrlY + 5, CelestiaTheme.TEXT_MAIN, false);
            }
            case OptionEntry.FloatSlider s -> {
                double val = s.getter().getAsDouble();
                double frac = s.max() > s.min() ? (val - s.min()) / (s.max() - s.min()) : 0.0;
                CelestiaTheme.drawProgressBar(gui, ctrlX, ctrlY, controlW, ctrlH, frac, 0x88C8B3E4);
                String txt = s.formatter().apply(val);
                gui.text(font, txt, ctrlX + (controlW - font.width(txt)) / 2, ctrlY + 5, CelestiaTheme.TEXT_MAIN, false);
            }
            case OptionEntry.Cycle<?> c -> {
                @SuppressWarnings("unchecked")
                OptionEntry.Cycle<Object> raw = (OptionEntry.Cycle<Object>) c;
                String txt = raw.formatter().apply(raw.getter().get());
                drawButton(gui, font, ctrlX, ctrlY, controlW, ctrlH, txt, hovered, false, true);
            }
            case OptionEntry.Action a -> {
                drawButton(gui, font, ctrlX, ctrlY, controlW, ctrlH, a.buttonLabel(), hovered, true, true);
            }
            case OptionEntry.Header ignored -> {}
        }
    }

    public static int rowHeight(OptionEntry entry) {
        return entry instanceof OptionEntry.Header ? HEADER_HEIGHT : ROW_HEIGHT;
    }

    public static boolean inside(double mx, double my, int x, int y, int w, int h) {
        return mx >= x && mx < x + w && my >= y && my < y + h;
    }
}
