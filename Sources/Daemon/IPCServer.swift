import Foundation

// MARK: - IPCServerError

/// Errors thrown by ``IPCServer`` during socket operations.
enum IPCServerError: Error, Sendable, Equatable {
    /// Failed to create the Unix domain socket.
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case connectionClosed
    case notRunning
    case alreadyRunning
    case messageTooLarge(Int)
}

// MARK: - IPCServer

/// Accepts IPC client connections over a Unix domain socket.
///
/// Each incoming connection is handled in its own `Task`. The server reads
/// a single framed `IPCRequest` per connection (4-byte length-prefix + JSON),
/// dispatches it to the appropriate handler, and writes back one framed
/// `IPCResponse`.
///
/// The listen socket is set to non-blocking mode so the accept loop can
/// cooperatively yield via `Task.sleep`, keeping Swift concurrency healthy.
///
/// **Platform note**: Unix domain sockets are POSIX-specific. The socket path
/// length is limited to `sizeof(sockaddr_un.sun_path) - 1` bytes (103 on macOS).
/// The default path `~/.deep-finder/ipc.sock` is well within this limit.
///
/// Thread-safe via actor isolation.
actor IPCServer {

    // MARK: - Properties

    private let socketPath: String
    private let coordinator: SearchCoordinator
    private let statsProvider: @Sendable () -> DaemonStats

    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [Task<Void, Never>] = []
    private var startTime: Date?

    /// Maximum allowed message size (16 MB).
    private let maxMessageSize = 16 * 1024 * 1024

    /// Whether the server is currently listening for connections.
    var isRunning: Bool {
        listenFD >= 0
    }

    // MARK: - Init

    /// Create an IPC server.
    ///
    /// - Parameters:
    ///   - socketPath: File path for the Unix domain socket (e.g. `~/.deep-finder/ipc.sock`).
    ///   - coordinator: The search coordinator that processes queries.
    ///   - statsProvider: Closure that returns current daemon statistics when called.
    init(
        socketPath: String,
        coordinator: SearchCoordinator,
        statsProvider: @escaping @Sendable () -> DaemonStats = {
            DaemonStats(totalFiles: 0, indexState: "unknown", uptimeSeconds: 0, memoryUsageMB: 0)
        }
    ) {
        self.socketPath = socketPath
        self.coordinator = coordinator
        self.statsProvider = statsProvider
    }

    // MARK: - Lifecycle

    /// Start listening on the Unix domain socket.
    ///
    /// Removes any stale socket file at `socketPath` before binding.
    /// - Throws: `IPCServerError` if socket creation, binding, or listening fails.
    func start() throws {
        guard listenFD < 0 else {
            throw IPCServerError.alreadyRunning
        }

        // Validate path fits in sockaddr_un.sun_path (104 bytes including null terminator)
        let maxPathLength = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard socketPath.utf8.count <= maxPathLength else {
            throw IPCServerError.socketCreationFailed(
                "Socket path too long (\(socketPath.utf8.count) bytes, max \(maxPathLength))"
            )
        }

        // Clean up stale socket file
        unlink(socketPath)

        // Ensure parent directory exists
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // Set non-blocking mode on listen socket so accept() doesn't block threads
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            close(fd)
            throw IPCServerError.socketCreationFailed(String(cString: strerror(errno)))
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(fd)
            throw IPCServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { pathPtr in
            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { destPtr in
                strcpy(destPtr, pathPtr)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw IPCServerError.bindFailed(err)
        }

        // Listen (backlog of 16)
        guard listen(fd, 16) == 0 else {
            let err = String(cString: strerror(errno))
            close(fd)
            throw IPCServerError.listenFailed(err)
        }

        self.listenFD = fd
        self.startTime = Date()

        // Ignore SIGPIPE — handle write errors explicitly
        signal(SIGPIPE, SIG_IGN)

        // Accept loop runs in background Task
        let capturedFD = fd
        acceptTask = Task { [weak self = self] in
            await self?.acceptLoop(listenFD: capturedFD)
        }
    }

    /// Stop accepting new connections and clean up.
    ///
    /// Cancels the accept loop and all in-flight client tasks, closes the listen
    /// socket, and removes the socket file from disk.
    ///
    /// - Note: In-flight client connections are cancelled via `Task.cancel()`, which
    ///   sets the cancellation flag. The actual file descriptor is closed when the
    ///   client handler's `defer { close(fd) }` fires on the next I/O error or when
    ///   the blocking `read()`/`write()` syscall returns. Under normal shutdown, the
    ///   clients will complete their current request before noticing cancellation.
    func stop() {
        guard listenFD >= 0 else { return }

        // Cancel accept loop
        acceptTask?.cancel()
        acceptTask = nil

        // Cancel all client tasks
        for task in clientTasks {
            task.cancel()
        }
        clientTasks.removeAll()

        // Close listen socket (unblocks non-blocking accept if still polling)
        let fd = listenFD
        listenFD = -1
        close(fd)

        // Remove socket file
        unlink(socketPath)

        startTime = nil
    }

    // MARK: - Accept Loop

    private func acceptLoop(listenFD: Int32) async {
        while !Task.isCancelled {
            var addr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    accept(listenFD, rebound, &addrLen)
                }
            }

            if clientFD < 0 {
                let err = errno
                // Socket closed by stop()
                if self.listenFD < 0 { break }
                // No pending connections — yield and retry
                if err == EAGAIN || err == EWOULDBLOCK {
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    continue
                }
                // Other transient errors (e.g. EMFILE when out of file descriptors).
                // Brief pause prevents busy-looping; persistent errors will eventually
                // resolve or the server will be stopped via stop().
                try? await Task.sleep(nanoseconds: 1_000_000)
                try? await Task.sleep(nanoseconds: 1_000_000)
                continue
            }

            let task = Task { [weak self = self] in
                guard let self else { return }
                await self.handleClient(fd: clientFD)
            }
            clientTasks.append(task)
        }
    }

    // MARK: - Client Handling

    /// Read one framed request from client, dispatch, write response.
    private func handleClient(fd: Int32) async {
        defer { close(fd) }

        do {
            // Read framed request
            let requestData = try readFramedMessage(fd: fd)
            let request = try JSONDecoder().decode(IPCRequest.self, from: requestData)

            // Dispatch
            let response = await dispatchRequest(request)

            // Write framed response
            let responseData = try IPCFraming.encode(response)
            try writeAll(fd: fd, data: responseData)
        } catch {
            // Send error response if possible
            let errorResponse = IPCResponse.error(
                .invalidRequest(error.localizedDescription)
            )
            if let data = try? IPCFraming.encode(errorResponse) {
                try? writeAll(fd: fd, data: data)
            }
        }
    }

    /// Dispatch a decoded IPCRequest to the appropriate handler.
    func dispatchRequest(_ request: IPCRequest) async -> IPCResponse {
        switch request {
        case .query(let query, let limit):
            var results = await coordinator.search(query: query)
            if let limit {
                results = Array(results.prefix(limit))
            }
            let queryID = "q-\(UUID().uuidString.prefix(8))"
            return .results(results, queryID: queryID)

        case .stats:
            let stats = statsProvider()
            return .stats(stats)

        case .cancel:
            return .ack

        case .configGet:
            return .ack

        case .configSet:
            return .ack

        case .indexStatus:
            let status = DaemonIndexStatus(
                state: "unknown",
                filesIndexed: 0,
                lastScanDate: nil
            )
            return .indexStatus(status)
        }
    }

    // MARK: - I/O Helpers

    /// Read a 4-byte-length-prefixed message from a file descriptor.
    private func readFramedMessage(fd: Int32) throws -> Data {
        // Read 4-byte header
        var header = Data(capacity: 4)
        while header.count < 4 {
            var buf = [UInt8](repeating: 0, count: 4 - header.count)
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                throw IPCServerError.connectionClosed
            }
            header.append(contentsOf: buf.prefix(n))
        }

        // Parse length
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) }))

        // Sanity check: reject unreasonably large messages
        guard length <= maxMessageSize else {
            throw IPCServerError.messageTooLarge(length)
        }
        guard length > 0 else {
            return Data()
        }

        // Read payload
        var payload = Data(capacity: length)
        while payload.count < length {
            let remaining = length - payload.count
            var buf = [UInt8](repeating: 0, count: min(remaining, 8192))
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                throw IPCServerError.connectionClosed
            }
            payload.append(contentsOf: buf.prefix(n))
        }

        return payload
    }

    /// Write all data to a file descriptor.
    ///
    /// Loops until all bytes are written or an error occurs. Handles partial writes
    /// by advancing the offset and retrying.
    private func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written <= 0 {
                throw IPCServerError.connectionClosed
            }
            offset += written
        }
    }
}
