// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - InstallCommandRunner

/// Executes `deepfinder install` and `deepfinder uninstall` commands.
///
/// Manages the LaunchAgent plist for auto-starting the daemon on login.
/// Delegates file operations to `LaunchAgent`.
public struct InstallCommandRunner {

    // MARK: - install

    /// Install the LaunchAgent plist and create the default configuration file.
    ///
    /// Checks if already installed. If not, generates the plist, writes it
    /// to the specified path, and creates a default `settings.json` if one
    /// does not already exist.
    ///
    /// - Parameters:
    ///   - plistPath: File system path for the plist. Defaults to `LaunchAgent.defaultPlistPath`.
    ///   - configPath: File system path for the config file. Defaults to `~/.deep-finder/settings.json`.
    ///   - output: Output writer for display. Defaults to `StdoutWriter`.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func install(
        plistPath: String = LaunchAgent.defaultPlistPath,
        configPath: String = Product.dataDir + "/settings.json",
        output: any CLIOutputWriter = StdoutWriter()
    ) throws -> Int32 {
        let resolvedPath = NSString(string: plistPath).expandingTildeInPath
        let resolvedConfigPath = NSString(string: configPath).expandingTildeInPath

        // Check if already installed
        if FileManager.default.fileExists(atPath: resolvedPath) {
            output.write("Already installed. Run `deepfinder uninstall` first to reinstall.\n")
            return 1
        }

        do {
            try LaunchAgent.installPlist(at: resolvedPath)
        } catch {
            output.writeError("Error: \(error.localizedDescription)\n")
            return 1
        }

        // Create default configuration file if it doesn't exist
        if !FileManager.default.fileExists(atPath: resolvedConfigPath) {
            let configDir = (resolvedConfigPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(DaemonConfig.defaults) {
                try? data.write(to: URL(fileURLWithPath: resolvedConfigPath), options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Product.privateFilePermissions)],
                    ofItemAtPath: resolvedConfigPath
                )
            }
        }

        output.write("LaunchAgent installed at \(resolvedPath)\n")
        if FileManager.default.fileExists(atPath: resolvedConfigPath) {
            output.write("Configuration: \(resolvedConfigPath)\n")
        }
        output.write("The daemon will start automatically on login.\n")
        return 0
    }

    // MARK: - uninstall

    /// Remove the LaunchAgent plist.
    ///
    /// Checks if the plist exists. If so, removes it.
    ///
    /// - Parameters:
    ///   - plistPath: File system path for the plist. Defaults to `LaunchAgent.defaultPlistPath`.
    ///   - output: Output writer for display. Defaults to `StdoutWriter`.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func uninstall(
        plistPath: String = LaunchAgent.defaultPlistPath,
        output: any CLIOutputWriter = StdoutWriter()
    ) throws -> Int32 {
        let resolvedPath = NSString(string: plistPath).expandingTildeInPath

        // Check if not installed
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            output.write("Not installed.\n")
            return 1
        }

        do {
            try LaunchAgent.uninstallPlist(at: resolvedPath)
        } catch {
            output.writeError("Error: \(error.localizedDescription)\n")
            return 1
        }

        output.write("LaunchAgent removed from \(resolvedPath)\n")
        return 0
    }
}
