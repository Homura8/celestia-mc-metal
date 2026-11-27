package dev.celestia.metal.shade.atmosphere;

import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import java.awt.image.BufferedImage;
import java.awt.image.Raster;
import java.io.IOException;
import java.io.InputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import javax.imageio.ImageIO;

/**
 * The volumetric clouds' noise textures (Photon Shaders' MIT-licensed assets, commit 26c2906e: see
 * {@code assets/celestiametal/textures/clouds/README.md} and {@code LICENSES/MIT-Photon.txt}).
 *
 * <p>The two volumes are packed into tiled 2D atlases (one slice per tile, a one-texel wrap gutter around each) so the shader
 * reads them with two bilinear taps and wraps on its own; {@code clouds.metal} {@code cloudVolume} undoes the layout:
 * <ul>
 *   <li>Worley 64³ R8: 8×8 tiles of 66² = 528×528 R8.</li>
 *   <li>Curl 32³ RGB8: 8×4 tiles of 34² = 272×136 RGBA8 (alpha unused).</li>
 *   <li>2D noise 512² RGBA8: as is (sampled with wrap). Its alpha is data, so the raster's raw samples are read.</li>
 * </ul>
 */
public final class ShadeCloudNoise {
    static final String DIR = "/assets/celestiametal/textures/clouds/";
    public static final int WORLEY = 64, WORLEY_TILE = WORLEY + 2, WORLEY_COLS = 8, WORLEY_ROWS = 8;
    public static final int CURL = 32, CURL_TILE = CURL + 2, CURL_COLS = 8, CURL_ROWS = 4;
    public static final int NOISE_2D = 512;

    long noise2d, worley, curl;

    private ShadeCloudNoise() {}

    /** Loads and uploads the three textures; returns null (after freeing what it made) if any step fails. */
    static ShadeCloudNoise create(long ctx) throws IOException {
        ShadeCloudNoise n = new ShadeCloudNoise();
        try (Arena arena = Arena.ofConfined()) {
            byte[] w = read("photon_worley.dat", WORLEY * WORLEY * WORLEY);
            byte[] c = read("photon_curl.dat", CURL * CURL * CURL * 3);
            byte[] p = rgba(readPng("photon_noise.png"), NOISE_2D);
            n.worley = upload(ctx, arena, MetalConst.FMT_R8_UNORM, atlas(w, WORLEY, 1, 1, WORLEY_COLS, WORLEY_ROWS),
                WORLEY_TILE * WORLEY_COLS, WORLEY_TILE * WORLEY_ROWS, 1, "CelestiaClouds.Worley");
            n.curl = upload(ctx, arena, MetalConst.FMT_RGBA8_UNORM, atlas(c, CURL, 3, 4, CURL_COLS, CURL_ROWS),
                CURL_TILE * CURL_COLS, CURL_TILE * CURL_ROWS, 4, "CelestiaClouds.Curl");
            n.noise2d = upload(ctx, arena, MetalConst.FMT_RGBA8_UNORM, p, NOISE_2D, NOISE_2D, 4, "CelestiaClouds.Noise2D");
        }
        if (n.worley == 0L || n.curl == 0L || n.noise2d == 0L) {
            n.close(ctx);
            return null;
        }
        return n;
    }

    /**
     * Packs an n³ volume (x fastest, then y, then z; {@code inC} channels per voxel) into a cols×rows grid of (n+2)² tiles, slice z
     * at tile (z % cols, z / cols). Each tile's border repeats the opposite edge (wrap), so bilinear taps inside a tile need no
     * clamping. {@code outC} channels per texel (extra ones are 255).
     */
    static byte[] atlas(byte[] vol, int n, int inC, int outC, int cols, int rows) {
        int tile = n + 2, aw = tile * cols, ah = tile * rows;
        byte[] out = new byte[aw * ah * outC];
        for (int z = 0; z < n; z++) {
            int ox = (z % cols) * tile, oy = (z / cols) * tile;
            for (int ty = 0; ty < tile; ty++) {
                int y = Math.floorMod(ty - 1, n);
                for (int tx = 0; tx < tile; tx++) {
                    int x = Math.floorMod(tx - 1, n);
                    int src = ((z * n + y) * n + x) * inC, dst = ((oy + ty) * aw + ox + tx) * outC;
                    for (int ch = 0; ch < outC; ch++) out[dst + ch] = ch < inC ? vol[src + ch] : (byte) 0xFF;
                }
            }
        }
        return out;
    }

    /** (tests) {@link #atlas}. */
    public static byte[] atlasForTest(byte[] vol, int n, int inC, int outC, int cols, int rows) {
        return atlas(vol, n, inC, outC, cols, rows);
    }

    /** (tests) {@link #rgba} of a 512² image. */
    public static byte[] rgbaForTest(BufferedImage img) throws IOException {
        return rgba(img, NOISE_2D);
    }

    private static long upload(long ctx, Arena arena, int fmt, byte[] data, int w, int h, int bpp, String label) {
        long tex = MetalNative.textureCreate(ctx, fmt, w, h, 1, 1, false, false, true, false, label);
        if (tex == 0L) return 0L;
        MemorySegment seg = arena.allocate(data.length);
        MemorySegment.copy(data, 0, seg, ValueLayout.JAVA_BYTE, 0, data.length);
        MetalNative.blitWriteTexture(ctx, tex, seg, data.length, w * bpp, 0, 0, 0, 0, w, h);
        return tex;
    }

    private static byte[] read(String name, int expected) throws IOException {
        try (InputStream in = ShadeCloudNoise.class.getResourceAsStream(DIR + name)) {
            if (in == null) throw new IOException("missing " + DIR + name);
            byte[] b = in.readAllBytes();
            if (b.length != expected) throw new IOException(name + ": " + b.length + " bytes, expected " + expected);
            return b;
        }
    }

    private static BufferedImage readPng(String name) throws IOException {
        try (InputStream in = ShadeCloudNoise.class.getResourceAsStream(DIR + name)) {
            if (in == null) throw new IOException("missing " + DIR + name);
            BufferedImage img = ImageIO.read(in);
            if (img == null) throw new IOException(name + ": not a readable image");
            return img;
        }
    }

    /** The image's raw RGBA samples (straight, not premultiplied: the alpha channel carries noise, not coverage). */
    static byte[] rgba(BufferedImage img, int size) throws IOException {
        if (img.getWidth() != size || img.getHeight() != size) throw new IOException("noise image is not " + size + "²");
        Raster r = img.getRaster();
        int bands = r.getNumBands();
        if (bands < 4) throw new IOException("noise image has " + bands + " channels, expected RGBA");
        int[] px = r.getPixels(0, 0, size, size, (int[]) null);
        byte[] out = new byte[size * size * 4];
        for (int i = 0, j = 0; i < size * size; i++, j += bands) {
            for (int ch = 0; ch < 4; ch++) out[i * 4 + ch] = (byte) px[j + ch];
        }
        return out;
    }

    void close(long ctx) {
        if (noise2d != 0L) MetalNative.textureDestroy(ctx, noise2d);
        if (worley != 0L) MetalNative.textureDestroy(ctx, worley);
        if (curl != 0L) MetalNative.textureDestroy(ctx, curl);
        noise2d = worley = curl = 0L;
    }
}
