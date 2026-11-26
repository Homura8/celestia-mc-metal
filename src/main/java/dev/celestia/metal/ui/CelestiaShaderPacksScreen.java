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
    private int infoX, infoY, infoW, infoH;

    public CelestiaShaderPacksScreen(Screen parent) {
        super(Component.literal("Celestia Shader Packs"));
        this.parent = parent;
        this.spm.refreshPacks();
        this.selectedId = spm.activePack().id;
    }

    @Override
    protected void init() {
        searchBox = new EditBox(this.font, width - 176, 12, 160, 18, Component.literal("Search packs..."));
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
        gui.text(font, "✦ Shader Packs", 18, 17, CelestiaTheme.ACCENT_BRIGHT, false);
        String activeTxt = spm.isShadersEnabled() ? ("Active: " + spm.activeDisplayName()) : "Shaders Paused (K)";
        CelestiaTheme.drawBadge(gui, font, activeTxt, 114, 14,
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
        int maxScroll = Math.max(0, totalH - listH);
        scrollOffset = Math.max(0.0, Math.min(scrollOffset, maxScroll));

        gui.enableScissor(listX + 2, listY + 2, listX + listW - 2, listY + listH - 2);
        int cy = listY + 6 - (int) scrollOffset;
        for (ShaderPackManifest pack : packs) {
            if (cy + rowH >= listY && cy <= listY + listH) {
                boolean hov = CelestiaWidgets.inside(mouseX, mouseY, listX + 6, cy, listW - 12, rowH - 4)
                    && CelestiaWidgets.inside(mouseX, mouseY, listX, listY, listW, listH);
                boolean sel = pack.id.equals(selectedId);
                boolean active = pack.id.equals(spm.activePack().id);
                int bg = sel ? CelestiaTheme.SURFACE_ACTIVE : (hov ? CelestiaTheme.SURFACE_HOVER : CelestiaTheme.SURFACE_CARD);
                int rim = active ? CelestiaTheme.ACCENT_LAVENDER : (sel ? CelestiaTheme.GLASS_RIM_STRONG : CelestiaTheme.GLASS_RIM);
                gui.fill(listX + 6, cy, listX + listW - 6, cy + rowH - 4, bg);
                gui.outline(listX + 6, cy, listW - 12, rowH - 4, rim);

                gui.text(font, pack.name, listX + 14, cy + 6, CelestiaTheme.TEXT_MAIN, false);
                String sub = pack.author + " · v" + pack.version + (active ? " · Active" : "");
                gui.text(font, font.plainSubstrByWidth(sub, listW - 110), listX + 14, cy + 19, CelestiaTheme.TEXT_MUTED, false);

                int badgeColor = switch (pack.kind) {
                    case NATIVE_MSL -> CelestiaTheme.ACCENT_BRIGHT;
                    case IRIS_GLSL -> CelestiaTheme.ORB_GOLD;
                    case OFF -> CelestiaTheme.TEXT_MUTED;
                };
                int bw = font.width(pack.kind.badge) + 10;
                CelestiaTheme.drawBadge(gui, font, pack.kind.badge, listX + listW - bw - 14, cy + 10, badgeColor);
            }
            cy += rowH;
        }
        gui.disableScissor();

        if (wide) {
            ShaderPackManifest sel = selectedPack();
            CelestiaTheme.drawGlassPanel(gui, infoX, infoY, infoW, infoH, false);
            int ix = infoX + 12;
            int iy = infoY + 12;
            gui.text(font, font.plainSubstrByWidth(sel.name, infoW - 24), ix, iy, CelestiaTheme.ACCENT_BRIGHT, false);
            iy += 14;
            CelestiaTheme.drawBadge(gui, font, sel.kind.badge, ix, iy,
                sel.kind == ShaderPackManifest.PackKind.NATIVE_MSL ? CelestiaTheme.ACCENT_LAVENDER : CelestiaTheme.TEXT_MUTED);
            iy += 20;
            gui.textWithWordWrap(font, Component.literal(sel.description), ix, iy, infoW - 24, CelestiaTheme.TEXT_MUTED);
            iy += 46;

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

        // Footer
        int fy = height - 28;
        boolean hovOpen = CelestiaWidgets.inside(mouseX, mouseY, 8, fy, 108, 20);
        boolean hovReload = CelestiaWidgets.inside(mouseX, mouseY, 122, fy, 86, 20);
        boolean hovToggle = CelestiaWidgets.inside(mouseX, mouseY, 214, fy, 92, 20);
        boolean hovApply = CelestiaWidgets.inside(mouseX, mouseY, width - 178, fy, 82, 20);
        boolean hovDone = CelestiaWidgets.inside(mouseX, mouseY, width - 90, fy, 82, 20);

        CelestiaWidgets.drawButton(gui, font, 8, fy, 108, 20, "Open Folder", hovOpen, false, true);
        CelestiaWidgets.drawButton(gui, font, 122, fy, 86, 20, "Reload (R)", hovReload, false, true);
        CelestiaWidgets.drawButton(gui, font, 214, fy, 92, 20, spm.isShadersEnabled() ? "Pause (K)" : "Resume (K)",
            hovToggle, !spm.isShadersEnabled(), true);
        CelestiaWidgets.drawButton(gui, font, width - 178, fy, 82, 20, "Apply", hovApply,
            !selectedId.equals(spm.activePack().id), true);
        CelestiaWidgets.drawButton(gui, font, width - 90, fy, 82, 20, "Done", hovDone, true, true);

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
                if (CelestiaWidgets.inside(mx, my, listX + 6, cy, listW - 12, rowH - 4)) {
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
                int iy = infoY + 106;
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
        int fy = height - 28;
        if (CelestiaWidgets.inside(mx, my, 8, fy, 108, 20)) {
            try {
                Path dir = spm.shaderpacksDir();
                Files.createDirectories(dir);
                new ProcessBuilder("open", dir.toAbsolutePath().toString()).start();
            } catch (Exception ignored) {}
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, 122, fy, 86, 20)) {
            spm.reloadActivePack();
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, 214, fy, 92, 20)) {
            spm.toggleShaders();
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, width - 178, fy, 82, 20)) {
            spm.selectPack(selectedId);
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, width - 90, fy, 82, 20)) {
            spm.selectPack(selectedId);
            onClose();
            return true;
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
