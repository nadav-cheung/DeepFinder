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

    /// Install the LaunchAgent plist.
    ///
    /// Checks if already installed. If not, generates the plist and writes it
    /// to the specified path.
    ///
    /// - Parameters:
    ///   - plistPath: File system path for the plist. Defaults to `LaunchAgent.defaultPlistPath`.
    ///   - output: Output writer for display. Defaults to `StdoutWriter`.
    /// - Returns: Exit code (0 = success, non-zero = error).
    public static func install(
        plistPath: String = LaunchAgent.defaultPlistPath,
        output: any CLIOutputWriter = StdoutWriter()
    ) throws -> Int32 {
        let resolvedPath = NSString(string: plistPath).expandingTildeInPath

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

        output.write("LaunchAgent installed at \(resolvedPath)\n")
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
