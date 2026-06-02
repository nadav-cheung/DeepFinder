import Foundation

// MARK: - LaunchAgentError

/// Errors thrown by ``LaunchAgent`` during plist management.
enum LaunchAgentError: Error, CustomStringConvertible, Equatable {
    /// The LaunchAgent plist could not be written to disk.
    case plistWriteFailed(String)
    /// The LaunchAgent plist exists but could not be removed.
    case plistRemoveFailed(String)
    /// No LaunchAgent plist was found at the expected path.
    case plistNotFound(String)

    var description: String {
        switch self {
        case .plistWriteFailed(let path):
            return "Failed to write LaunchAgent plist to: \(path)"
        case .plistRemoveFailed(let path):
            return "Failed to remove LaunchAgent plist at: \(path)"
        case .plistNotFound(let path):
            return "LaunchAgent plist not found at: \(path)"
        }
    }
}

// MARK: - LaunchAgent

/// Manages the macOS LaunchAgent plist for auto-starting the DeepFinder daemon.
///
/// The LaunchAgent plist is installed at:
/// `~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`
///
/// Installation is typically done via `deepfinder install` (v0.7).
/// The daemon can also be auto-spawned by the CLI without a LaunchAgent.
///
/// **Platform note**: LaunchAgents are macOS-specific (launchd). The plist uses
/// `RunAtLoad` to start on login and `KeepAlive` to restart on crash. Per-user
/// agents run in the user's security session, which is required for Full Disk Access.
enum LaunchAgent {

    // MARK: - Properties

    /// The LaunchAgent label (matches the bundle identifier).
    static let label = "\(Product.identifier).daemon"

    /// Default install path for the plist.
    static var defaultPlistPath: String {
        let home = NSString(string: "~").expandingTildeInPath
        return "\(home)/Library/LaunchAgents/\(label).plist"
    }

    // MARK: - Plist Generation

    /// Generate the LaunchAgent plist XML content.
    ///
    /// The plist configures:
    /// - Label: `com.nadav.deepfinder.daemon`
    /// - Program: full path to the `deepfinder-daemon` binary
    /// - Arguments: (none)
    /// - RunAtLoad: `true` (start on login)
    /// - KeepAlive: `true` (restart on crash)
    /// - StandardOutPath / StandardErrorPath: log files in `~/.deep-finder/logs/`
    ///
    /// - Returns: A complete XML plist string.
    static func generatePlist() -> String {
        let binaryPath = "/usr/local/bin/\(Product.daemonCommand)"
        let logOut = "\(Product.logsDir)/daemon-stdout.log"
        let logErr = "\(Product.logsDir)/daemon-stderr.log"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
            </array>
            <key>Program</key>
            <string>\(binaryPath)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(NSString(string: logOut).expandingTildeInPath)</string>
            <key>StandardErrorPath</key>
            <string>\(NSString(string: logErr).expandingTildeInPath)</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Install / Uninstall

    /// Install the LaunchAgent plist to the given path.
    ///
    /// Creates parent directories if needed. Writes the plist atomically.
    ///
    /// - Parameter path: File system path to write the plist.
    ///   Defaults to `~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`.
    /// - Throws: `LaunchAgentError.plistWriteFailed` if the file cannot be written.
    static func installPlist(at path: String = defaultPlistPath) throws {
        let plistContent = generatePlist()

        guard let data = plistContent.data(using: .utf8) else {
            throw LaunchAgentError.plistWriteFailed(path)
        }

        // Ensure parent directory exists
        let parentDir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw LaunchAgentError.plistWriteFailed(path)
        }
    }

    /// Remove the LaunchAgent plist from the given path.
    ///
    /// - Parameter path: File system path of the plist to remove.
    ///   Defaults to `~/Library/LaunchAgents/com.nadav.deepfinder.daemon.plist`.
    /// - Throws: `LaunchAgentError.plistRemoveFailed` if the file exists but cannot be removed.
    /// - Throws: `LaunchAgentError.plistNotFound` if the file does not exist.
    static func uninstallPlist(at path: String = defaultPlistPath) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw LaunchAgentError.plistNotFound(path)
        }

        do {
            try fm.removeItem(atPath: path)
        } catch {
            throw LaunchAgentError.plistRemoveFailed(path)
        }
    }
}
