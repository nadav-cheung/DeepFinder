/// Client-side IPC connector used by CLI and GUI to talk to the daemon.
///
/// Connects over a Unix domain socket, sends framed `IPCRequest` messages, and reads
/// framed `IPCResponse` replies. Also handles daemon lifecycle: auto-spawning the daemon
/// binary, checking its PID file, and cleaning up stale sockets.
import Foundation

// MARK: - IPCClientError

enum IPCClientError: Error, CustomStringConvertible, Equatable {
    case notConnected
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case daemonSpawnFailed(String)
    case daemonStartupTimedOut

    var description: String {
        switch self {
        case .notConnected:
            return "IPCClient is not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .sendFailed(let reason):
            return "Send failed: \(reason)"
        case .receiveFailed(let reason):
            return "Receive failed: \(reason)"
        case .daemonSpawnFailed(let reason):
            return "Failed to spawn daemon: \(reason)"
        case .daemonStartupTimedOut:
            return "Daemon did not become ready within the expected timeout"
        }
    }
}

// MARK: - SpawnError

/// Error wrapper for daemon spawn failures.
struct SpawnError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - IPCClient

/// Client for communicating with the DeepFinder daemon over a Unix domain socket.
///
/// Connects to the daemon's IPC socket, sends framed `IPCRequest` messages,
/// and reads framed `IPCResponse` messages back. Provides convenience methods
/// for daemon lifecycle management (auto-spawn, PID checks, stale cleanup).
///
/// Thread-safe via actor isolation.
actor IPCClient {

    // MARK: - Properties

    /// Path to the Unix domain socket.
    private let socketPath: String

    /// File descriptor for the connected socket. -1 when not connected.
    private var fd: Int32 = -1

    /// Whether the client currently has an active connection.
    var isConnected: Bool {
        fd >= 0
    }

    // MARK: - Init

    /// Create a new IPCClient targeting the given socket path.
    ///
    /// Does not connect automatically — call `connect()` to establish the connection.
    ///
    /// - Parameter socketPath: Path to the Unix domain socket. Supports `~` expansion.
    init(socketPath: String) {
        self.socketPath = Self.expandTilde(socketPath)
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    // MARK: - Connection Lifecycle

    /// Connect to the daemon's Unix domain socket.
    ///
    /// - Throws: `IPCClientError.connectionFailed` if the socket cannot be reached.
    func connect() throws {
        guard fd < 0 else { return } // Already connected

        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else {
            throw IPCClientError.connectionFailed(String(cString: strerror(errno)))
        }

        // Prevent SIGPIPE when writing to a closed socket. Without this, a
        // daemon-side disconnect causes the app process to be killed instantly
        // by SIGPIPE — no crash report, no delegate methods, no error handling.
        var nosigpipe: Int32 = 1
        setsockopt(newFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout.size(ofValue: nosigpipe)))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { pathPtr in
            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                strcpy(destPtr, pathPtr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(newFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(newFD)
            throw IPCClientError.connectionFailed(err)
        }

        self.fd = newFD
    }

    /// Disconnect from the daemon. Safe to call when already disconnected.
    func disconnect() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    // MARK: - Request / Response

    /// Send an IPCRequest to the daemon and read one IPCResponse.
    ///
    /// Connects automatically if not already connected.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The daemon's response.
    /// - Throws: `IPCClientError` on communication failures.
    func send(_ request: IPCRequest) async throws -> IPCResponse {
        do {
            return try sendAttempt(request)
        } catch {
            // If the first attempt failed, the connection may be stale.
            // Disconnect, reconnect, and retry once.
            disconnect()
            try connect()
            return try sendAttempt(request)
        }
    }

    /// Single attempt to send a request and read the response.
    private func sendAttempt(_ request: IPCRequest) throws -> IPCResponse {
        if fd < 0 {
            try connect()
        }

        guard fd >= 0 else {
            throw IPCClientError.notConnected
        }

        // Encode and send
        let encoded: Data
        do {
            encoded = try IPCFraming.encode(request)
        } catch {
            throw IPCClientError.sendFailed("Encoding failed: \(error)")
        }

        do {
            try IPCFramingIO.writeAll(to: fd, data: encoded)
        } catch {
            throw IPCClientError.sendFailed(error.localizedDescription)
        }

        // Read response
        let responseData: Data
        do {
            responseData = try IPCFramingIO.readFramedMessage(from: fd)
        } catch {
            throw IPCClientError.receiveFailed(error.localizedDescription)
        }

        do {
            return try JSONDecoder().decode(IPCResponse.self, from: responseData)
        } catch {
            throw IPCClientError.receiveFailed("Decoding failed: \(error)")
        }
    }

    // MARK: - Daemon Lifecycle Helpers

    /// Ensure the daemon is running, spawning it if necessary.
    ///
    /// Checks if the daemon is alive via its PID file. If not running, spawns
    /// the daemon binary and polls the socket until it becomes available.
    ///
    /// - Parameters:
    ///   - pidPath: Path to the daemon's PID file.
    ///   - daemonBinaryPath: Path to the daemon executable.
    ///   - timeout: Maximum time to wait for the socket (seconds). Default 10.
    ///   - pollInterval: Time between socket availability checks (seconds). Default 0.5.
    ///   - maxRetries: Maximum number of spawn attempts. Default 3.
    /// - Throws: `IPCClientError.daemonSpawnFailed` or `IPCClientError.daemonStartupTimedOut`.
    func ensureDaemonRunning(
        pidPath: String = Product.pidPath,
        daemonBinaryPath: String = Product.daemonCommand,
        timeout: TimeInterval = Constants.IPC.daemonReadyTimeout,
        pollInterval: TimeInterval = Constants.IPC.daemonPollInterval,
        maxRetries: Int = 3
    ) async throws {
        let resolvedPidPath = Self.expandTilde(pidPath)
        let resolvedSocketPath = Self.expandTilde(socketPath)

        // Already running?
        if Self.isDaemonRunning(pidPath: resolvedPidPath) {
            return
        }

        // Try to spawn
        var lastError: String?
        for attempt in 1...maxRetries {
            // Clean up stale PID if present
            Self.cleanupStalePID(pidPath: resolvedPidPath)

            // Spawn daemon process
            let result = Self.spawnDaemon(binaryPath: daemonBinaryPath)
            switch result {
            case .success:
                break
            case .failure(let err):
                lastError = err.description
                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: Constants.IPC.retryDelayNs)
                    continue
                }
                throw IPCClientError.daemonSpawnFailed(lastError ?? "Unknown spawn error")
            }

            // Wait for socket to become available
            let deadline = Date().addingTimeInterval(timeout)
            var socketReady = false

            while Date() < deadline {
                // Check if socket file exists and is connectable
                if FileManager.default.fileExists(atPath: resolvedSocketPath) {
                    // Try to connect to verify daemon is ready
                    let testFD = socket(AF_UNIX, SOCK_STREAM, 0)
                    if testFD >= 0 {
                        var addr = sockaddr_un()
                        addr.sun_family = sa_family_t(AF_UNIX)
                        resolvedSocketPath.withCString { pathPtr in
                            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                                strcpy(destPtr, pathPtr)
                            }
                        }
                        let connectResult = withUnsafePointer(to: &addr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                                Darwin.connect(testFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
                            }
                        }
                        Darwin.close(testFD)
                        if connectResult == 0 {
                            socketReady = true
                            break
                        }
                    }
                }

                // Poll interval
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }

            if socketReady {
                return
            }

            lastError = "Daemon did not become ready within \(timeout)s (attempt \(attempt)/\(maxRetries))"
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: Constants.IPC.retryDelayNs)
            }
        }

        throw IPCClientError.daemonStartupTimedOut
    }

    // MARK: - Static Utilities

    /// Check if the daemon is running by examining its PID file.
    ///
    /// Reads the PID file. If the file exists and the process is alive, returns `true`.
    /// If the file exists but the process is dead (stale), cleans up the file and returns `false`.
    /// If the file doesn't exist, returns `false`.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    /// - Returns: `true` if a live daemon process is detected.
    static func isDaemonRunning(pidPath: String) -> Bool {
        DaemonMain.checkExistingDaemon(pidPath: pidPath)
    }

    /// Remove a stale PID file (process no longer alive).
    ///
    /// Only removes the file if the PID in it belongs to a dead process.
    /// If the PID belongs to a live process, the file is left intact.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    static func cleanupStalePID(pidPath: String) {
        let resolved = expandTilde(pidPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else { return }

        // Read PID
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
              let pidString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else {
            // Corrupted file — clean it up
            try? fm.removeItem(atPath: resolved)
            return
        }

        // Only remove if the process is actually dead
        let result = kill(pid, 0)
        if result != 0 {
            try? fm.removeItem(atPath: resolved)
        }
    }

    // MARK: - Private Helpers

    /// Expand `~` in a path to the user's home directory.
    private static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// Spawn the daemon process.
    ///
    /// Resolves the daemon binary from fixed, absolute locations only. Never uses
    /// PATH lookup or CWD-relative resolution, which would allow an attacker to
    /// substitute a malicious binary.
    static func spawnDaemon(binaryPath: String) -> Result<Void, SpawnError> {
        // Resolve the daemon binary path from absolute locations only.
        // Each candidate must be an absolute path (starts with "/") to prevent
        // CWD-relative attacks where a malicious binary could shadow the real one.
        // Build candidate absolute paths to search.
        // Use only the last path component to prevent path traversal attacks
        // (e.g. binaryPath = "../../malicious" should not resolve to cliDir/../../malicious).
        let binaryName = (binaryPath as NSString).lastPathComponent
        let cliDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent
        let candidates: [String] = [
            // 1. Next to the current CLI executable (SPM .build/debug/ or install dir)
            cliDir.map { ($0 as NSString).appendingPathComponent(binaryName) },
            // 2. Standard Homebrew / Unix install location
            "\(Product.defaultBinDir)/\(binaryName)",
        ].compactMap { $0 }

        let resolvedPath: String
        // If binaryPath is already absolute, use it directly
        if binaryPath.hasPrefix("/") {
            resolvedPath = binaryPath
        } else {
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                let searched = ["<provided path>"] + candidates
                return .failure(SpawnError(message:
                    "Daemon binary '\(binaryPath)' not found. " +
                    "Searched absolute locations: \(searched.joined(separator: ", ")). " +
                    "Install the daemon or provide an absolute path."
                ))
            }
            resolvedPath = found
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedPath)
        process.arguments = []

        // ── Security hardening ──────────────────────────────────────
        // Prevent daemon from inheriting parent cwd, stdio, or env.

        // Working directory: use data directory; fall back to root.
        let dataDir = Self.expandTilde(Product.dataDir)
        if FileManager.default.fileExists(atPath: dataDir) {
            process.currentDirectoryURL = URL(fileURLWithPath: dataDir)
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
        }

        // Stdio: detach from parent terminal.
        //   stdin  → /dev/null (daemon is non-interactive)
        //   stdout → daemon log file
        //   stderr → same log file
        let nullHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        process.standardInput = nullHandle

        let logDir = NSString(string: Product.logsDir).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logPath = (logDir as NSString).appendingPathComponent("daemon.log")
        // Create the log file if it doesn't exist, then open for append.
        // We preserve existing log contents (crash diagnostics from previous runs).
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            _ = try? logHandle.seekToEnd()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        // Environment: pass only the minimal set the daemon needs.
        // PATH is intentionally excluded — the daemon is launched from a fixed
        // absolute path and should not inherit an attacker-controlled PATH.
        let env = ProcessInfo.processInfo.environment
        var minimalEnv: [String: String] = [:]
        for key in ["HOME", "TMPDIR"] {
            if let value = env[key] {
                minimalEnv[key] = value
            }
        }
        process.environment = minimalEnv

        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(SpawnError(message: "Failed to launch daemon: \(error.localizedDescription)"))
        }
    }
}
