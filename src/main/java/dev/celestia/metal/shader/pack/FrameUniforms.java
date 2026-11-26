package dev.celestia.metal.shader.pack;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.joml.Vector4f;

/**
 * 256-byte aligned frame uniform block shared with {@code celestia_common.metal} ({@code CelestiaFrameUniforms}).
 * Every native MSL shader pack binds this at buffer slot 14.
 */
public final class FrameUniforms {
    public static final int BYTE_SIZE = 512;

    public final Matrix4f viewProj = new Matrix4f();
    public final Matrix4f invViewProj = new Matrix4f();
    public final Matrix4f prevViewProj = new Matrix4f();
    public final Matrix4f shadowViewProjNear = new Matrix4f();
    public final Matrix4f shadowViewProjFar = new Matrix4f();

    public final Vector4f cameraPosTime = new Vector4f();        // xyz world pos, w seconds
    public final Vector4f sunDirDaylight = new Vector4f(0.4f, 0.8f, 0.4f, 1.0f); // xyz towards sun/moon, w daylight 0..1
    public final Vector4f weatherState = new Vector4f();         // x twilight, y rain, z thunder, w fogMode
    public final Vector4f skyColorFrame = new Vector4f(0.48f, 0.67f, 0.98f, 0.0f);
    public final Vector4f fogColorElevation = new Vector4f(0.65f, 0.77f, 0.94f, 0.5f);
    public final Vector4f fogRanges = new Vector4f(64.0f, 192.0f, 160.0f, 256.0f);
    public final Vector4f resolutionParams = new Vector4f(1920.0f, 1080.0f, 1.0f, 1.0f); // xy res, z hdrPeak, w edrHeadroom
    public final Vector4f qualityFlags = new Vector4f(1.0f, 0.0f, 0.0f, 0.0f); // x dynamicLightPower, y gamma, z nightVision, w underwater

    public void pack(ByteBuffer buf) {
        buf.order(ByteOrder.LITTLE_ENDIAN);
        int start = buf.position();
        putMat4(buf, viewProj);          // +0   (64)
        putMat4(buf, invViewProj);       // +64  (64)
        putMat4(buf, prevViewProj);      // +128 (64)
        putMat4(buf, shadowViewProjNear);// +192 (64)
        putMat4(buf, shadowViewProjFar); // +256 (64)
        putVec4(buf, cameraPosTime);     // +320 (16)
        putVec4(buf, sunDirDaylight);    // +336 (16)
        putVec4(buf, weatherState);      // +352 (16)
        putVec4(buf, skyColorFrame);     // +368 (16)
        putVec4(buf, fogColorElevation); // +384 (16)
        putVec4(buf, fogRanges);         // +400 (16)
        putVec4(buf, resolutionParams);  // +416 (16)
        putVec4(buf, qualityFlags);      // +432 (16) -> 448 bytes used, pad to 512
        while (buf.position() - start < BYTE_SIZE) {
            buf.putFloat(0.0f);
        }
    }

    private static void putMat4(ByteBuffer buf, Matrix4f m) {
        buf.putFloat(m.m00()).putFloat(m.m01()).putFloat(m.m02()).putFloat(m.m03());
        buf.putFloat(m.m10()).putFloat(m.m11()).putFloat(m.m12()).putFloat(m.m13());
        buf.putFloat(m.m20()).putFloat(m.m21()).putFloat(m.m22()).putFloat(m.m23());
        buf.putFloat(m.m30()).putFloat(m.m31()).putFloat(m.m32()).putFloat(m.m33());
    }

    private static void putVec4(ByteBuffer buf, Vector4f v) {
        buf.putFloat(v.x()).putFloat(v.y()).putFloat(v.z()).putFloat(v.w());
    }
}
