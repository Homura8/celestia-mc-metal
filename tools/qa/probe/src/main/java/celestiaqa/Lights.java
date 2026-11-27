package celestiaqa;

import static celestiaqa.Qa.*;

import java.util.List;
import java.util.function.Consumer;
import net.minecraft.client.Minecraft;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Blocks;

/** Coloured block lights and dynamic light emitters in two rooms sealed against skylight. */
final class Lights {
    private static final BlockPos ROOMS_MIN = new BlockPos(988, 139, 984);
    private static final BlockPos ROOMS_MAX = new BlockPos(1032, 168, 1040);
    private static final Identifier WHITE_CONCRETE = Identifier.parse("minecraft:white_concrete");
    private static final String EMITTER = "celestiaqa_emitter";

    private Lights() {}

    static void add(List<Step> steps) {
        steps.add(once(mc -> {
            CelestiaHooks.presetWith("Balanced", null);
            CelestiaHooks.debugView(0);
            cmd(mc, "gamemode creative @a");
            cmd(mc, "time set 18000");
            cmd(mc, "weather clear");
            cmd(mc, "tp @a 1009.5 150 995.5 0 15");
        }));
        steps.add(mc -> {
            if (elapsed() >= 100 && roomChunksLoaded(mc)) return true;
            if (elapsed() >= 600) throw new IllegalStateException("Light-room chunks did not load");
            return false;
        });
        steps.add(once(Lights::buildRooms));
        steps.add(mc -> {
            var roof = mc.level.getBlockState(new BlockPos(1006, 168, 1034)).getBlock();
            if (mc.level.getBlockState(new BlockPos(994, 140, 1012)).is(Blocks.SOUL_LANTERN)
                && WHITE_CONCRETE.equals(BuiltInRegistries.BLOCK.getKey(roof))) return true;
            if (elapsed() >= 600) throw new IllegalStateException("Light rooms did not build");
            return false;
        });
        waitForLight(steps, 200);
        shot(steps, "colour-on", 10, mc -> CelestiaHooks.debugView(7));
        shot(steps, "colour-debug-raw", 10, mc -> CelestiaHooks.debugView(8));
        shot(steps, "colour-debug-add", 80, mc -> {
            CelestiaHooks.debugView(0);
            CelestiaHooks.options("COLORED_LIGHTS=false");
        });
        shot(steps, "colour-off", 160, mc -> CelestiaHooks.options("COLORED_LIGHTS=true,COLORED_LIGHT_GLOW=3.0"));
        shot(steps, "colour-glow3", 120, mc -> {
            CelestiaHooks.options("COLORED_LIGHT_GLOW=1.0");
            cmd(mc, "tp @a 994.5 141 1006.5 0 25");
        });
        shot(steps, "colour-soul-close", 120, mc -> cmd(mc, "tp @a 1018.5 141 1006.5 0 25"));
        shot(steps, "colour-sealantern-close", 120, mc -> cmd(mc, "tp @a 1000.5 141 1006.5 0 25"));
        shot(steps, "colour-redstone-close", 160, mc -> {
            cmd(mc, "tp @a 995.5 160 1018.5 0 10");
            cmd(mc, "item replace entity @a weapon.mainhand with minecraft:torch");
        });
        shot(steps, "dyn-hand-on", 100, mc -> CelestiaHooks.options("DYNAMIC_LIGHTS=false"));
        shot(steps, "dyn-hand-off", 160, mc -> {
            CelestiaHooks.options("DYNAMIC_LIGHTS=true");
            cmd(mc, "item replace entity @a weapon.mainhand with minecraft:air");
            // Peaceful removes blazes, even with PersistenceRequired.
            cmd(mc, "difficulty normal");
            cmd(mc, "summon minecraft:blaze 1006.5 160 1034.5 {NoAI:1b,Silent:1b,PersistenceRequired:1b,Tags:[\"" + EMITTER + "\"]}");
            cmd(mc, "summon minecraft:item 993.5 160 1030.5 {Item:{id:\"minecraft:glowstone\",count:1},PickupDelay:32767,Age:-32768,Tags:[\"" + EMITTER + "\"]}");
            cmd(mc, "tp @a 999.5 161 1018.5 0 15");
        });
        shot(steps, "dyn-blaze-glowstone", 100, mc -> CelestiaHooks.options("DYNAMIC_LIGHTS=false"));
        shot(steps, "dyn-blaze-glowstone-off", 100, mc -> CelestiaHooks.presetWith("Performance", null));
        shot(steps, "preset-performance", 120, mc -> CelestiaHooks.presetWith("Ultra", null));
        shot(steps, "preset-ultra", 100, mc -> {
            CelestiaHooks.presetWith("Balanced", null);
            cmd(mc, "kill @e[tag=" + EMITTER + "]");
            cmd(mc, "difficulty peaceful");
            cmd(mc, "tp @a 1009.5 141 995.5 0 12");
        });
        shot(steps, "ab-native", 10, mc -> CelestiaHooks.debugView(9));
        shot(steps, "ab-debug-blocklight", 10, mc -> CelestiaHooks.debugView(10));
        shot(steps, "ab-debug-vertexcolour", 100, mc -> {
            CelestiaHooks.debugView(0);
            CelestiaHooks.selectPack("off");
        });
        shot(steps, "ab-pack-off", 20, mc -> {
            cmd(mc, "gamemode spectator @a");
            configure();
        });
    }

    private static boolean roomChunksLoaded(Minecraft mc) {
        for (int x = ROOMS_MIN.getX() >> 4; x <= (ROOMS_MAX.getX() >> 4); x++) {
            for (int z = ROOMS_MIN.getZ() >> 4; z <= (ROOMS_MAX.getZ() >> 4); z++) {
                if (!mc.level.hasChunk(x, z)) return false;
            }
        }
        return true;
    }

    private static void buildRooms(Minecraft mc) {
        cmd(mc, "fill 988 139 984 1032 152 1014 minecraft:white_concrete hollow");
        for (int x : new int[] {997, 1003, 1009, 1015, 1021}) {
            cmd(mc, "fill " + x + " 140 1004 " + x + " 145 1013 minecraft:white_concrete");
        }
        String[] blocks = {"soul_lantern", "redstone_torch", "copper_torch", "amethyst_cluster", "sea_lantern", "torch"};
        for (int i = 0; i < blocks.length; i++) {
            cmd(mc, "setblock " + (994 + 6 * i) + " 140 1012 minecraft:" + blocks[i]);
        }
        cmd(mc, "fill 988 159 1016 1012 168 1040 minecraft:white_concrete hollow");
        cmd(mc, "fill 1001 160 1028 1011 166 1028 minecraft:white_concrete");
        cmd(mc, "tp @a 1009.5 141 995.5 0 12");
    }

    private static void shot(List<Step> steps, String name, int wait, Consumer<Minecraft> next) {
        steps.add(once(mc -> {
            double[] samples = finishSampling();
            double gpu = java.util.Arrays.stream(samples).average().orElse(-1);
            screenshot(mc, "lights-" + name);
            log(fmt("lights %s | fps %d | gpu avg %.2f ms | %s", name, mc.getFps(), gpu, CelestiaHooks.status()));
            next.accept(mc);
        }));
        waitForLight(steps, wait);
    }

    private static void waitForLight(List<Step> steps, int wait) {
        steps.add(once(mc -> startSampling()));
        steps.add(ticks(wait));
    }
}
