package dev.celestia.metal.ui;

import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.shader.pack.ShaderOptionState;
import dev.celestia.metal.shader.pack.ShaderPackManifest;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
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
 * Unified Shader Options editor supporting both Native MSL packs ({@code celestia-shader.json})
 * and Iris/OptiFine GLSL packs ({@code shaders.properties} + {@code .txt} persistence).
 */
public final class CelestiaShaderOptionsScreen extends Screen {
    private final Screen parent;
    private final ShaderPackManifest pack;
    private final ShaderOptionState state;
    private final List<String> categories;
    private String activeCategory;
    private EditBox searchBox;
    private String searchQuery = "";
    private double scrollOffset;
    private ShaderOptionDef hoveredOption;
    private ShaderOptionDef draggingOption;
    private int catX, catY, catW, catH;
    private int optX, optY, optW, optH;
    private int infoX, infoY, infoW, infoH;

    public CelestiaShaderOptionsScreen(Screen parent, ShaderPackManifest pack) {
        super(Component.literal(pack.name + " Options"));
        this.parent = parent;
        this.pack = pack;
        this.state = ShaderPipelineManager.get().optionState(pack);
        this.categories = pack.categories.isEmpty() ? List.of("General") : pack.categories;
        this.activeCategory = this.categories.get(0);
    }

    @Override
    protected void init() {
        searchBox = new EditBox(this.font, width - 176, 12, 160, 18, Component.literal("Search options..."));
        searchBox.setHint(Component.literal("Search options..."));
        searchBox.setValue(searchQuery);
        searchBox.setResponder(q -> {
            this.searchQuery = q;
            this.scrollOffset = 0;
        });
        addRenderableWidget(searchBox);
    }

    private List<ShaderOptionDef> visibleOptions() {
        List<ShaderOptionDef> out = new ArrayList<>();
        String q = searchQuery.toLowerCase(java.util.Locale.ROOT).trim();
        for (ShaderOptionDef def : pack.options) {
            if (!q.isEmpty()) {
                if (def.label().toLowerCase(java.util.Locale.ROOT).contains(q)
                    || def.id().toLowerCase(java.util.Locale.ROOT).contains(q)
                    || def.description().toLowerCase(java.util.Locale.ROOT).contains(q)) {
                    out.add(def);
                }
            } else if (def.category().equals(activeCategory)) {
                out.add(def);
            }
        }
        return out;
    }

    private OptionEntry toOptionEntry(ShaderOptionDef def) {
        return switch (def.kind()) {
            case TOGGLE -> new OptionEntry.Toggle(def.label(), def.description(), def.impact(),
                () -> state.getBoolean(def.id()),
                v -> state.set(def.id(), Boolean.toString(v)));
            case ENUM -> new OptionEntry.Cycle<>(def.label(), def.description(), def.impact(),
                def.values(),
                () -> state.get(def.id()),
                v -> state.set(def.id(), v),
                s -> s);
            case INT_SLIDER -> new OptionEntry.IntSlider(def.label(), def.description(), def.impact(),
                (int) Math.round(def.min()), (int) Math.round(def.max()), Math.max(1, (int) Math.round(def.step())),
                () -> state.getInt(def.id()),
                v -> state.set(def.id(), Integer.toString(v)),
                Object::toString);
            case FLOAT_SLIDER -> new OptionEntry.FloatSlider(def.label(), def.description(), def.impact(),
                def.min(), def.max(), def.step() > 0 ? def.step() : 0.05,
                () -> state.getDouble(def.id()),
                v -> state.set(def.id(), String.format(java.util.Locale.ROOT, "%.2f", v)),
                v -> String.format(java.util.Locale.ROOT, "%.2f", v));
        };
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor gui, int mouseX, int mouseY, float partialTick) {
        CelestiaTheme.drawBackdrop(gui, width, height);

        CelestiaTheme.drawGlassPanel(gui, 8, 6, width - 16, 30, false);
        gui.text(font, "✦ " + pack.name, 18, 17, CelestiaTheme.ACCENT_BRIGHT, false);
        String presetText = state.activePreset().isEmpty() ? pack.kind.badge : ("Preset: " + state.activePreset());
        CelestiaTheme.drawBadge(gui, font, presetText, 24 + font.width("✦ " + pack.name), 14, CelestiaTheme.ACCENT_LAVENDER);

        catX = 8;
        catY = 44;
        catW = Math.min(138, Math.max(100, width / 5));
        catH = height - catY - 38;

        boolean wide = width >= 560;
        if (wide) {
            infoW = Math.min(200, width / 4);
            optX = catX + catW + 8;
            optY = catY;
            optW = width - catW - infoW - 32;
            optH = catH;
            infoX = optX + optW + 8;
            infoY = catY;
            infoH = catH;
        } else {
            infoW = 0;
            optX = catX + catW + 8;
            optY = catY;
            optW = width - catW - 24;
            optH = catH;
        }

        // Category sidebar
        CelestiaTheme.drawGlassPanel(gui, catX, catY, catW, catH, false);
        int cy = catY + 8;
        for (String cat : categories) {
            boolean hov = CelestiaWidgets.inside(mouseX, mouseY, catX + 6, cy, catW - 12, 22);
            boolean sel = searchQuery.isBlank() && cat.equals(activeCategory);
            CelestiaWidgets.drawButton(gui, font, catX + 6, cy, catW - 12, 22,
                font.plainSubstrByWidth(cat, catW - 22), hov, sel, true);
            cy += 26;
        }

        // Option rows
        CelestiaTheme.drawGlassPanel(gui, optX, optY, optW, optH, false);
        List<ShaderOptionDef> opts = visibleOptions();
        int totalH = opts.size() * CelestiaWidgets.ROW_HEIGHT + 8;
        int maxScroll = Math.max(0, totalH - optH);
        scrollOffset = Math.max(0.0, Math.min(scrollOffset, maxScroll));

        hoveredOption = null;
        gui.enableScissor(optX + 2, optY + 2, optX + optW - 2, optY + optH - 2);
        int oy = optY + 6 - (int) scrollOffset;
        for (ShaderOptionDef def : opts) {
            if (oy + CelestiaWidgets.ROW_HEIGHT >= optY && oy <= optY + optH) {
                boolean hov = CelestiaWidgets.inside(mouseX, mouseY, optX + 6, oy, optW - 12, CelestiaWidgets.ROW_HEIGHT)
                    && CelestiaWidgets.inside(mouseX, mouseY, optX, optY, optW, optH);
                if (hov) hoveredOption = def;
                CelestiaWidgets.drawOptionRow(gui, font, toOptionEntry(def), optX + 6, oy, optW - 12, hov);
            }
            oy += CelestiaWidgets.ROW_HEIGHT;
        }
        gui.disableScissor();

        if (wide) {
            CelestiaTheme.drawGlassPanel(gui, infoX, infoY, infoW, infoH, false);
            int ix = infoX + 12;
            int iy = infoY + 12;
            if (hoveredOption != null) {
                gui.text(font, font.plainSubstrByWidth(hoveredOption.label(), infoW - 24), ix, iy, CelestiaTheme.ACCENT_BRIGHT, false);
                iy += 14;
                CelestiaTheme.drawBadge(gui, font, "Impact: " + hoveredOption.impact().label, ix, iy, hoveredOption.impact().color);
                iy += 20;
                gui.text(font, "Macro: " + hoveredOption.id(), ix, iy, CelestiaTheme.TEXT_MUTED, false);
                iy += 14;
                gui.textWithWordWrap(font, Component.literal(hoveredOption.description().isEmpty()
                    ? "Modifies shader option " + hoveredOption.id() : hoveredOption.description()),
                    ix, iy, infoW - 24, CelestiaTheme.TEXT_MUTED);
            } else {
                gui.text(font, "✦ Pack Options", ix, iy, CelestiaTheme.ACCENT_LAVENDER, false);
                iy += 16;
                gui.textWithWordWrap(font, Component.literal("Hover any option to view its GPU impact and shader macro."),
                    ix, iy, infoW - 24, CelestiaTheme.TEXT_MUTED);
            }
        }

        // Footer
        int fy = height - 28;
        boolean hovReset = CelestiaWidgets.inside(mouseX, mouseY, 8, fy, 118, 20);
        boolean hovApply = CelestiaWidgets.inside(mouseX, mouseY, width - 178, fy, 82, 20);
        boolean hovDone = CelestiaWidgets.inside(mouseX, mouseY, width - 90, fy, 82, 20);

        CelestiaWidgets.drawButton(gui, font, 8, fy, 118, 20, "Reset Defaults", hovReset, false, true);
        CelestiaWidgets.drawButton(gui, font, width - 178, fy, 82, 20, "Apply", hovApply, true, true);
        CelestiaWidgets.drawButton(gui, font, width - 90, fy, 82, 20, "Done", hovDone, true, true);

        super.extractRenderState(gui, mouseX, mouseY, partialTick);
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubleClick) {
        if (super.mouseClicked(event, doubleClick)) return true;
        double mx = event.x(), my = event.y();

        // Categories
        int cy = catY + 8;
        for (String cat : categories) {
            if (CelestiaWidgets.inside(mx, my, catX + 6, cy, catW - 12, 22)) {
                activeCategory = cat;
                searchQuery = "";
                searchBox.setValue("");
                scrollOffset = 0;
                return true;
            }
            cy += 26;
        }

        // Options
        if (CelestiaWidgets.inside(mx, my, optX, optY, optW, optH)) {
            int oy = optY + 6 - (int) scrollOffset;
            for (ShaderOptionDef def : visibleOptions()) {
                if (CelestiaWidgets.inside(mx, my, optX + 6, oy, optW - 12, CelestiaWidgets.ROW_HEIGHT)) {
                    handleOptionClick(def, mx, event.button());
                    return true;
                }
                oy += CelestiaWidgets.ROW_HEIGHT;
            }
        }

        // Footer
        int fy = height - 28;
        if (CelestiaWidgets.inside(mx, my, 8, fy, 118, 20)) {
            state.resetToDefaults();
            applyOptions();
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, width - 178, fy, 82, 20)) {
            applyOptions();
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, width - 90, fy, 82, 20)) {
            applyOptions();
            onClose();
            return true;
        }
        return false;
    }

    private void handleOptionClick(ShaderOptionDef def, double mx, int button) {
        switch (def.kind()) {
            case TOGGLE -> state.set(def.id(), Boolean.toString(!state.getBoolean(def.id())));
            case ENUM -> {
                List<String> vals = def.values();
                if (vals.isEmpty()) return;
                int idx = vals.indexOf(state.get(def.id()));
                int step = button == 1 ? -1 : 1;
                state.set(def.id(), vals.get((idx + step + vals.size()) % vals.size()));
            }
            case INT_SLIDER, FLOAT_SLIDER -> {
                draggingOption = def;
                applySliderDrag(def, mx);
            }
        }
    }

    private void applySliderDrag(ShaderOptionDef def, double mx) {
        int rowW = optW - 12;
        int controlW = Math.min(136, Math.max(96, rowW / 3));
        int ctrlX = optX + 6 + rowW - controlW - 8;
        double t = Math.max(0.0, Math.min(1.0, (mx - ctrlX) / (double) controlW));
        if (def.kind() == ShaderOptionDef.Kind.INT_SLIDER) {
            int min = (int) Math.round(def.min());
            int max = (int) Math.round(def.max());
            int step = Math.max(1, (int) Math.round(def.step()));
            int raw = (int) Math.round(min + t * (max - min));
            int snapped = min + ((raw - min + step / 2) / step) * step;
            state.set(def.id(), Integer.toString(Math.clamp(snapped, min, max)));
        } else {
            double step = def.step() > 0 ? def.step() : 0.05;
            double raw = def.min() + t * (def.max() - def.min());
            double snapped = def.min() + Math.round((raw - def.min()) / step) * step;
            snapped = Math.max(def.min(), Math.min(def.max(), snapped));
            state.set(def.id(), String.format(java.util.Locale.ROOT, "%.2f", snapped));
        }
    }

    @Override
    public boolean mouseDragged(MouseButtonEvent event, double dx, double dy) {
        if (draggingOption != null) {
            applySliderDrag(draggingOption, event.x());
            return true;
        }
        return super.mouseDragged(event, dx, dy);
    }

    @Override
    public boolean mouseReleased(MouseButtonEvent event) {
        draggingOption = null;
        return super.mouseReleased(event);
    }

    @Override
    public boolean mouseScrolled(double mouseX, double mouseY, double hAmount, double vAmount) {
        if (CelestiaWidgets.inside(mouseX, mouseY, optX, optY, optW, optH)) {
            scrollOffset -= vAmount * 18.0;
            return true;
        }
        return super.mouseScrolled(mouseX, mouseY, hAmount, vAmount);
    }

    @Override
    public boolean keyPressed(KeyEvent event) {
        if (event.key() == 256) {
            applyOptions();
            onClose();
            return true;
        }
        return super.keyPressed(event);
    }

    private void applyOptions() {
        ShaderPipelineManager spm = ShaderPipelineManager.get();
        state.saveToDisk(spm.shaderpacksDir());
        if (pack.id.equals(spm.activePack().id)) {
            spm.compileActivePackIfNeeded(true);
        }
    }

    @Override
    public void onClose() {
        Minecraft.getInstance().gui.setScreen(parent);
    }
}
