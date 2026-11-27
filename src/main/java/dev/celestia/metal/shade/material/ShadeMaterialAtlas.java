package dev.celestia.metal.shade.material;

import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.logging.LogUtils;
import com.mojang.renderpearl.api.textures.GpuTexture;
import dev.celestia.metal.backend.MetalConst;
import dev.celestia.metal.backend.MetalNative;
import dev.celestia.metal.mixin.TextureAtlasAccessor;
import dev.celestia.metal.shade.ShadeLook;
import java.io.IOException;
import java.io.InputStream;
import java.lang.foreign.MemorySegment;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Collection;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.client.resources.metadata.animation.AnimationMetadataSection;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;
import org.slf4j.Logger;

/** Linear labPBR companions laid out at the same sprite coordinates as the block atlas. */
public final class ShadeMaterialAtlas {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final int NORMAL_SLOT = 7, SPECULAR_SLOT = 8;

    private GpuTexture blockTexture;
    private long normal, specular;
    private boolean bindingChanged;

    public int prepare(long ctx, Minecraft mc, boolean enabled) {
        if (!enabled || !(mc.getTextureManager().getTexture(TextureAtlas.LOCATION_BLOCKS) instanceof TextureAtlas atlas)) {
            release(ctx);
            return 0;
        }
        GpuTexture texture = atlas.getTexture();
        if (texture != blockTexture) {
            release(ctx);
            blockTexture = texture;
            if (texture != null && !texture.isClosed()) {
                var sprites = ((TextureAtlasAccessor) atlas).celestia$regions().values();
                ResourceManager resources = mc.getResourceManager();
                normal = build(ctx, resources, sprites, texture, true);
                specular = build(ctx, resources, sprites, texture, false);
                bindingChanged = true;
            }
        }
        return (normal != 0 ? ShadeLook.FEATURE_PBR_NORMAL : 0)
            | (specular != 0 ? ShadeLook.FEATURE_PBR_SPECULAR : 0);
    }

    /** Call after publishing the current frame's argument buffer. */
    public void bind(long ctx) {
        if (!bindingChanged) return;
        MetalNative.shadeSetResource(ctx, NORMAL_SLOT, normal);
        MetalNative.shadeSetResource(ctx, SPECULAR_SLOT, specular);
        bindingChanged = false;
    }

    public void close(long ctx) {
        release(ctx);
        if (ctx != 0) bind(ctx);
    }

    private void release(long ctx) {
        blockTexture = null;
        if (normal != 0) MetalNative.textureDestroy(ctx, normal);
        if (specular != 0) MetalNative.textureDestroy(ctx, specular);
        bindingChanged |= normal != 0 || specular != 0;
        normal = specular = 0;
    }

    private static long build(long ctx, ResourceManager resources, Collection<TextureAtlasSprite> sprites,
                              GpuTexture blockAtlas, boolean normal) {
        int levels = blockAtlas.getMipLevels();
        long[] offsets = new long[levels + 1];
        for (int mip = 0; mip < levels; mip++) {
            offsets[mip + 1] = offsets[mip] + (long) blockAtlas.getWidth(mip) * blockAtlas.getHeight(mip) * 4;
        }
        String suffix = normal ? "_n.png" : "_s.png";
        String label = normal ? "CelestiaShade.LabPbrNormal" : "CelestiaShade.LabPbrSpecular";
        long staging = 0;
        int count = 0;
        try {
            ByteBuffer[] mips = new ByteBuffer[levels];
            for (TextureAtlasSprite sprite : sprites) {
                Identifier id = sprite.contents().name().withPath(path -> "textures/" + path + suffix);
                Resource resource = resources.getResource(id).orElse(null);
                if (resource == null) continue;
                int width = sprite.contents().width(), height = sprite.contents().height();
                int[] pixels;
                try {
                    pixels = readTile(resource, width, height);
                } catch (IOException | RuntimeException e) {
                    LOGGER.warn("Skipping labPBR texture {}: {}", id, e.getMessage());
                    continue;
                }
                if (staging == 0) {
                    staging = MetalNative.bufferCreate(ctx, offsets[levels], MemorySegment.NULL, label + ".Upload");
                    if (staging == 0) throw new IllegalStateException("Could not allocate texture staging");
                    long address = MetalNative.bufferContents(staging);
                    if (address == 0) throw new IllegalStateException("Texture staging is inaccessible");
                    MemorySegment data = MemorySegment.ofAddress(address).reinterpret(offsets[levels]);
                    data.fill((byte) 0);
                    for (int mip = 0; mip < levels; mip++) {
                        mips[mip] = data.asSlice(offsets[mip], offsets[mip + 1] - offsets[mip])
                            .asByteBuffer().order(ByteOrder.nativeOrder());
                    }
                }
                int padding = Math.round(sprite.getU0() * blockAtlas.getWidth(0)) - sprite.getX();
                for (int mip = 0; mip < levels; mip++) {
                    copyTile(mips[mip], blockAtlas.getWidth(mip), sprite.getX() >> mip, sprite.getY() >> mip,
                        padding >> mip, pixels, width, height);
                    if (mip + 1 < levels) {
                        pixels = nextMip(pixels, width, height, normal);
                        width = Math.max(1, width >> 1);
                        height = Math.max(1, height >> 1);
                    }
                }
                count++;
            }
            if (count == 0) return 0L;

            long texture = MetalNative.textureCreate(ctx, MetalConst.FMT_RGBA8_UNORM,
                blockAtlas.getWidth(0), blockAtlas.getHeight(0), 1, levels, false, false, true, false, label);
            if (texture == 0) throw new IllegalStateException("Could not allocate material atlas");
            try {
                for (int mip = 0; mip < levels; mip++) {
                    int width = blockAtlas.getWidth(mip), height = blockAtlas.getHeight(mip);
                    MetalNative.blitCopyBufferToTexture(ctx, staging, offsets[mip], width * 4,
                        texture, mip, 0, 0, 0, width, height);
                }
            } catch (RuntimeException e) {
                MetalNative.textureDestroy(ctx, texture);
                throw e;
            }
            LOGGER.info("Loaded {} labPBR {} maps into {}×{} atlas", count, normal ? "normal" : "specular",
                blockAtlas.getWidth(0), blockAtlas.getHeight(0));
            return texture;
        } catch (RuntimeException e) {
            LOGGER.warn("Could not build {}", label, e);
            return 0L;
        } finally {
            if (staging != 0) MetalNative.bufferDestroy(ctx, staging);
        }
    }

    private static int[] readTile(Resource resource, int width, int height) throws IOException {
        try (InputStream in = resource.open(); NativeImage image = NativeImage.read(in)) {
            int sourceWidth = image.getWidth(), sourceHeight = image.getHeight();
            int x = 0, y = 0;
            var metadata = resource.metadata().getSection(AnimationMetadataSection.TYPE);
            if (metadata.isPresent()) {
                AnimationMetadataSection animation = metadata.get();
                var size = animation.calculateFrameSize(sourceWidth, sourceHeight);
                int columns = sourceWidth / size.width(), rows = sourceHeight / size.height();
                if (columns == 0 || rows == 0) throw new IOException("Animation frame does not fit the image");
                int first = animation.frames().stream().flatMap(Collection::stream).mapToInt(frame -> frame.index())
                    .filter(index -> index >= 0 && index < columns * rows).findFirst().orElse(0);
                sourceWidth = size.width();
                sourceHeight = size.height();
                x = first % columns * sourceWidth;
                y = first / columns * sourceHeight;
            } else if ((long) sourceWidth * height != (long) sourceHeight * width) {
                // Companion frame strips often rely on the albedo's .mcmeta.
                long frameHeight = (long) sourceWidth * height / width;
                if (frameHeight < 1 || sourceHeight % frameHeight != 0) throw new IOException("Unexpected sprite aspect ratio");
                sourceHeight = (int) frameHeight;
            }
            if (sourceWidth == width && sourceHeight == height && x == 0 && y == 0 && sourceHeight == image.getHeight()) {
                return image.getPixelsABGR();
            }
            int[] pixels = new int[Math.multiplyExact(width, height)];
            ByteBuffer rgba = image.getPixelBytes().order(ByteOrder.nativeOrder());
            for (int dy = 0; dy < height; dy++) {
                int row = (y + dy * sourceHeight / height) * image.getWidth();
                for (int dx = 0; dx < width; dx++) {
                    pixels[dy * width + dx] = rgba.getInt(4 * (row + x + dx * sourceWidth / width));
                }
            }
            return pixels;
        }
    }

    static void copyTile(ByteBuffer atlas, int stride, int x, int y, int padding, int[] pixels, int w, int h) {
        for (int dy = -padding; dy < h + padding; dy++) {
            int src = Math.clamp(dy, 0, h - 1) * w;
            int dst = (y + padding + dy) * stride + x + padding;
            for (int dx = -padding; dx < w + padding; dx++) {
                atlas.putInt((dst + dx) * 4, pixels[src + Math.clamp(dx, 0, w - 1)]);
            }
        }
    }

    static int[] nextMip(int[] pixels, int width, int height, boolean normal) {
        int w = Math.max(1, width >> 1), h = Math.max(1, height >> 1);
        int[] mip = new int[w * h];
        for (int y = 0; y < h; y++) {
            int top = 2 * y * width, bottom = Math.min(2 * y + 1, height - 1) * width;
            for (int x = 0; x < w; x++) {
                int left = 2 * x, right = Math.min(left + 1, width - 1);
                mip[y * w + x] = reduce(pixels[top + left], pixels[top + right],
                    pixels[bottom + left], pixels[bottom + right], normal);
            }
        }
        return mip;
    }

    private static int reduce(int a, int b, int c, int d, boolean normal) {
        int r = average(a, b, c, d, 0);
        int g = average(a, b, c, d, 8);
        int bChannel = average(a, b, c, d, 16);
        int alpha = average(a, b, c, d, 24);
        if (!normal) {
            // Average continuous data and preserve the leading texel's material class at class boundaries.
            if (((a >>> 8) & 255) >= 230 || ((b >>> 8) & 255) >= 230 || ((c >>> 8) & 255) >= 230 || ((d >>> 8) & 255) >= 230) {
                g = (a >>> 8) & 255;
            }
            boolean scattering = isScattering(a);
            if (isScattering(b) != scattering || isScattering(c) != scattering || isScattering(d) != scattering) {
                bChannel = (a >>> 16) & 255;
            }
            alpha = (emission(a) + emission(b) + emission(c) + emission(d) + 2) >> 2;
        }
        return r | (g << 8) | (bChannel << 16) | (alpha << 24);
    }

    private static int average(int a, int b, int c, int d, int shift) {
        return (((a >>> shift) & 255) + ((b >>> shift) & 255) + ((c >>> shift) & 255) + ((d >>> shift) & 255) + 2) >> 2;
    }

    private static int emission(int pixel) {
        int alpha = pixel >>> 24;
        return alpha == 255 ? 0 : alpha;
    }

    private static boolean isScattering(int pixel) {
        return ((pixel >>> 16) & 255) > 64;
    }
}
