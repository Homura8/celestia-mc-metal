package dev.celestia.metal.backend;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import net.minecraft.client.PreferredGraphicsApi;

/**
 * Isolates startup crash recovery so a crash unrelated to Celestia Metal does not permanently lock
 * the user onto OpenGL, while a genuine crash during Metal startup still falls back safely.
 *
 * Inspired by Pure Metal's StartupGuard (Apache-2.0).
 */
public final class StartupGuard {
    private static final String MARKER_NAME = "celestia-metal-startup.lock";
    private static volatile boolean activeMetalAttempt;
    private static volatile boolean startupComplete;
    private static volatile boolean recoveredFromMetalCrash;

    private StartupGuard() {}

    public static boolean begin(PreferredGraphicsApi configuredApi, Path gameDir) {
        if (startupComplete) return false;
        Path marker = markerPath(gameDir);
        if (configuredApi == PreferredGraphicsApi.OPENGL && Files.exists(marker)) {
            // Previous attempt crashed while Metal was initializing: honor fallback once and clear lock.
            recoveredFromMetalCrash = true;
            clearMarker(marker);
            return false;
        }
        if (configuredApi == PreferredGraphicsApi.DEFAULT) {
            activeMetalAttempt = true;
            writeMarker(marker);
            return false;
        }
        return false;
    }

    public static void markStartupSuccess(Path gameDir) {
        startupComplete = true;
        activeMetalAttempt = false;
        clearMarker(markerPath(gameDir));
    }

    public static boolean didRecoverFromMetalCrash() {
        return recoveredFromMetalCrash;
    }

    public static boolean isAttemptingMetal() {
        return activeMetalAttempt;
    }

    private static Path markerPath(Path gameDir) {
        Path dir = gameDir != null ? gameDir.resolve("config") : Path.of("config");
        return dir.resolve(MARKER_NAME);
    }

    private static void writeMarker(Path marker) {
        try {
            Files.createDirectories(marker.getParent());
            Files.writeString(marker, Long.toString(System.currentTimeMillis()));
        } catch (IOException ignored) {}
    }

    private static void clearMarker(Path marker) {
        try {
            Files.deleteIfExists(marker);
        } catch (IOException ignored) {}
    }
}
