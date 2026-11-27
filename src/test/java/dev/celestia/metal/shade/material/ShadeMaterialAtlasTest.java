package dev.celestia.metal.shade.material;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.jupiter.api.Test;

class ShadeMaterialAtlasTest {
    @Test
    void mirrorsSpriteOriginAndPadsEdges() {
        ByteBuffer atlas = ByteBuffer.allocate(7 * 6 * 4).order(ByteOrder.nativeOrder());
        ShadeMaterialAtlas.copyTile(atlas, 7, 2, 1, 1, new int[] {11, 12, 21, 22}, 2, 2);
        int[] actual = new int[7 * 6];
        atlas.asIntBuffer().get(actual);
        assertArrayEquals(new int[] {
            0, 0, 0, 0, 0, 0, 0,
            0, 0, 11, 11, 12, 12, 0,
            0, 0, 11, 11, 12, 12, 0,
            0, 0, 21, 21, 22, 22, 0,
            0, 0, 21, 21, 22, 22, 0,
            0, 0, 0, 0, 0, 0, 0
        }, actual);
    }

    @Test
    void preservesSpecularClassesAndTreatsEmission255AsZero() {
        int[] pixels = {rgba(20, 230, 64, 255), rgba(40, 229, 65, 255), rgba(60, 0, 255, 254), rgba(80, 0, 128, 0)};
        assertEquals(rgba(50, 230, 64, 64), ShadeMaterialAtlas.nextMip(pixels, 2, 2, false)[0]);
        assertEquals(rgba(50, 115, 128, 191), ShadeMaterialAtlas.nextMip(pixels, 2, 2, true)[0]);
    }

    private static int rgba(int r, int g, int b, int a) {
        return r | (g << 8) | (b << 16) | (a << 24);
    }
}
