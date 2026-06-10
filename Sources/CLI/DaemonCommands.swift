import Foundation

// MARK: - Abstraction Protocols

/// Abstraction for spawning a daemon process. Testable via MockProcessSpawner.
protocol ProcessSpawner: Sendable {
    func spawnDaemon(binaryPath: String, arguments: [String]) -> Result<Void, Error>
}

/// Abstraction for sending signals to processes and checking liveness.
protocol ProcessSignaler: Sendable {
    /// Send SIGTERM to the given PID. Returns true if the signal was sent successfully.
    func sendSIGTERM(to pid: Int32) -> Bool
    /// Check whether the process with the given PID is still alive.
    func isProcessAlive(_ pid: Int32) -> Bool
}

/// Abstraction for waiting until the daemon's IPC socket is available.
protocol SocketWaiter: Sendable {
    /// Poll until the socket file exists and is connectable, or timeout elapses.
    /// Returns true if the socket became available within the timeout.
    func waitForSocket(at path: String, timeout: TimeInterval) -> Bool
}

/// Abstraction for reading PID files and removing them.
protocol PIDReader: Sendable {
    /// Read the PID from the file at the given path. Returns nil if the file
    /// does not exist or is corrupted.
    func readPID(from path: String) -> Int32?
    /// Remove the PID file at the given path.
    func removePIDFile(at path: String)
}

// MARK: - DaemonSubcommand

/// Subcommands for managing the DeepFinder daemon.
///
/// Usage: `deepfinder daemon start|stop|restart|status`
enum DaemonSubcommand: String, Sendable, Equatable {
    case start
    case stop
    case restart
    case status
}

// MARK: - DaemonCommandRunnerError

private enum DaemonCommandRunnerError: Error, CustomStringConvertible {
    case spawnFailed(String)
    case startupTimedOut
    case daemonNotRunning
    case stopTimedOut

    var description: String {
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
struct DaemonCommandRunner: Sendable {

    /// Paths and binary location.
    let pidPath: String
    let socketPath: String
    let daemonBinaryPath: String

    /// Injectable dependencies.
    let processSpawner: any ProcessSpawner
    let processSignaler: any ProcessSignaler
    let socketWaiter: any SocketWaiter
    let pidReader: any PIDReader
    let output: any CLIOutputWriter

    /// How long to wait for the daemon socket to become available after spawn.
    let startupTimeout: TimeInterval

    /// How long to wait for the daemon to exit after SIGTERM.
    let shutdownTimeout: TimeInterval

    /// Poll interval for checking process liveness during stop.
    let shutdownPollInterval: TimeInterval

    // MARK: - Init

    init(
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
    func run(_ subcommand: DaemonSubcommand, client: any IPCClientProtocol) async -> Int32 {
        switch subcommand {
        case .start:
            return await doStart(client: client)
        case .stop:
            return await doStop()
        case .restart:
            return await doRestart(client: client)
        case .status:
            return await doStatus(client: client)
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
            return 1
        }

        // Wait for socket
        let ready = socketWaiter.waitForSocket(at: socketPath, timeout: startupTimeout)
        if !ready {
            output.writeError("Error: \(DaemonCommandRunnerError.startupTimedOut)\n")
            return 1
        }

        output.write("Daemon started\n")
        return 0
    }

    // MARK: - Stop

    /// Stop the daemon by sending SIGTERM and polling until exit or timeout.
    private func doStop() async -> Int32 {
        guard let pid = pidReader.readPID(from: pidPath) else {
            output.write("Daemon is not running\n")
            return 1
        }

        guard processSignaler.isProcessAlive(pid) else {
            // Stale PID file
            pidReader.removePIDFile(at: pidPath)
            cleanupSocket()
            output.write("Daemon is not running (cleaned up stale PID file)\n")
            return 1
        }

        // Send SIGTERM
        guard processSignaler.sendSIGTERM(to: pid) else {
            output.writeError("Error: failed to send SIGTERM to PID \(pid)\n")
            return 1
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
            return 1
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
            return 1
        }

        guard processSignaler.isProcessAlive(pid) else {
            output.write("Daemon is not running (stale PID file)\n")
            return 1
        }

        // Fetch stats via IPC
        let response: IPCResponse
        do {
            response = try await client.send(.stats)
        } catch {
            // Daemon PID exists but IPC failed
            output.writeError("Daemon running (PID \(pid)) but not reachable via IPC\n")
            output.writeError("  Error: \(error.localizedDescription)\n")
            return 1
        }

        switch response {
        case .stats(let stats):
            let uptime = formatUptime(stats.uptimeSeconds)
            output.write("Daemon running (PID \(pid))\n")
            output.write("  Uptime: \(uptime)\n")
            output.write("  Index state: \(stats.indexState)\n")
            output.write("  Files indexed: \(stats.totalFiles)\n")
            output.write("  Memory: \(String(format: "%.1f", stats.memoryUsageMB)) MB\n")
            return 0

        case .error(let ipcError):
            output.writeError("Daemon running (PID \(pid)) but returned error: \(ipcError)\n")
            return 1

        default:
            output.writeError("Daemon running (PID \(pid)) but returned unexpected response\n")
            return 1
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

    /// Expand `~` in a path to the user's home directory.
    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

// MARK: - System Implementations

/// Production implementation: delegates to `IPCClient.spawnDaemon` for
/// shared secure path resolution, environment hardening, and stdio setup.
struct SystemProcessSpawner: ProcessSpawner, Sendable {
    func spawnDaemon(binaryPath: String, arguments: [String]) -> Result<Void, Error> {
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
struct SystemProcessSignaler: ProcessSignaler, Sendable {
    func sendSIGTERM(to pid: Int32) -> Bool {
        kill(pid, SIGTERM) == 0
    }

    func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}

/// Production implementation: polls the socket file and attempts connection.
struct SystemSocketWaiter: SocketWaiter, Sendable {
    func waitForSocket(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = Constants.IPC.socketPollIntervalNs

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                // Try to connect to verify daemon is ready
                let testFD = socket(AF_UNIX, SOCK_STREAM, 0)
                if testFD >= 0 {
                    var addr = sockaddr_un()
                    addr.sun_family = sa_family_t(AF_UNIX)
                    path.withCString { pathPtr in
                        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                            strcpy(destPtr, pathPtr)
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
struct SystemPIDReader: PIDReader, Sendable {
    func readPID(from path: String) -> Int32? {
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

    func removePIDFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
