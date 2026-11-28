package dev.celestia.metal.ui;

import dev.celestia.metal.backend.CelestiaMetalDevice;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.perf.PerformanceEngine;
import dev.celestia.metal.shader.pack.ShaderOptionDef;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import net.minecraft.client.CloudStatus;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Options;
import net.minecraft.client.PreferredGraphicsApi;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.VideoSettingsScreen;
import net.minecraft.client.input.CharacterEvent;
import net.minecraft.client.input.KeyEvent;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ParticleStatus;

/**
 * Reese's Sodium Options-inspired tabbed & searchable Video Settings screen
 * styled with CelestiaGlow's frosted observatory aesthetic.
 */
public final class CelestiaVideoSettingsScreen extends Screen {
    public enum Tab {
        GENERAL("General"),
        QUALITY("Quality"),
        PERFORMANCE("Performance"),
        APPLE_SILICON("Apple Silicon"),
        SHADERS("Shaders"),
        ADVANCED("Advanced");

        public final String title;
        Tab(String title) { this.title = title; }
    }

    private final Screen parent;
    private final Options mcOptions;
    private final CelestiaConfig workingConfig;
    private Tab activeTab = Tab.GENERAL;
    private EditBox searchBox;
    private String searchQuery = "";
    private double scrollOffset;
    private OptionEntry hoveredEntry;
    private OptionEntry draggingSlider;
    private int listX, listY, listW, listH;
    private int lastContentW = 240;
    private int infoX, infoY, infoW, infoH;
    private int badgeX, badgeY, badgeW, badgeH;
    private boolean switchedToDefaultThisSession;
    private int pendingGuiScale;
    private boolean dirty;
    private boolean allowVanillaBypass;

    public CelestiaVideoSettingsScreen(Screen parent, Options options) {
        super(Component.literal("Celestia Metal Video Settings"));
        this.parent = parent;
        this.mcOptions = options;
        this.workingConfig = CelestiaConfig.get().copy();
        this.pendingGuiScale = options.guiScale().get();
    }

    private int searchW() {
        return Math.min(156, Math.max(96, width / 3 - 8));
    }

    private int searchX() {
        return width - searchW() - 14;
    }

    @Override
    protected void init() {
        int sx = searchX();
        int sw = searchW();
        searchBox = new EditBox(this.font, sx + 6, 17, sw - 10, 12, Component.literal("Search options..."));
        searchBox.setBordered(false);
        searchBox.setTextColor(CelestiaTheme.TEXT_MAIN);
        searchBox.setHint(Component.literal("Search options..."));
        searchBox.setValue(searchQuery);
        searchBox.setResponder(q -> {
            this.searchQuery = q;
            this.scrollOffset = 0;
        });
        addRenderableWidget(searchBox);
    }

    private List<OptionEntry> buildCurrentEntries() {
        List<OptionEntry> all = new ArrayList<>();
        if (!searchQuery.isBlank()) {
            for (Tab t : Tab.values()) {
                for (OptionEntry e : buildEntriesForTab(t)) {
                    if (e.matches(searchQuery)) all.add(e);
                }
            }
            return all;
        }
        return buildEntriesForTab(activeTab);
    }

    private List<OptionEntry> buildEntriesForTab(Tab tab) {
        List<OptionEntry> list = new ArrayList<>();
        switch (tab) {
            case GENERAL -> {
                list.add(new OptionEntry.Header("Display & Viewport"));
                list.add(new OptionEntry.IntSlider("Render Distance",
                    "Controls how many chunks around the player are rendered.",
                    ShaderOptionDef.Impact.HIGH, 2, 32, 1,
                    () -> mcOptions.renderDistance().get(),
                    v -> { mcOptions.renderDistance().set(v); dirty = true; },
                    v -> v + " chunks"));
                list.add(new OptionEntry.IntSlider("Simulation Distance",
                    "Controls how far away entities and block ticks update.",
                    ShaderOptionDef.Impact.MEDIUM, 5, 32, 1,
                    () -> mcOptions.simulationDistance().get(),
                    v -> { mcOptions.simulationDistance().set(v); dirty = true; },
                    v -> v + " chunks"));
                list.add(new OptionEntry.IntSlider("Max Framerate",
                    "Caps maximum FPS. 260 means Unlimited.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, 10, 260, 10,
                    () -> mcOptions.framerateLimit().get(),
                    v -> { mcOptions.framerateLimit().set(v); dirty = true; },
                    v -> v >= 260 ? "Unlimited" : (v + " FPS")));
                list.add(new OptionEntry.Toggle("VSync / ProMotion Sync",
                    "Synchronizes presentation to the MacBook display (120 Hz ProMotion).",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> mcOptions.enableVsync().get(),
                    v -> { mcOptions.enableVsync().set(v); dirty = true; }));
                list.add(new OptionEntry.Toggle("Fullscreen",
                    "Toggles macOS fullscreen window mode.",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> mcOptions.fullscreen().get(),
                    v -> { mcOptions.fullscreen().set(v); dirty = true; }));
                var window = Minecraft.getInstance().getWindow();
                int windowMaxScale = window != null ? window.calculateScale(0, mcOptions.forceUnicodeFont().get()) : 8;
                int maxGuiScale = Math.max(8, Math.max(pendingGuiScale, windowMaxScale));
                list.add(new OptionEntry.IntSlider("GUI Scale",
                    "Interface scale factor (0 = Auto). Applied when clicking Apply or Done so dragging never shifts the UI.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, 0, maxGuiScale, 1,
                    () -> pendingGuiScale,
                    v -> { pendingGuiScale = v; dirty = true; },
                    v -> v == 0 ? "Auto" : (v + "x")));
                list.add(new OptionEntry.FloatSlider("Brightness",
                    "Adjusts gamma curve for dark caves and night scenes.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, 0.0, 1.0, 0.05,
                    () -> mcOptions.gamma().get(),
                    v -> { mcOptions.gamma().set(v); dirty = true; },
                    v -> Math.round(v * 100) + "%"));
            }
            case QUALITY -> {
                list.add(new OptionEntry.Header("World & Visual Quality"));
                list.add(new OptionEntry.Toggle("Smooth Lighting",
                    "Ambient occlusion across block vertices.",
                    ShaderOptionDef.Impact.LOW,
                    () -> mcOptions.ambientOcclusion().get(),
                    v -> { mcOptions.ambientOcclusion().set(v); workingConfig.quality.smoothLighting = v; dirty = true; }));
                list.add(new OptionEntry.IntSlider("Biome Blend",
                    "Smoothness of grass and foliage color transitions across biomes.",
                    ShaderOptionDef.Impact.LOW, 0, 7, 1,
                    () -> mcOptions.biomeBlendRadius().get(),
                    v -> { mcOptions.biomeBlendRadius().set(v); workingConfig.quality.biomeBlendRadius = v; dirty = true; },
                    v -> v == 0 ? "Off" : (v * 2 + 1) + "x" + (v * 2 + 1)));
                list.add(new OptionEntry.Cycle<>("Clouds",
                    "Vanilla cloud rendering mode (Native MSL shaders override with volumetric clouds when active).",
                    ShaderOptionDef.Impact.LOW, Arrays.asList(CloudStatus.values()),
                    () -> mcOptions.cloudStatus().get(),
                    v -> { mcOptions.cloudStatus().set(v); dirty = true; },
                    CloudStatus::name));
                list.add(new OptionEntry.IntSlider("Weather Radius",
                    "Controls how far rain and snow are drawn from the camera. Lower values reduce GPU work during storms.",
                    ShaderOptionDef.Impact.MEDIUM, 3, 10, 1,
                    () -> mcOptions.weatherRadius().get(),
                    v -> { mcOptions.weatherRadius().set(v); dirty = true; },
                    v -> v + " blocks"));
                list.add(new OptionEntry.Toggle("Cutout Leaves",
                    "Renders transparent gaps in leaf blocks.",
                    ShaderOptionDef.Impact.LOW,
                    () -> mcOptions.cutoutLeaves().get(),
                    v -> { mcOptions.cutoutLeaves().set(v); workingConfig.quality.cutoutLeaves = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Entity Shadows",
                    "Draws ground contact shadows underneath mobs and items.",
                    ShaderOptionDef.Impact.LOW,
                    () -> mcOptions.entityShadows().get(),
                    v -> { mcOptions.entityShadows().set(v); workingConfig.quality.entityShadows = v; dirty = true; }));
                list.add(new OptionEntry.Cycle<>("Particles",
                    "Density of particle effects.",
                    ShaderOptionDef.Impact.LOW, Arrays.asList(ParticleStatus.values()),
                    () -> mcOptions.particles().get(),
                    v -> { mcOptions.particles().set(v); dirty = true; },
                    ParticleStatus::name));
                list.add(new OptionEntry.IntSlider("Mipmap Levels",
                    "Reduces texture shimmer in the distance.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, 0, 4, 1,
                    () -> mcOptions.mipmapLevels().get(),
                    v -> { mcOptions.mipmapLevels().set(v); workingConfig.quality.mipmapLevels = v; dirty = true; },
                    v -> v == 0 ? "Off" : (v + "x")));
                list.add(new OptionEntry.Toggle("Vignette",
                    "Darkens screen edges slightly in dim areas.",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> mcOptions.vignette().get(),
                    v -> { mcOptions.vignette().set(v); workingConfig.quality.vignette = v; dirty = true; }));
            }
            case PERFORMANCE -> {
                list.add(new OptionEntry.Header("Metal Rendering & Memory"));
                list.add(new OptionEntry.Toggle("Size-Bucketed Buffer Pooling",
                    "Reuses MTLStorageModeShared buffers after GPU submit completion to eliminate GC/allocation stalls.",
                    ShaderOptionDef.Impact.LOW,
                    () -> workingConfig.performance.bufferPooling,
                    v -> { workingConfig.performance.bufferPooling = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Relaxed Terrain Math",
                    "Uses fast IEEE math selectively for terrain pipelines while keeping sky/UI/post exact.",
                    ShaderOptionDef.Impact.LOW,
                    () -> workingConfig.performance.relaxedTerrainMath,
                    v -> { workingConfig.performance.relaxedTerrainMath = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Chunk Upload Pacing",
                    "Limits chunk GPU uploads per frame to prevent frame-time p99 hitches.",
                    ShaderOptionDef.Impact.LOW,
                    () -> workingConfig.performance.chunkUploadPacing,
                    v -> { workingConfig.performance.chunkUploadPacing = v; dirty = true; }));
                list.add(new OptionEntry.IntSlider("Max Chunk Uploads / Frame",
                    "Upper bound on chunk buffer uploads per frame when pacing is enabled.",
                    ShaderOptionDef.Impact.MEDIUM, 1, 16, 1,
                    () -> workingConfig.performance.maxChunkUploadsPerFrame,
                    v -> { workingConfig.performance.maxChunkUploadsPerFrame = v; dirty = true; },
                    v -> v + " chunks"));
                list.add(new OptionEntry.Toggle("Distant Terrain LOD",
                    "Simplifies distant geometry beyond the full-detail radius for higher FPS at 16+ chunks.",
                    ShaderOptionDef.Impact.MEDIUM,
                    () -> workingConfig.performance.terrainLod,
                    v -> { workingConfig.performance.terrainLod = v; dirty = true; }));
                list.add(new OptionEntry.IntSlider("Full-Detail Terrain Radius",
                    "Percentage of render distance rendered at full detail before LOD simplification.",
                    ShaderOptionDef.Impact.MEDIUM, 40, 100, 5,
                    () -> workingConfig.performance.terrainLodRadiusPercent,
                    v -> { workingConfig.performance.terrainLodRadiusPercent = v; dirty = true; },
                    v -> v + "%"));
            }
            case APPLE_SILICON -> {
                list.add(new OptionEntry.Header("Metal 4 & Apple GPU"));
                list.add(new OptionEntry.Cycle<>("Metal API Mode",
                    "Auto uses Metal 4 (MTL4CommandQueue, MTL4Compiler, MTLResidencySet) on macOS 26+.",
                    ShaderOptionDef.Impact.LOW, Arrays.asList(CelestiaConfig.MetalMode.values()),
                    () -> workingConfig.appleSilicon.metalMode,
                    v -> { workingConfig.appleSilicon.metalMode = v; dirty = true; },
                    m -> switch (m) {
                        case AUTO_METAL_4 -> "Auto (Metal 4)";
                        case METAL_4 -> "Metal 4";
                        case METAL_3 -> "Metal 3";
                    }));
                list.add(new OptionEntry.Toggle("Low-Latency Queue (2 Frames)",
                    "Limits in-flight GPU submits to 2 frames for crisp input response on 120 Hz ProMotion.",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> workingConfig.appleSilicon.lowLatencyQueue,
                    v -> { workingConfig.appleSilicon.lowLatencyQueue = v; dirty = true; }));

                list.add(new OptionEntry.Header("MetalFX Upscaling & HDR"));
                list.add(new OptionEntry.Toggle("Auto Render Scale",
                    "Adjusts internal resolution to meet the display refresh rate or your lower FPS cap.",
                    ShaderOptionDef.Impact.HIGH,
                    () -> workingConfig.appleSilicon.autoRenderScale,
                    v -> { workingConfig.appleSilicon.autoRenderScale = v; dirty = true; }));
                list.add(new OptionEntry.IntSlider("Internal Render Scale",
                    "Renders the 3D world at this percentage of the window resolution and upscales it; menus, HUD and "
                        + "overlays stay sharp. Lowers GPU cost, most useful with shader packs.",
                    ShaderOptionDef.Impact.HIGH, 50, 100, 5,
                    () -> workingConfig.appleSilicon.renderScalePercent,
                    v -> { workingConfig.appleSilicon.renderScalePercent = v; dirty = true; },
                    v -> v + "%"));
                list.add(new OptionEntry.Cycle<>("Upscaler",
                    "Upscales the world below 100% render scale. TAAU uses previous frames to reduce shimmering. "
                        + "MetalFX Temporal uses the Spatial path.",
                    ShaderOptionDef.Impact.MEDIUM, Arrays.asList(CelestiaConfig.UpscalerMode.values()),
                    () -> workingConfig.appleSilicon.upscaler,
                    v -> { workingConfig.appleSilicon.upscaler = v; dirty = true; },
                    u -> switch (u) {
                        case METALFX_TEMPORAL -> "MetalFX Temporal";
                        case METALFX_SPATIAL -> "MetalFX Spatial";
                        case BILINEAR -> "Bilinear";
                        case TAAU -> "TAAU";
                    }));
                list.add(new OptionEntry.Toggle("HDR / EDR Highlights",
                    "Uses RGBA16Float Extended Linear Display P3 swapchain for XDR / ProMotion HDR highlights.",
                    ShaderOptionDef.Impact.LOW,
                    () -> workingConfig.appleSilicon.hdrEnabled,
                    v -> { workingConfig.appleSilicon.hdrEnabled = v; dirty = true; }));
                list.add(new OptionEntry.FloatSlider("HDR Peak Headroom",
                    "Maximum peak luminance target in nits on XDR displays.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, 400.0, 1600.0, 100.0,
                    () -> workingConfig.appleSilicon.hdrPeakNits,
                    v -> { workingConfig.appleSilicon.hdrPeakNits = (float) v; dirty = true; },
                    v -> Math.round(v) + " nits"));

                list.add(new OptionEntry.Header("Thermal, Battery & HUD"));
                list.add(new OptionEntry.Cycle<>("Thermal & Battery Policy",
                    "Responds automatically to macOS thermal pressure and Low Power Mode.",
                    ShaderOptionDef.Impact.LOW, Arrays.asList(CelestiaConfig.ThermalMode.values()),
                    () -> workingConfig.appleSilicon.thermalMode,
                    v -> { workingConfig.appleSilicon.thermalMode = v; dirty = true; },
                    t -> switch (t) {
                        case OFF -> "Unlimited";
                        case BALANCED -> "Balanced";
                        case BATTERY_SAVER -> "Battery Saver";
                    }));
                list.add(new OptionEntry.Cycle<>("Performance HUD",
                    "Shows a frosted CelestiaGlow FPS / GPU ms pill in the top-left corner.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, Arrays.asList(CelestiaConfig.HudMode.values()),
                    () -> workingConfig.appleSilicon.performanceHud,
                    v -> { workingConfig.appleSilicon.performanceHud = v; dirty = true; },
                    h -> switch (h) {
                        case OFF -> "Off";
                        case COMPACT -> "Compact";
                        case DETAILED -> "Detailed";
                    }));
            }
            case SHADERS -> {
                ShaderPipelineManager spm = ShaderPipelineManager.get();
                list.add(new OptionEntry.Header("Native MSL Shader Packs"));
                list.add(new OptionEntry.Action("Shader Packs",
                    "Active pack: " + spm.activeDisplayName() + " (" + spm.activePack().kind.badge + "). Browse, switch, or hot-reload native MSL packs.",
                    "Open Shader Packs...", ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> Minecraft.getInstance().gui.setScreen(new CelestiaShaderPacksScreen(this))));
                list.add(new OptionEntry.Action("Configure Current Pack",
                    "Edit presets and options for " + spm.activePack().name + ".",
                    "Shader Options...", ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> {
                        if (spm.activePack().kind != dev.celestia.metal.shader.pack.ShaderPackManifest.PackKind.OFF) {
                            Minecraft.getInstance().gui.setScreen(new CelestiaShaderOptionsScreen(this, spm.activePack()));
                        }
                    }));
                list.add(new OptionEntry.Toggle("Binary Pipeline Archive Cache",
                    "Caches compiled Metal pipeline states on disk to eliminate shader compile hitches across launches.",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> workingConfig.shaders.binaryPipelineCache,
                    v -> { workingConfig.shaders.binaryPipelineCache = v; dirty = true; }));
            }
            case ADVANCED -> {
                list.add(new OptionEntry.Header("Diagnostics & Compatibility"));
                list.add(new OptionEntry.Cycle<>("Graphics API Preference",
                    "Default tries Celestia Metal first. Requires game restart to switch backend.",
                    ShaderOptionDef.Impact.NEGLIGIBLE, Arrays.asList(PreferredGraphicsApi.values()),
                    () -> mcOptions.preferredGraphicsBackend().get(),
                    v -> { mcOptions.preferredGraphicsBackend().set(v); dirty = true; },
                    api -> switch (api) {
                        case DEFAULT -> "Default (Metal)";
                        case OPENGL -> "OpenGL";
                        case VULKAN -> "Vulkan";
                    }));
                list.add(new OptionEntry.Toggle("Non-Blocking Present",
                    "With VSync off, the game never waits for the display: the newest finished frame is shown each refresh "
                        + "without tearing, lifting the cap near twice the refresh rate. Turn off to present every frame in order.",
                    ShaderOptionDef.Impact.HIGH,
                    () -> workingConfig.appleSilicon.nonBlockingPresent,
                    v -> { workingConfig.appleSilicon.nonBlockingPresent = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Render Pass Merging",
                    "Continues the open Metal render encoder for consecutive passes drawing to the same targets, "
                        + "saving a full-resolution tile store/load per pass. Turn off if a mod renders incorrectly.",
                    ShaderOptionDef.Impact.HIGH,
                    () -> workingConfig.performance.renderPassMerging,
                    v -> { workingConfig.performance.renderPassMerging = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Deferred Clears",
                    "Folds texture clears into the next render pass instead of running separate clear passes. "
                        + "Turn off if a mod renders incorrectly.",
                    ShaderOptionDef.Impact.MEDIUM,
                    () -> workingConfig.performance.deferredClears,
                    v -> { workingConfig.performance.deferredClears = v; dirty = true; }));
                list.add(new OptionEntry.Toggle("Metal Validation Labels",
                    "Attaches debug labels to buffers, textures, and render encoders.",
                    ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> workingConfig.advanced.validationLabels,
                    v -> { workingConfig.advanced.validationLabels = v; dirty = true; }));
                list.add(new OptionEntry.Action("Vanilla Video Settings",
                    "Opens Minecraft's stock Video Settings screen for any mod-injected vanilla controls.",
                    "Open Vanilla...", ShaderOptionDef.Impact.NEGLIGIBLE,
                    () -> {
                        allowVanillaBypass = true;
                        Minecraft.getInstance().gui.setScreen(new VideoSettingsScreen(this, Minecraft.getInstance(), mcOptions));
                    }));
            }
        }
        return list;
    }

    public boolean shouldBypassReplacement() {
        return allowVanillaBypass;
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor gui, int mouseX, int mouseY, float partialTick) {
        CelestiaTheme.drawBackdrop(gui, width, height);

        // Header bar
        CelestiaTheme.drawGlassPanel(gui, 8, 6, width - 16, 30, false);
        String titleStr = "✦ Celestia Metal";
        gui.text(font, titleStr, 18, 17, CelestiaTheme.ACCENT_BRIGHT, false);

        int sx = searchX();
        int sw = searchW();
        CelestiaTheme.drawSearchFieldChrome(gui, sx, 12, sw, 18, searchBox != null && searchBox.isFocused());

        CelestiaMetalDevice dev = CelestiaMetalDevice.current;
        PerformanceEngine perf = PerformanceEngine.get();
        PreferredGraphicsApi configuredApi = mcOptions.preferredGraphicsBackend().get();
        String statusBadge;
        int badgeColor;
        if (dev != null) {
            statusBadge = (dev.isMetal4() ? "Metal 4 · " : "Metal 3 · ") + perf.displayRefreshHz() + " Hz";
            badgeColor = CelestiaTheme.BADGE_GREEN;
        } else if (configuredApi == PreferredGraphicsApi.OPENGL) {
            statusBadge = "OpenGL · Click -> Metal";
            badgeColor = CelestiaTheme.ORB_ROSE;
        } else if (switchedToDefaultThisSession || configuredApi == PreferredGraphicsApi.DEFAULT) {
            statusBadge = "Metal Ready · Restart";
            badgeColor = CelestiaTheme.ACCENT_LAVENDER;
        } else {
            statusBadge = "Vulkan · Click -> Metal";
            badgeColor = CelestiaTheme.ORB_GOLD;
        }
        badgeX = 18 + font.width(titleStr) + 8;
        badgeY = 14;
        int maxBadgeW = Math.max(40, sx - badgeX - 8);
        badgeW = CelestiaTheme.drawBadgeClipped(gui, font, statusBadge, badgeX, badgeY, maxBadgeW, badgeColor);
        badgeH = 14;

        // Tab bar (proportional widths so longer labels like Performance and Apple Silicon fit cleanly)
        Tab[] tabs = Tab.values();
        String[] tabLabels = new String[tabs.length];
        for (int i = 0; i < tabs.length; i++) tabLabels[i] = tabs[i].title;
        int tabGap = 4;
        int[] tabWidths = CelestiaWidgets.computeProportionalWidths(font, tabLabels, width - 16, tabGap, 8, 16);
        int tabY = 42;
        int tabH = 22;
        int tx = 8;
        for (int i = 0; i < tabs.length; i++) {
            int tw = tabWidths[i];
            boolean hov = CelestiaWidgets.inside(mouseX, mouseY, tx, tabY, tw, tabH);
            boolean sel = searchQuery.isBlank() && activeTab == tabs[i];
            CelestiaWidgets.drawButton(gui, font, tx, tabY, tw, tabH, tabs[i].title, hov, sel, true);
            tx += tw + tabGap;
        }

        // Main split area
        boolean wide = width >= 540;
        listX = 8;
        listY = 70;
        listH = height - listY - 38;
        if (wide) {
            infoW = Math.min(220, width / 3);
            listW = width - infoW - 24;
            infoX = listX + listW + 8;
            infoY = listY;
            infoH = listH;
        } else {
            listW = width - 16;
            infoW = 0;
        }

        CelestiaTheme.drawGlassPanel(gui, listX, listY, listW, listH, false);

        List<OptionEntry> entries = buildCurrentEntries();
        int totalH = 8;
        for (OptionEntry e : entries) totalH += CelestiaWidgets.rowHeight(e);
        int maxScroll = Math.max(0, totalH - (listH - 8));
        scrollOffset = Math.max(0.0, Math.min(scrollOffset, maxScroll));
        int contentW = maxScroll > 0 ? (listW - 18) : (listW - 12);
        this.lastContentW = contentW;

        hoveredEntry = null;
        gui.enableScissor(listX + 2, listY + 4, listX + listW - 2, listY + listH - 4);
        int cy = listY + 6 - (int) scrollOffset;
        for (OptionEntry e : entries) {
            int rh = CelestiaWidgets.rowHeight(e);
            if (cy + rh >= listY && cy <= listY + listH) {
                boolean hov = CelestiaWidgets.inside(mouseX, mouseY, listX + 6, cy, contentW, rh - 2)
                    && CelestiaWidgets.inside(mouseX, mouseY, listX, listY + 2, listW, listH - 4);
                if (hov && !(e instanceof OptionEntry.Header)) hoveredEntry = e;
                CelestiaWidgets.drawOptionRow(gui, font, e, listX + 6, cy, contentW, hov);
            }
            cy += rh;
        }
        CelestiaTheme.drawScrollFades(gui, listX + 2, listY + 4, listW - 4, listH - 8, scrollOffset, maxScroll);
        gui.disableScissor();
        CelestiaTheme.drawScrollbar(gui, listX + listW - 6, listY + 6, listH - 12, scrollOffset, maxScroll, totalH);

        // Contextual info + Apple Silicon telemetry panel
        if (wide) {
            CelestiaTheme.drawGlassPanel(gui, infoX, infoY, infoW, infoH, false);
            int ix = infoX + 12;
            int iy = infoY + 12;
            if (hoveredEntry != null) {
                gui.text(font, font.plainSubstrByWidth(hoveredEntry.label(), infoW - 24), ix, iy, CelestiaTheme.ACCENT_BRIGHT, false);
                iy += 14;
                CelestiaTheme.drawBadge(gui, font, "Impact: " + hoveredEntry.impact().label, ix, iy, hoveredEntry.impact().color);
                iy += 22;
                gui.textWithWordWrap(font, Component.literal(hoveredEntry.description()), ix, iy, infoW - 24, CelestiaTheme.TEXT_MUTED);
            } else {
                gui.text(font, "✦ Observatory Telemetry", ix, iy, CelestiaTheme.ACCENT_LAVENDER, false);
                iy += 16;
                MetalNative.ProbeInfo probe = CelestiaMetalDevice.current != null ? CelestiaMetalDevice.current.probeInfo() : null;
                String gpu = probe != null ? probe.gpuName() : "Apple Silicon GPU";
                gui.text(font, font.plainSubstrByWidth(gpu, infoW - 24), ix, iy, CelestiaTheme.TEXT_MAIN, false);
                iy += 13;
                if (dev == null && configuredApi != PreferredGraphicsApi.DEFAULT) {
                    gui.textWithWordWrap(font, Component.literal("Active API: " + configuredApi.name()
                        + ". Click the status pill above or set Graphics API Preference to Default (Metal) and restart."),
                        ix, iy, infoW - 24, CelestiaTheme.ORB_ROSE);
                } else {
                    gui.text(font, String.format("FPS: %.0f (1%% low: %.0f)", perf.averageFps(), perf.onePercentLowFps()),
                        ix, iy, CelestiaTheme.TEXT_MUTED, false);
                    iy += 12;
                    gui.text(font, String.format("GPU Frame: %.2f ms", perf.ewmaGpuMs()), ix, iy, CelestiaTheme.TEXT_MUTED, false);
                    iy += 12;
                    gui.text(font, "Thermal: " + perf.thermalLabel() + (perf.isLowPowerMode() ? " (Low Power)" : ""),
                        ix, iy, CelestiaTheme.TEXT_MUTED, false);
                    iy += 12;
                    gui.text(font, "Shader: " + ShaderPipelineManager.get().activeDisplayName(),
                        ix, iy, CelestiaTheme.ACCENT_BRIGHT, false);
                }
            }
        }

        // Footer bar
        int fy = height - 28;
        int bw = Math.min(82, Math.max(54, (width - 148) / 3));
        int spW = Math.min(112, Math.max(88, width - bw * 3 - 34));
        boolean hovShaders = CelestiaWidgets.inside(mouseX, mouseY, 8, fy, spW, 20);
        CelestiaWidgets.drawButton(gui, font, 8, fy, spW, 20, "✦ Shader Packs", hovShaders, false, true);

        boolean hovUndo = CelestiaWidgets.inside(mouseX, mouseY, width - bw * 3 - 20, fy, bw, 20);
        boolean hovApply = CelestiaWidgets.inside(mouseX, mouseY, width - bw * 2 - 14, fy, bw, 20);
        boolean hovDone = CelestiaWidgets.inside(mouseX, mouseY, width - bw - 8, fy, bw, 20);

        CelestiaWidgets.drawButton(gui, font, width - bw * 3 - 20, fy, bw, 20, "Reset", hovUndo, false, dirty);
        CelestiaWidgets.drawButton(gui, font, width - bw * 2 - 14, fy, bw, 20, "Apply", hovApply, dirty, dirty);
        CelestiaWidgets.drawButton(gui, font, width - bw - 8, fy, bw, 20, "Done", hovDone, true, true);

        super.extractRenderState(gui, mouseX, mouseY, partialTick);
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubleClick) {
        if (super.mouseClicked(event, doubleClick)) return true;
        double mx = event.x();
        double my = event.y();

        // Clickable backend badge when running on OpenGL/Vulkan fallback
        if (CelestiaMetalDevice.current == null && CelestiaWidgets.inside(mx, my, badgeX, badgeY, badgeW, badgeH)) {
            if (mcOptions.preferredGraphicsBackend().get() != PreferredGraphicsApi.DEFAULT) {
                mcOptions.preferredGraphicsBackend().set(PreferredGraphicsApi.DEFAULT);
                mcOptions.save();
                switchedToDefaultThisSession = true;
            }
            return true;
        }

        // Tab clicks
        Tab[] tabs = Tab.values();
        String[] tabLabels = new String[tabs.length];
        for (int i = 0; i < tabs.length; i++) tabLabels[i] = tabs[i].title;
        int tabGap = 4;
        int[] tabWidths = CelestiaWidgets.computeProportionalWidths(font, tabLabels, width - 16, tabGap, 8, 16);
        int tabY = 42, tabH = 22;
        int tx = 8;
        for (int i = 0; i < tabs.length; i++) {
            int tw = tabWidths[i];
            if (CelestiaWidgets.inside(mx, my, tx, tabY, tw, tabH)) {
                activeTab = tabs[i];
                searchQuery = "";
                searchBox.setValue("");
                scrollOffset = 0;
                return true;
            }
            tx += tw + tabGap;
        }

        // Footer buttons
        int fy = height - 28;
        int bw = Math.min(82, Math.max(54, (width - 148) / 3));
        int spW = Math.min(112, Math.max(88, width - bw * 3 - 34));
        if (CelestiaWidgets.inside(mx, my, 8, fy, spW, 20)) {
            Minecraft.getInstance().gui.setScreen(new CelestiaShaderPacksScreen(this));
            return true;
        }
        if (dirty && CelestiaWidgets.inside(mx, my, width - bw * 3 - 20, fy, bw, 20)) {
            CelestiaConfig fresh = CelestiaConfig.get().copy();
            workingConfig.quality = fresh.quality;
            workingConfig.performance = fresh.performance;
            workingConfig.appleSilicon = fresh.appleSilicon;
            workingConfig.shaders = fresh.shaders;
            workingConfig.advanced = fresh.advanced;
            pendingGuiScale = mcOptions.guiScale().get();
            dirty = false;
            return true;
        }
        if (dirty && CelestiaWidgets.inside(mx, my, width - bw * 2 - 14, fy, bw, 20)) {
            applyChanges();
            return true;
        }
        if (CelestiaWidgets.inside(mx, my, width - bw - 8, fy, bw, 20)) {
            onClose();
            return true;
        }

        // Option rows
        if (CelestiaWidgets.inside(mx, my, listX, listY, listW, listH)) {
            List<OptionEntry> entries = buildCurrentEntries();
            int cy = listY + 6 - (int) scrollOffset;
            for (OptionEntry e : entries) {
                int rh = CelestiaWidgets.rowHeight(e);
                if (CelestiaWidgets.inside(mx, my, listX + 6, cy, lastContentW, rh - 2)) {
                    handleRowClick(e, mx, event.button());
                    return true;
                }
                cy += rh;
            }
        }
        return false;
    }

    @Override
    public boolean mouseDragged(MouseButtonEvent event, double dx, double dy) {
        if (draggingSlider != null) {
            applySliderDrag(draggingSlider, event.x());
            return true;
        }
        return super.mouseDragged(event, dx, dy);
    }

    @Override
    public boolean mouseReleased(MouseButtonEvent event) {
        draggingSlider = null;
        return super.mouseReleased(event);
    }

    @Override
    public boolean mouseScrolled(double mouseX, double mouseY, double hAmount, double vAmount) {
        if (CelestiaWidgets.inside(mouseX, mouseY, listX, listY, listW, listH)) {
            scrollOffset -= vAmount * 18.0;
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
    public boolean charTyped(CharacterEvent event) {
        return super.charTyped(event);
    }

    private void handleRowClick(OptionEntry e, double mx, int button) {
        switch (e) {
            case OptionEntry.Toggle t -> t.setter().accept(!Boolean.TRUE.equals(t.getter().get()));
            case OptionEntry.Cycle<?> c -> {
                @SuppressWarnings("unchecked")
                OptionEntry.Cycle<Object> raw = (OptionEntry.Cycle<Object>) c;
                List<Object> vals = raw.values();
                int idx = vals.indexOf(raw.getter().get());
                int step = button == 1 ? -1 : 1;
                int next = (idx + step + vals.size()) % vals.size();
                raw.setter().accept(vals.get(next));
            }
            case OptionEntry.IntSlider s -> {
                draggingSlider = s;
                applySliderDrag(s, mx);
            }
            case OptionEntry.FloatSlider s -> {
                draggingSlider = s;
                applySliderDrag(s, mx);
            }
            case OptionEntry.Action a -> a.action().run();
            case OptionEntry.Header ignored -> {}
        }
    }

    private void applySliderDrag(OptionEntry entry, double mx) {
        int rowW = lastContentW;
        int controlW = Math.min(136, Math.max(96, rowW / 3));
        int ctrlX = listX + 6 + rowW - controlW - 8;
        double t = Math.max(0.0, Math.min(1.0, (mx - ctrlX) / (double) controlW));
        if (entry instanceof OptionEntry.IntSlider s) {
            int raw = (int) Math.round(s.min() + t * (s.max() - s.min()));
            int snapped = s.min() + ((raw - s.min() + s.step() / 2) / s.step()) * s.step();
            s.setter().accept(Math.clamp(snapped, s.min(), s.max()));
        } else if (entry instanceof OptionEntry.FloatSlider s) {
            double raw = s.min() + t * (s.max() - s.min());
            double snapped = s.min() + Math.round((raw - s.min()) / s.step()) * s.step();
            s.setter().accept(Math.max(s.min(), Math.min(s.max(), snapped)));
        }
    }

    private void applyChanges() {
        CelestiaConfig.replace(workingConfig.copy());
        if (pendingGuiScale != mcOptions.guiScale().get()) {
            mcOptions.guiScale().set(pendingGuiScale);
            pendingGuiScale = mcOptions.guiScale().get();
        }
        mcOptions.save();
        dirty = false;
    }

    @Override
    public void onClose() {
        if (dirty) applyChanges();
        Minecraft.getInstance().gui.setScreen(parent);
    }
}
