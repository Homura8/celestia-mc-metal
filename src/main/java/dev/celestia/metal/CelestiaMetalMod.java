package dev.celestia.metal;

import dev.celestia.metal.perf.CelestiaConfig;
import dev.celestia.metal.shader.pack.ShaderPipelineManager;
import net.fabricmc.api.ClientModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class CelestiaMetalMod implements ClientModInitializer {
    public static final String MOD_ID = "celestia-metal";
    public static final Logger LOGGER = LoggerFactory.getLogger("CelestiaMetal");

    @Override
    public void onInitializeClient() {
        CelestiaConfig.get();
        ShaderPipelineManager.get().refreshPacks();
        LOGGER.info("Celestia Metal initialized (Apple Silicon Metal 4 / Metal 3 engine)");
    }
}
