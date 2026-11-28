package dev.celestia.metal.ui;

import dev.celestia.metal.perf.CelestiaConfig;
import java.util.function.Consumer;
import java.util.function.Function;
import java.util.function.Supplier;
import net.caffeinemc.mods.sodium.api.config.ConfigEntryPoint;
import net.caffeinemc.mods.sodium.api.config.StorageEventHandler;
import net.caffeinemc.mods.sodium.api.config.option.OptionFlag;
import net.caffeinemc.mods.sodium.api.config.option.OptionImpact;
import net.caffeinemc.mods.sodium.api.config.structure.BooleanOptionBuilder;
import net.caffeinemc.mods.sodium.api.config.structure.ConfigBuilder;
import net.caffeinemc.mods.sodium.api.config.structure.EnumOptionBuilder;
import net.caffeinemc.mods.sodium.api.config.structure.OptionGroupBuilder;
import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;

/**
 * Registers Celestia Metal's Apple Silicon, Performance, Shader Packs, and CelestiaGlow UI
 * pages directly inside Sodium 0.9+ / Reese's Sodium Options via Sodium's Config API.
 * All Sodium API types are isolated to this entrypoint so the mod runs cleanly without Sodium.
 */
public final class CelestiaSodiumConfigEntrypoint implements ConfigEntryPoint {
    private static final String NAMESPACE = "celestiametal";
    private static final int CELESTIA_LAVENDER_RGB = 0xC8B3E4;

    @Override
    public void registerConfigLate(ConfigBuilder builder) {
        StorageEventHandler saveHandler = () -> CelestiaConfig.get().save();

        OptionGroupBuilder backendGroup = builder.createOptionGroup()
            .setName(Component.literal("Metal Backend & Presentation"))
            .addOption(enumOpt(builder, "metal_mode",
                "Metal API Mode",
                "Select Metal 4 on macOS 26+, automatic fallback, or Metal 3 compatibility mode.",
                CelestiaConfig.MetalMode.class,
                CelestiaConfig.MetalMode.AUTO_METAL_4,
                OptionImpact.VARIES,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.metalMode,
                v -> CelestiaConfig.get().appleSilicon.metalMode = v,
                CelestiaSodiumConfigEntrypoint::formatMetalMode,
                OptionFlag.REQUIRES_GAME_RESTART))
            .addOption(boolOpt(builder, "hdr_enabled",
                "HDR / EDR Output",
                "Enable 16-bit floating-point Extended Linear Display P3 output on supported Retina XDR displays.",
                false,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.hdrEnabled,
                v -> CelestiaConfig.get().appleSilicon.hdrEnabled = v,
                OptionFlag.REQUIRES_GAME_RESTART))
            .addOption(boolOpt(builder, "low_latency_queue",
                "Low Latency Queue",
                "Cap Metal command submission queue depth to 2 frames in flight for lower input latency.",
                true,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.lowLatencyQueue,
                v -> CelestiaConfig.get().appleSilicon.lowLatencyQueue = v))
            .addOption(boolOpt(builder, "promotion_pacing",
                "ProMotion 120 Hz Pacing",
                "Align swapchain sync and render pacing with Apple Silicon ProMotion display refresh rates.",
                true,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.promotionFramePacing,
                v -> CelestiaConfig.get().appleSilicon.promotionFramePacing = v))
            .addOption(enumOpt(builder, "performance_hud",
                "Performance HUD Pill",
                "Show CelestiaGlow FPS, GPU frame time, Metal API mode, and active shader pack overlay.",
                CelestiaConfig.HudMode.class,
                CelestiaConfig.HudMode.COMPACT,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.performanceHud,
                v -> CelestiaConfig.get().appleSilicon.performanceHud = v,
                CelestiaSodiumConfigEntrypoint::formatHudMode));

        OptionGroupBuilder scalingGroup = builder.createOptionGroup()
            .setName(Component.literal("Scaling & Thermals"))
            .addOption(enumOpt(builder, "upscaler",
                "MetalFX Upscaler",
                "TAAU uses previous frames to reduce shimmering. MetalFX Temporal uses the Spatial path.",
                CelestiaConfig.UpscalerMode.class,
                CelestiaConfig.UpscalerMode.METALFX_TEMPORAL,
                OptionImpact.HIGH,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.upscaler,
                v -> CelestiaConfig.get().appleSilicon.upscaler = v,
                CelestiaSodiumConfigEntrypoint::formatUpscaler))
            .addOption(boolOpt(builder, "auto_render_scale",
                "Auto Render Scale",
                "Adjusts internal resolution to meet the display refresh rate or your lower FPS cap.",
                false,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.autoRenderScale,
                v -> CelestiaConfig.get().appleSilicon.autoRenderScale = v))
            .addOption(builder.createIntegerOption(id("render_scale"))
                .setName(Component.literal("Render Scale"))
                .setTooltip(Component.literal("Target internal render resolution percentage before MetalFX upscaling."))
                .setRange(50, 100, 5)
                .setValueFormatter(v -> Component.literal(v + "%"))
                .setDefaultValue(100)
                .setImpact(OptionImpact.HIGH)
                .setStorageHandler(saveHandler)
                .setBinding(v -> CelestiaConfig.get().appleSilicon.renderScalePercent = v,
                    () -> CelestiaConfig.get().appleSilicon.renderScalePercent))
            .addOption(enumOpt(builder, "thermal_mode",
                "Thermal & Battery Policy",
                "Automatically throttle background work under macOS Low Power Mode or Fair/Serious thermal pressure.",
                CelestiaConfig.ThermalMode.class,
                CelestiaConfig.ThermalMode.BALANCED,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.thermalMode,
                v -> CelestiaConfig.get().appleSilicon.thermalMode = v,
                CelestiaSodiumConfigEntrypoint::formatThermalMode));

        var appleSiliconPage = builder.createOptionPage()
            .setName(Component.literal("Apple Silicon"))
            .addOptionGroup(backendGroup)
            .addOptionGroup(scalingGroup);

        OptionGroupBuilder memoryGroup = builder.createOptionGroup()
            .setName(Component.literal("Memory & Pipelines"))
            .addOption(boolOpt(builder, "buffer_pooling",
                "Unified Buffer Pooling",
                "Reuse MTLStorageModeShared power-of-two Metal buffers across frames after GPU completion.",
                true,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().performance.bufferPooling,
                v -> CelestiaConfig.get().performance.bufferPooling = v))
            .addOption(boolOpt(builder, "indirect_batching",
                "Indirect & Multi-Draw Batching",
                "Batch terrain and pass draws through native Metal multi-draw and indirect encoding.",
                true,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().performance.indirectBatching,
                v -> CelestiaConfig.get().performance.indirectBatching = v))
            .addOption(boolOpt(builder, "relaxed_terrain_math",
                "Fast Terrain Math",
                "Allow relaxed IEEE floating-point optimizations when compiling terrain MSL pipelines.",
                true,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().performance.relaxedTerrainMath,
                v -> CelestiaConfig.get().performance.relaxedTerrainMath = v,
                OptionFlag.REQUIRES_GAME_RESTART))
            .addOption(boolOpt(builder, "binary_pipeline_cache",
                "Binary Pipeline Archive",
                "Persist compiled Metal pipelines to MTLBinaryArchive on disk for faster subsequent launches.",
                true,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().shaders.binaryPipelineCache,
                v -> CelestiaConfig.get().shaders.binaryPipelineCache = v,
                OptionFlag.REQUIRES_GAME_RESTART));

        OptionGroupBuilder uploadsGroup = builder.createOptionGroup()
            .setName(Component.literal("Uploads & Diagnostics"))
            .addOption(boolOpt(builder, "chunk_upload_pacing",
                "Chunk Upload Pacing",
                "Pace chunk GPU uploads per frame to prevent frame-time spikes when exploring new areas.",
                true,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().performance.chunkUploadPacing,
                v -> CelestiaConfig.get().performance.chunkUploadPacing = v))
            .addOption(builder.createIntegerOption(id("max_chunk_uploads"))
                .setName(Component.literal("Max Chunk Uploads / Frame"))
                .setTooltip(Component.literal("Maximum paced chunk buffer uploads allowed per rendered frame."))
                .setRange(1, 16, 1)
                .setValueFormatter(v -> Component.literal(String.valueOf(v)))
                .setDefaultValue(4)
                .setImpact(OptionImpact.MEDIUM)
                .setStorageHandler(saveHandler)
                .setBinding(v -> CelestiaConfig.get().performance.maxChunkUploadsPerFrame = v,
                    () -> CelestiaConfig.get().performance.maxChunkUploadsPerFrame))
            .addOption(boolOpt(builder, "non_blocking_present",
                "Non-Blocking Present",
                "With VSync off, never wait for the display: show the newest finished frame each refresh without tearing.",
                true,
                OptionImpact.HIGH,
                saveHandler,
                () -> CelestiaConfig.get().appleSilicon.nonBlockingPresent,
                v -> CelestiaConfig.get().appleSilicon.nonBlockingPresent = v))
            .addOption(boolOpt(builder, "render_pass_merging",
                "Render Pass Merging",
                "Continue the open Metal render encoder for consecutive passes on the same targets. Turn off if a mod renders incorrectly.",
                true,
                OptionImpact.HIGH,
                saveHandler,
                () -> CelestiaConfig.get().performance.renderPassMerging,
                v -> CelestiaConfig.get().performance.renderPassMerging = v))
            .addOption(boolOpt(builder, "deferred_clears",
                "Deferred Clears",
                "Fold texture clears into the next render pass instead of separate clear passes. Turn off if a mod renders incorrectly.",
                true,
                OptionImpact.MEDIUM,
                saveHandler,
                () -> CelestiaConfig.get().performance.deferredClears,
                v -> CelestiaConfig.get().performance.deferredClears = v))
            .addOption(boolOpt(builder, "validation_labels",
                "Metal Debug Labels",
                "Attach debug names to Metal buffers, textures, passes, and encoders (slightly higher CPU overhead).",
                false,
                OptionImpact.LOW,
                saveHandler,
                () -> CelestiaConfig.get().advanced.validationLabels,
                v -> CelestiaConfig.get().advanced.validationLabels = v,
                OptionFlag.REQUIRES_GAME_RESTART));

        var performancePage = builder.createOptionPage()
            .setName(Component.literal("Performance"))
            .addOptionGroup(memoryGroup)
            .addOptionGroup(uploadsGroup);

        var shaderPacksPage = builder.createExternalPage()
            .setName(Component.literal("Shader Packs"))
            .setScreenConsumer(parent -> Minecraft.getInstance().gui.setScreen(new CelestiaShaderPacksScreen(parent)));

        var celestiaGlowPage = builder.createExternalPage()
            .setName(Component.literal("CelestiaGlow UI"))
            .setScreenConsumer(parent -> {
                Minecraft mc = Minecraft.getInstance();
                mc.gui.setScreen(new CelestiaVideoSettingsScreen(parent, mc.options));
            });

        builder.registerOwnModOptions()
            .setName("Celestia Metal")
            .setColorTheme(builder.createColorTheme().setBaseThemeRGB(CELESTIA_LAVENDER_RGB))
            .addPage(appleSiliconPage)
            .addPage(performancePage)
            .addPage(shaderPacksPage)
            .addPage(celestiaGlowPage);
    }

    private static Identifier id(String path) {
        return Identifier.fromNamespaceAndPath(NAMESPACE, path);
    }

    private static BooleanOptionBuilder boolOpt(
        ConfigBuilder builder,
        String path,
        String name,
        String tooltip,
        boolean defaultVal,
        OptionImpact impact,
        StorageEventHandler storage,
        Supplier<Boolean> getter,
        Consumer<Boolean> setter,
        OptionFlag... flags
    ) {
        BooleanOptionBuilder opt = builder.createBooleanOption(id(path))
            .setName(Component.literal(name))
            .setTooltip(Component.literal(tooltip))
            .setDefaultValue(defaultVal)
            .setImpact(impact)
            .setStorageHandler(storage)
            .setBinding(setter, getter);
        if (flags.length > 0) {
            opt.setFlags(flags);
        }
        return opt;
    }

    private static <E extends Enum<E>> EnumOptionBuilder<E> enumOpt(
        ConfigBuilder builder,
        String path,
        String name,
        String tooltip,
        Class<E> type,
        E defaultVal,
        OptionImpact impact,
        StorageEventHandler storage,
        Supplier<E> getter,
        Consumer<E> setter,
        Function<E, Component> formatter,
        OptionFlag... flags
    ) {
        EnumOptionBuilder<E> opt = builder.createEnumOption(id(path), type)
            .setName(Component.literal(name))
            .setTooltip(Component.literal(tooltip))
            .setDefaultValue(defaultVal)
            .setImpact(impact)
            .setStorageHandler(storage)
            .setElementNameProvider(formatter)
            .setBinding(setter, getter);
        if (flags.length > 0) {
            opt.setFlags(flags);
        }
        return opt;
    }

    private static Component formatMetalMode(CelestiaConfig.MetalMode mode) {
        return Component.literal(switch (mode) {
            case AUTO_METAL_4 -> "Auto (Metal 4)";
            case METAL_4 -> "Metal 4";
            case METAL_3 -> "Metal 3";
        });
    }

    private static Component formatHudMode(CelestiaConfig.HudMode mode) {
        return Component.literal(switch (mode) {
            case OFF -> "Off";
            case COMPACT -> "Compact";
            case DETAILED -> "Detailed";
        });
    }

    private static Component formatUpscaler(CelestiaConfig.UpscalerMode mode) {
        return Component.literal(switch (mode) {
            case METALFX_TEMPORAL -> "MetalFX Temporal";
            case METALFX_SPATIAL -> "MetalFX Spatial";
            case BILINEAR -> "Bilinear";
            case TAAU -> "TAAU";
        });
    }

    private static Component formatThermalMode(CelestiaConfig.ThermalMode mode) {
        return Component.literal(switch (mode) {
            case OFF -> "Unthrottled";
            case BALANCED -> "Balanced";
            case BATTERY_SAVER -> "Battery Saver";
        });
    }
}
