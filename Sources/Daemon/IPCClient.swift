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
private struct SpawnError: Error, CustomStringConvertible {
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
    /// - Parameter socketPath: Absolute path to the Unix domain socket.
    init(socketPath: String) {
        self.socketPath = socketPath
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
            try writeAll(data: encoded)
        } catch {
            throw IPCClientError.sendFailed(error.localizedDescription)
        }

        // Read response
        let responseData: Data
        do {
            responseData = try readFramedMessage()
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
        daemonBinaryPath: String = Product.command,
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.5,
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
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s between retries
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
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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
    private static func spawnDaemon(binaryPath: String) -> Result<Void, SpawnError> {
        // Use Process to launch the daemon in the background
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--daemon"]

        do {
            try process.run()
            return .success(())
        } catch {
            return .failure(SpawnError(message: "Failed to launch daemon: \(error.localizedDescription)"))
        }
    }

    /// Write all data to the connected socket.
    private func writeAll(data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                throw IPCClientError.sendFailed(String(cString: strerror(errno)))
            }
            offset += written
        }
    }

    /// Read a 4-byte-length-prefixed framed message from the connected socket.
    private func readFramedMessage() throws -> Data {
        // Read 4-byte header
        var header = Data(capacity: 4)
        while header.count < 4 {
            var buf = [UInt8](repeating: 0, count: 4 - header.count)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                throw IPCClientError.receiveFailed("Connection closed while reading header")
            }
            header.append(contentsOf: buf.prefix(n))
        }

        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard length > 0 else { return Data() }

        // Sanity check
        let maxMessageSize = 16 * 1024 * 1024 // 16 MB
        guard length <= maxMessageSize else {
            throw IPCClientError.receiveFailed("Message too large: \(length) bytes")
        }

        // Read payload
        var payload = Data(capacity: length)
        while payload.count < length {
            let remaining = length - payload.count
            var buf = [UInt8](repeating: 0, count: min(remaining, 8192))
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                throw IPCClientError.receiveFailed("Connection closed while reading payload")
            }
            payload.append(contentsOf: buf.prefix(n))
        }

        return payload
    }
}
