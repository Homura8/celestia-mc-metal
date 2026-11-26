package dev.celestia.metal;

import javax.swing.JOptionPane;

/**
 * Displayed if a user double-clicks the mod JAR directly instead of placing it in Fabric's mods/ folder.
 */
public final class InstallHelp {
    private InstallHelp() {}

    public static void main(String[] args) {
        String msg = """
            Celestia Metal is a Fabric mod for Minecraft: Java Edition 26.3 on Apple Silicon Macs.

            To install:
            1. Install Fabric Loader 0.19.5+ for Minecraft 26.3.
            2. Place this JAR into your Minecraft instance's 'mods/' folder.
            3. Launch Minecraft on Apple Silicon (macOS 15+ / macOS 26+ for Metal 4).
            """;
        System.out.println(msg);
        try {
            JOptionPane.showMessageDialog(null, msg, "Celestia Metal", JOptionPane.INFORMATION_MESSAGE);
        } catch (Throwable ignored) {
        }
    }
}
