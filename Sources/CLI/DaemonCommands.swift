// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderServices

// MARK: - Abstraction Protocols

/// Abstraction for spawning a daemon process. Testable via MockProcessSpawner.
public protocol ProcessSpawner: Sendable {
    func spawnDaemon(binaryPath: String, arguments: [String]) -> Result<Void, Error>
}

/// Abstraction for sending signals to processes and checking liveness.
public protocol ProcessSignaler: Sendable {
    /// Send SIGTERM to the given PID. Returns true if the signal was sent successfully.
    func sendSIGTERM(to pid: Int32) -> Bool
    /// Check whether the process with the given PID is still alive.
    func isProcessAlive(_ pid: Int32) -> Bool
}

/// Abstraction for waiting until the daemon's IPC socket is available.
public protocol SocketWaiter: Sendable {
    /// Poll until the socket file exists and is connectable, or timeout elapses.
    /// Returns true if the socket became available within the timeout.
    func waitForSocket(at path: String, timeout: TimeInterval) -> Bool
}

/// Abstraction for reading PID files and removing them.
public protocol PIDReader: Sendable {
    /// Read the PID from the file at the given path. Returns nil if the file
    /// does not exist or is corrupted.
    func readPID(from path: String) -> Int32?
    /// Remove the PID file at the given path.
    func removePIDFile(at path: String)
}

// MARK: - DaemonSubcommand

/// Subcommands for managing the DeepFinder daemon.
///
/// Usage: `deepfinder daemon start|stop|restart|status|rebuild|rescan`
public enum DaemonSubcommand: String, Sendable, Equatable {
    case start
    case stop
    case restart
    case status
    case rebuild
    case rescan
}

// MARK: - DaemonCommandRunnerError

private enum DaemonCommandRunnerError: Error, CustomStringConvertible {
    case spawnFailed(String)
    case startupTimedOut
    case daemonNotRunning
    case stopTimedOut

    public var description: String {
        switch self {
        case .spawnFailed(let reason):
            return "Failed to start daemon: \(reason)"
        case .startupTimedOut:
            return "Daemon did not become ready within the expected timeout"
        case .daemonNotRunning:
            return "Daemon is not running"
        case .stopTimedOut:
            return "Daemon did not stop within 5 seconds. Try: kill -9 <PID>"
        }
    }
}

// MARK: - DaemonCommandRunner

/// Executes daemon subcommands (start, stop, restart, status).
///
/// Designed for testability: process spawning, signal sending, socket waiting,
/// PID file access, and output are all injected via protocols. Production uses
/// the default concrete implementations; tests inject mocks.
public struct DaemonCommandRunner: Sendable {

    /// Paths and binary location.
    public let pidPath: String
    public let socketPath: String
    public let daemonBinaryPath: String

    /// Injectable dependencies.
    public let processSpawner: any ProcessSpawner
    public let processSignaler: any ProcessSignaler
    public let socketWaiter: any SocketWaiter
    public let pidReader: any PIDReader
    public let output: any CLIOutputWriter

    /// How long to wait for the daemon socket to become available after spawn.
    public let startupTimeout: TimeInterval

    /// How long to wait for the daemon to exit after SIGTERM.
    public let shutdownTimeout: TimeInterval

    /// Poll interval for checking process liveness during stop.
    public let shutdownPollInterval: TimeInterval

    // MARK: - Init

    public init(
        pidPath: String = Product.pidPath,
        socketPath: String = Product.socketPath,
        daemonBinaryPath: String = Product.daemonCommand,
        processSpawner: any ProcessSpawner = SystemProcessSpawner(),
        processSignaler: any ProcessSignaler = SystemProcessSignaler(),
        socketWaiter: any SocketWaiter = SystemSocketWaiter(),
        pidReader: any PIDReader = SystemPIDReader(),
        output: any CLIOutputWriter = StdoutWriter(),
        startupTimeout: TimeInterval = Constants.Daemon.startupTimeout,
        shutdownTimeout: TimeInterval = Constants.Daemon.shutdownTimeout,
        shutdownPollInterval: TimeInterval = Constants.Daemon.shutdownPollInterval
    ) {
        self.pidPath = DaemonCommandRunner.expandTilde(pidPath)
        self.socketPath = DaemonCommandRunner.expandTilde(socketPath)
        self.daemonBinaryPath = daemonBinaryPath
        self.processSpawner = processSpawner
        self.processSignaler = processSignaler
        self.socketWaiter = socketWaiter
        self.pidReader = pidReader
        self.output = output
        self.startupTimeout = startupTimeout
        self.shutdownTimeout = shutdownTimeout
        self.shutdownPollInterval = shutdownPollInterval
    }

    // MARK: - Public API

    /// Run a daemon subcommand.
    ///
    /// - Parameters:
    ///   - subcommand: The daemon operation to perform.
    ///   - client: IPC client for communicating with the daemon (used by status).
    /// - Returns: Exit code (0 = success, 1 = error).
    public func run(_ subcommand: DaemonSubcommand, client: any IPCClientProtocol) async -> Int32 {
        switch subcommand {
        case .start:
            return await doStart(client: client)
        case .stop:
            return await doStop()
        case .restart:
            return await doRestart(client: client)
        case .status:
            return await doStatus(client: client)
        case .rebuild:
            return await doRebuild(client: client)
        case .rescan:
            return await doRescan(client: client)
        }
    }

    // MARK: - Start

    /// Start the daemon. If already running, reports the PID. Otherwise spawns
    /// the process and waits for the IPC socket to become available.
    private func doStart(client: any IPCClientProtocol) async -> Int32 {
        // Check if already running
        if let pid = pidReader.readPID(from: pidPath), processSignaler.isProcessAlive(pid) {
            output.write("Daemon already running (PID \(pid))\n")
            return 0
        }

        // Clean up stale PID/socket if present
        pidReader.removePIDFile(at: pidPath)
        cleanupSocket()

        // Spawn daemon
        let result = processSpawner.spawnDaemon(
            binaryPath: daemonBinaryPath,
            arguments: ["--daemon"]
        )
        switch result {
        case .success:
            break
        case .failure(let error):
            output.writeError("Error: \(DaemonCommandRunnerError.spawnFailed(error.localizedDescription))\n")
            return 2
        }

        // Wait for socket
        let ready = socketWaiter.waitForSocket(at: socketPath, timeout: startupTimeout)
        if !ready {
            output.writeError("Error: \(DaemonCommandRunnerError.startupTimedOut)\n")
            return 2
        }

        output.write("Daemon started\n")
        return 0
    }

    // MARK: - Stop

    /// Stop the daemon by sending SIGTERM and polling until exit or timeout.
    private func doStop() async -> Int32 {
        guard let pid = pidReader.readPID(from: pidPath) else {
            output.write("Daemon is not running\n")
            return 2
        }

        guard processSignaler.isProcessAlive(pid) else {
            // Stale PID file
            pidReader.removePIDFile(at: pidPath)
            cleanupSocket()
            output.write("Daemon is not running (cleaned up stale PID file)\n")
            return 2
        }

        // Send SIGTERM
        guard processSignaler.sendSIGTERM(to: pid) else {
            output.writeError("Error: failed to send SIGTERM to PID \(pid)\n")
            return 2
        }

        // Poll until process exits or timeout
        let deadline = Date().addingTimeInterval(shutdownTimeout)
        var exited = false
        while Date() < deadline {
            if !processSignaler.isProcessAlive(pid) {
                exited = true
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(shutdownPollInterval * 1_000_000_000))
        }

        if !exited {
            output.writeError("Error: \(DaemonCommandRunnerError.stopTimedOut)\n")
            return 2
        }

        // Cleanup
        pidReader.removePIDFile(at: pidPath)
        cleanupSocket()
        output.write("Daemon stopped\n")
        return 0
    }

    // MARK: - Restart

    /// Restart the daemon: stop (if running) then start.
    private func doRestart(client: any IPCClientProtocol) async -> Int32 {
        // Stop if running
        _ = await doStop()
        // stop returns 1 for "not running" which is fine during restart

        // Start
        return await doStart(client: client)
    }

    // MARK: - Status

    /// Print daemon status: PID, uptime, index state, file count, and memory usage.
    private func doStatus(client: any IPCClientProtocol) async -> Int32 {
        guard let pid = pidReader.readPID(from: pidPath) else {
            output.write("Daemon is not running\n")
            return 2
        }

        guard processSignaler.isProcessAlive(pid) else {
            output.write("Daemon is not running (stale PID file)\n")
            return 2
        }

        // Fetch stats via IPC
        let response: IPCResponse
        do {
            response = try await client.send(.stats)
        } catch {
            // Daemon PID exists but IPC failed
            output.writeError("Daemon running (PID \(pid)) but not reachable via IPC\n")
            output.writeError("  Error: \(error.localizedDescription)\n")
            return 2
        }

        switch response {
        case .stats(let stats):
            let uptime = formatUptime(stats.uptimeSeconds)
            output.write("Daemon running (PID \(pid))\n")
            output.write("  Uptime: \(uptime)\n")
            output.write("  Index state: \(stats.indexState)\n")

            // Progress: when estimatedTotalFiles is known and scan is ongoing,
            // show percentage + ETA. Otherwise just the raw count.
            if let estimated = stats.estimatedTotalFiles, estimated > 0 {
                let pct = min(100, stats.totalFiles * 100 / estimated)
                let filesStr = Self.formatNumber(stats.totalFiles)
                let estStr = Self.formatNumber(estimated)
                output.write("  Files indexed: \(filesStr) / \(estStr) (\(pct)%)\n")

                if stats.totalFiles < estimated && stats.uptimeSeconds > 0 {
                    let rate = Double(stats.totalFiles) / max(stats.uptimeSeconds, 1)
                    if rate > 0 {
                        let remaining = Double(estimated - stats.totalFiles) / rate
                        output.write("  Scan ETA: ~\(formatDuration(remaining))\n")
                    }
                }
            } else {
                output.write("  Files indexed: \(Self.formatNumber(stats.totalFiles))\n")
            }
            output.write("  Memory: \(String(format: "%.1f", stats.memoryUsageMB)) MB\n")
            return 0

        case .error(let ipcError):
            output.writeError("Daemon running (PID \(pid)) but returned error: \(ipcError)\n")
            return 2

        default:
            output.writeError("Daemon running (PID \(pid)) but returned unexpected response\n")
            return 2
        }
    }

    // MARK: - Rebuild

    /// Rebuild the index from scratch: stop daemon, delete index cache, restart.
    private func doRebuild(client: any IPCClientProtocol) async -> Int32 {
        output.write("Rebuilding index from scratch...\n")

        // 1. Stop daemon if running
        if let pid = pidReader.readPID(from: pidPath), processSignaler.isProcessAlive(pid) {
            output.write("Stopping daemon (PID \(pid))...\n")
            _ = processSignaler.sendSIGTERM(to: pid)
            let deadline = Date().addingTimeInterval(shutdownTimeout)
            var exited = false
            while Date() < deadline {
                if !processSignaler.isProcessAlive(pid) { exited = true; break }
                try? await Task.sleep(nanoseconds: UInt64(shutdownPollInterval * 1_000_000_000))
            }
            if !exited {
                output.writeError("Error: daemon did not stop in time\n")
                return 2
            }
            pidReader.removePIDFile(at: pidPath)
            cleanupSocket()
        }

        // 2. Delete index cache
        let cacheDir = (pidPath as NSString).deletingLastPathComponent + "/../cache"
        let resolvedCacheDir = NSString(string: cacheDir).expandingTildeInPath
        let indexPath = resolvedCacheDir + "/index.db"
        for suffix in ["", "-wal", "-shm"] {
            let path = indexPath + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        output.write("Index cache cleared.\n")

        // 3. Start daemon (will rebuild from scratch)
        return await doStart(client: client)
    }

    // MARK: - Rescan

    /// Trigger a rescan of all paths without clearing the index.
    private func doRescan(client: any IPCClientProtocol) async -> Int32 {
        // Check daemon is running
        guard let pid = pidReader.readPID(from: pidPath), processSignaler.isProcessAlive(pid) else {
            output.write("Daemon is not running. Start it first: \(Product.command) daemon start\n")
            return 2
        }

        do {
            let response = try await client.send(.rescan)
            if case .ack = response {
                output.write("Rescan triggered — daemon is scanning all paths.\n")
                return 0
            } else {
                output.writeError("Error: unexpected response from daemon\n")
                return 2
            }
        } catch {
            output.writeError("Error: could not reach daemon — \(error.localizedDescription)\n")
            return 2
        }
    }

    // MARK: - Helpers

    /// Remove the Unix domain socket file if it exists.
    private func cleanupSocket() {
        // socketPath is already tilde-expanded in init — no need to expand again
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Format a duration in seconds as a human-readable string (e.g. "2h 30m", "5m 12s", "45s").
    private func formatUptime(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    /// Format an integer with thousand-separator commas (e.g. 1_484_939 → "1,484,939").
    private static func formatNumber(_ n: Int) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.groupingSeparator = ","
        return nf.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Format a duration in seconds as a human-readable ETA (e.g. "45m", "2h 30m", "30s").
    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m"
        } else {
            return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
        }
    }

    /// Expand `~` in a path to the user's home directory.
    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

// MARK: - System Implementations

/// Production implementation: delegates to `IPCClient.spawnDaemon` for
/// shared secure path resolution, environment hardening, and stdio setup.
public struct SystemProcessSpawner: ProcessSpawner, Sendable {
    public init() {}
    public func spawnDaemon(binaryPath: String, arguments: [String]) -> Result<Void, Error> {
        let result = IPCClient.spawnDaemon(binaryPath: binaryPath)
        switch result {
        case .success:
            return .success(())
        case .failure(let spawnError):
            return .failure(spawnError)
        }
    }
}

/// Production implementation: uses `kill(pid, 0)` for liveness and `kill(pid, SIGTERM)`.
public struct SystemProcessSignaler: ProcessSignaler, Sendable {
    public init() {}
    public func sendSIGTERM(to pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }

    public func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}

/// Production implementation: polls the socket file and attempts connection.
public struct SystemSocketWaiter: SocketWaiter, Sendable {
    public init() {}
    public func waitForSocket(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = Constants.IPC.socketPollIntervalNs

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                // Try to connect to verify daemon is ready
                let testFD = socket(AF_UNIX, SOCK_STREAM, 0)
                if testFD >= 0 {
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    // `sun_path` is a fixed-size buffer (104 bytes on macOS). The raw
                    // `strcpy` below was an unbounded write — a socket path whose UTF-8
                    // encoding fills or exceeds the buffer would overflow it. Guard the
                    // length and use the bounded `strlcpy` instead. (A path this long
                    // cannot represent a valid bound AF_UNIX address anyway.)
                    let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
                    if path.utf8.count >= sunPathCapacity {
                        Darwin.close(testFD)
                        usleep(UInt32(pollInterval / 1000))
                        continue
                    }
                    path.withCString { pathPtr in
                        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                            strlcpy(destPtr, pathPtr, sunPathCapacity)
                        }
                    }
                    let result = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                            Darwin.connect(testFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    Darwin.close(testFD)
                    if result == 0 {
                        return true
                    }
                }
            }
            usleep(UInt32(pollInterval / 1000)) // convert ns to us
        }
        return false
    }
}

/// Production implementation: reads/removes PID files from disk.
public struct SystemPIDReader: PIDReader, Sendable {
    public init() {}
    public func readPID(from path: String) -> Int32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(str) else {
            return nil
        }
        // Verify the process is actually alive
        guard kill(pid, 0) == 0 else {
            // Stale — remove the file
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return pid
    }

    public func removePIDFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
