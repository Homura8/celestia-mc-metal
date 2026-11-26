package dev.celestia.metal.ui;

import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.input.KeyEvent;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.network.chat.Component;

/**
 * Dedicated shader pack selector supporting Built-in Native MSL packs, external Native MSL packs,
 * and Iris/OptiFine GLSL shader packs.
 */
public final class CelestiaShaderPacksScreen extends Screen {
    private final Screen parent;
    private final ShaderPipelineManager spm = ShaderPipelineManager.get();
    private EditBox searchBox;
    private String searchQuery = "";
    private String selectedId;
    private double scrollOffset;
    private int listX, listY, listW, listH;
    private int lastContentW = 240;
    private int infoX, infoY, infoW, infoH;

    public CelestiaShaderPacksScreen(Screen parent) {
        super(Component.literal("Celestia Shader Packs"));
        this.parent = parent;
        this.spm.refreshPacks();
        this.selectedId = spm.activePack().id;
    }

    private int searchW() {
        return Math.min(156, Math.max(96, width / 3 - 8));
    }

    private int searchX() {
        return width - searchW() - 14;
    }

    private int presetStartY(ShaderPackManifest sel) {
        int descLines = Math.max(1, font.split(Component.literal(sel.description), Math.max(40, infoW - 24)).size());
        int descH = descLines * (font.lineHeight + 1);
        return infoY + 46 + Math.max(20, descH) + 8 + 14;
    }

    private String[] footerLabels(boolean wide) {
        return wide
            ? new String[]{"Open Folder", "Reload (R)", spm.isShadersEnabled() ? "Pause (K)" : "Resume (K)", "Apply", "Done"}
            : new String[]{"Folder", "Reload", "Options", "Apply", "Done"};
    }

    @Override
    protected void init() {
        int sx = searchX();
        int sw = searchW();
        searchBox = new EditBox(this.font, sx + 6, 17, sw - 10, 12, Component.literal("Search packs..."));
        searchBox.setBordered(false);
        searchBox.setTextColor(CelestiaTheme.TEXT_MAIN);
        searchBox.setHint(Component.literal("Search packs..."));
        searchBox.setValue(searchQuery);
        searchBox.setResponder(q -> {
            this.searchQuery = q;
            this.scrollOffset = 0;
        });
        addRenderableWidget(searchBox);
    }

    private List<ShaderPackManifest> filteredPacks() {
        List<ShaderPackManifest> out = new ArrayList<>();
        String q = searchQuery.toLowerCase(java.util.Locale.ROOT).trim();
        for (ShaderPackManifest m : spm.packs()) {
            if (q.isEmpty() || m.name.toLowerCase(java.util.Locale.ROOT).contains(q)
                || m.author.toLowerCase(java.util.Locale.ROOT).contains(q)) {
                out.add(m);
            }
        }
        return out;
    }

    private ShaderPackManifest selectedPack() {
        ShaderPackManifest m = spm.findPack(selectedId);
        return m != null ? m : spm.activePack();
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor gui, int mouseX, int mouseY, float partialTick) {
        CelestiaTheme.drawBackdrop(gui, width, height);

        CelestiaTheme.drawGlassPanel(gui, 8, 6, width - 16, 30, false);
        String title = "✦ Shader Packs";
        gui.text(font, title, 18, 17, CelestiaTheme.ACCENT_BRIGHT, false);
        int sx = searchX();
        int sw = searchW();
        CelestiaTheme.drawSearchFieldChrome(gui, sx, 12, sw, 18, searchBox != null && searchBox.isFocused());

        String activeTxt = spm.isShadersEnabled() ? ("Active: " + spm.activeDisplayName()) : "Shaders Paused (K)";
        int bx = 18 + font.width(title) + 8;
        int maxBw = Math.max(40, sx - bx - 8);
        CelestiaTheme.drawBadgeClipped(gui, font, activeTxt, bx, 14, maxBw,
            spm.isShadersEnabled() ? CelestiaTheme.BADGE_GREEN : CelestiaTheme.ORB_ROSE);

        boolean wide = width >= 500;
        listX = 8;
        listY = 44;
        listH = height - listY - 38;
        if (wide) {
            infoW = Math.min(240, Math.max(180, width * 2 / 5));
            listW = width - infoW - 24;
            infoX = listX + listW + 8;
            infoY = listY;
            infoH = listH;
        } else {
            listW = width - 16;
            infoW = 0;
        }

        CelestiaTheme.drawGlassPanel(gui, listX, listY, listW, listH, false);

        List<ShaderPackManifest> packs = filteredPacks();
        int rowH = 38;
        int totalH = packs.size() * rowH + 8;
        int maxScroll = Math.max(0, totalH - (listH - 8));
        scrollOffset = Math.max(0.0, Math.min(scrollOffset, maxScroll));
        int contentW = maxScroll > 0 ? (listW - 18) : (listW - 12);
        this.lastContentW = contentW;

        gui.enableScissor(listX + 2, listY + 4, listX + listW - 2, listY + listH - 4);
        int cy = listY + 6 - (int) scrollOffset;
        for (ShaderPackManifest pack : packs) {
            if (cy + rowH >= listY && cy <= listY + listH) {
                boolean hov = CelestiaWidgets.inside(mouseX, mouseY, listX + 6, cy, contentW, rowH - 4)
                    && CelestiaWidgets.inside(mouseX, mouseY, listX, listY + 2, listW, listH - 4);
                boolean sel = pack.id.equals(selectedId);
                boolean active = pack.id.equals(spm.activePack().id);
                int bg = sel ? CelestiaTheme.SURFACE_ACTIVE : (hov ? CelestiaTheme.SURFACE_HOVER : CelestiaTheme.SURFACE_CARD);
                int rim = active ? CelestiaTheme.ACCENT_LAVENDER : (sel ? CelestiaTheme.GLASS_RIM_STRONG : CelestiaTheme.GLASS_RIM);
                gui.fill(listX + 6, cy, listX + 6 + contentW, cy + rowH - 4, bg);
                gui.outline(listX + 6, cy, contentW, rowH - 4, rim);
                if (hov && !sel) {
                    gui.fill(listX + 7, cy + 2, listX + 9, cy + rowH - 6, CelestiaTheme.ACCENT_LAVENDER);
                }

                int badgeColor = switch (pack.kind) {
                    case WORLD_MSL, NATIVE_MSL -> CelestiaTheme.ACCENT_BRIGHT;
                    case IRIS_GLSL -> CelestiaTheme.ORB_GOLD;
                    case OFF -> CelestiaTheme.TEXT_MUTED;
                };
                int bw = CelestiaTheme.badgeWidth(font, pack.kind.badge);
                int textMaxW = Math.max(40, contentW - bw - 22);
                gui.text(font, font.plainSubstrByWidth(pack.name, textMaxW), listX + 14, cy + 6, CelestiaTheme.TEXT_MAIN, false);
                String sub = pack.author + " · v" + pack.version + (active ? " · Active" : "");
                gui.text(font, font.plainSubstrByWidth(sub, textMaxW), listX + 14, cy + 19, CelestiaTheme.TEXT_MUTED, false);

                CelestiaTheme.drawBadge(gui, font, pack.kind.badge, listX + 6 + contentW - bw - 8, cy + 10, badgeColor);
            }
            cy += rowH;
        }
        CelestiaTheme.drawScrollFades(gui, listX + 2, listY + 4, listW - 4, listH - 8, scrollOffset, maxScroll);
        gui.disableScissor();
        CelestiaTheme.drawScrollbar(gui, listX + listW - 6, listY + 6, listH - 12, scrollOffset, maxScroll, totalH);

        if (wide) {
            ShaderPackManifest sel = selectedPack();
            CelestiaTheme.drawGlassPanel(gui, infoX, infoY, infoW, infoH, false);
            int ix = infoX + 12;
            int iy = infoY + 12;
            gui.text(font, font.plainSubstrByWidth(sel.name, infoW - 24), ix, iy, CelestiaTheme.ACCENT_BRIGHT, false);
            iy += 14;
            CelestiaTheme.drawBadge(gui, font, sel.kind.badge, ix, iy,
                sel.kind == ShaderPackManifest.PackKind.NATIVE_MSL || sel.kind == ShaderPackManifest.PackKind.WORLD_MSL
                    ? CelestiaTheme.ACCENT_LAVENDER : CelestiaTheme.TEXT_MUTED);
            iy += 20;
            gui.textWithWordWrap(font, Component.literal(sel.description), ix, iy, infoW - 24, CelestiaTheme.TEXT_MUTED);
            iy = presetStartY(sel) - 14;

            if (!sel.presets.isEmpty()) {
                ShaderOptionState st = spm.optionState(sel);
                gui.text(font, "Preset: " + (st.activePreset().isEmpty() ? "Default" : st.activePreset()),
                    ix, iy, CelestiaTheme.TEXT_MAIN, false);
                iy += 14;
                int px = ix;
                for (String presetName : sel.presets.keySet()) {
                    int pw = font.width(presetName) + 12;
                    if (px + pw > infoX + infoW - 12) {
                        px = ix;
                        iy += 20;
                    }
                    boolean phov = CelestiaWidgets.inside(mouseX, mouseY, px, iy, pw, 17);
                    boolean psel = presetName.equals(st.activePreset());
                    CelestiaWidgets.drawButton(gui, font, px, iy, pw, 17, presetName, phov, psel, true);
                    px += pw + 4;
                }
                iy += 24;
            }

            if (sel.id.equals(spm.activePack().id)) {
                List<String> diags = spm.lastDiagnostics();
                if (sel.kind == ShaderPackManifest.PackKind.NATIVE_MSL) {
                    String status = diags.isEmpty()
                        ? String.format("Compiled %d passes in %d ms", spm.compiledPassCount(), spm.lastCompileTimeMs())
                        : diags.get(0);
                    gui.textWithWordWrap(font, Component.literal(status), ix, iy, infoW - 24,
                        diags.isEmpty() ? CelestiaTheme.BADGE_GREEN : CelestiaTheme.ORB_ROSE);
                }
            }

            // Configure button inside inspector
            boolean canCfg = sel.kind != ShaderPackManifest.PackKind.OFF && !sel.options.isEmpty();
            boolean hovCfg = CelestiaWidgets.inside(mouseX, mouseY, ix, infoY + infoH - 28, infoW - 24, 20);
            CelestiaWidgets.drawButton(gui, font, ix, infoY + infoH - 28, infoW - 24, 20,
                "Configure Pack Options...", hovCfg, false, canCfg);
        }

        // Responsive footer
        int fy = height - 28;
        String[] labels = footerLabels(wide);
        int fGap = wide ? 5 : 4;
        int[] bws = CelestiaWidgets.computeProportionalWidths(font, labels, width - 16, fGap, 8, 14);
        ShaderPackManifest sel = selectedPack();
        boolean canCfgCompact = sel.kind != ShaderPackManifest.PackKind.OFF && !sel.options.isEmpty();
        boolean[] selectedFlags = {false, false, wide ? !spm.isShadersEnabled() : false, !selectedId.equals(spm.activePack().id), true};
        boolean[] enabledFlags = {true, true, wide || canCfgCompact, true, true};
        int fx = 8;
        for (int i = 0; i < labels.length; i++) {
            boolean hov = CelestiaWidgets.inside(mouseX, mouseY, fx, fy, bws[i], 20);
            CelestiaWidgets.drawButton(gui, font, fx, fy, bws[i], 20, labels[i], hov, selectedFlags[i], enabledFlags[i]);
            fx += bws[i] + fGap;
        }

        super.extractRenderState(gui, mouseX, mouseY, partialTick);
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubleClick) {
        if (super.mouseClicked(event, doubleClick)) return true;
        double mx = event.x(), my = event.y();

        // Pack rows
        if (CelestiaWidgets.inside(mx, my, listX, listY, listW, listH)) {
            List<ShaderPackManifest> packs = filteredPacks();
            int rowH = 38;
            int cy = listY + 6 - (int) scrollOffset;
            for (ShaderPackManifest pack : packs) {
                if (CelestiaWidgets.inside(mx, my, listX + 6, cy, lastContentW, rowH - 4)) {
                    selectedId = pack.id;
                    if (doubleClick) {
                        spm.selectPack(selectedId);
                    }
                    return true;
                }
                cy += rowH;
            }
        }

        // Inspector preset pills & configure button
        if (infoW > 0) {
            ShaderPackManifest sel = selectedPack();
            int ix = infoX + 12;
            if (CelestiaWidgets.inside(mx, my, ix, infoY + infoH - 28, infoW - 24, 20)
                && sel.kind != ShaderPackManifest.PackKind.OFF && !sel.options.isEmpty()) {
                spm.selectPack(sel.id);
                Minecraft.getInstance().gui.setScreen(new CelestiaShaderOptionsScreen(this, sel));
                return true;
            }
            if (!sel.presets.isEmpty()) {
                int iy = presetStartY(sel);
                int px = ix;
                for (String presetName : sel.presets.keySet()) {
                    int pw = font.width(presetName) + 12;
                    if (px + pw > infoX + infoW - 12) {
                        px = ix;
                        iy += 20;
                    }
                    if (CelestiaWidgets.inside(mx, my, px, iy, pw, 17)) {
                        spm.selectPack(sel.id);
                        spm.applyPreset(presetName);
                        return true;
                    }
                    px += pw + 4;
                }
            }
        }

        // Footer
        boolean wide = infoW > 0;
        int fy = height - 28;
        String[] labels = footerLabels(wide);
        int fGap = wide ? 5 : 4;
        int[] bws = CelestiaWidgets.computeProportionalWidths(font, labels, width - 16, fGap, 8, 14);
        int fx = 8;
        for (int i = 0; i < bws.length; i++) {
            int bw = bws[i];
            if (CelestiaWidgets.inside(mx, my, fx, fy, bw, 20)) {
                switch (i) {
                    case 0 -> {
                        try {
                            Path dir = spm.shaderpacksDir();
                            Files.createDirectories(dir);
                            new ProcessBuilder("open", dir.toAbsolutePath().toString()).start();
                        } catch (Exception ignored) {}
                    }
                    case 1 -> spm.reloadActivePack();
                    case 2 -> {
                        if (wide) {
                            spm.toggleShaders();
                        } else {
                            ShaderPackManifest sel = selectedPack();
                            if (sel.kind != ShaderPackManifest.PackKind.OFF && !sel.options.isEmpty()) {
                                spm.selectPack(sel.id);
                                Minecraft.getInstance().gui.setScreen(new CelestiaShaderOptionsScreen(this, sel));
                            }
                        }
                    }
                    case 3 -> spm.selectPack(selectedId);
                    case 4 -> {
                        spm.selectPack(selectedId);
                        onClose();
                    }
                }
                return true;
            }
            fx += bw + fGap;
        }
        return false;
    }

    @Override
    public boolean mouseScrolled(double mouseX, double mouseY, double hAmount, double vAmount) {
        if (CelestiaWidgets.inside(mouseX, mouseY, listX, listY, listW, listH)) {
            scrollOffset -= vAmount * 22.0;
            return true;
        }
        return super.mouseScrolled(mouseX, mouseY, hAmount, vAmount);
    }

    @Override
    public boolean keyPressed(KeyEvent event) {
        if (event.key() == 256) {
            onClose();
            return true;
        }
        return super.keyPressed(event);
    }

    @Override
    public void onClose() {
        Minecraft.getInstance().gui.setScreen(parent);
    }
}
