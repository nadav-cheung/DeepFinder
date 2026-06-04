/// Daemon-side IPC listener that accepts client connections over a Unix domain socket.
///
/// Each connection is handled in its own Task: reads one framed `IPCRequest`, dispatches
/// it to the `SearchCoordinator`, and writes back one framed `IPCResponse`. Enforces
/// rate limiting, concurrency caps, and peer-credential verification to reject connections
/// from other users.
import Foundation
import OSLog

// MARK: - IPCServerError

/// Errors thrown by ``IPCServer`` during socket operations.
enum IPCServerError: Error, Sendable, Equatable {
    /// Failed to create the Unix domain socket.
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case notRunning
    case alreadyRunning
    /// Peer credential verification failed (uid mismatch, invalid pid, etc.).
    /// The associated value is the client file descriptor that was rejected.
    case peerVerificationFailed(Int32)
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
/// The default path `~/.deep-finder/session/ipc.sock` is well within this limit.
///
/// Thread-safe via actor isolation.
actor IPCServer {

    // MARK: - Logging

    /// Structured logger for IPC server events.
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "ipc")

    // MARK: - Properties

    private let socketPath: String
    private let coordinator: SearchCoordinator
    private let statsProvider: @Sendable () async -> DaemonStats
    private let indexStatusProvider: @Sendable () async -> DaemonIndexStatus
    private let duplicateProvider: @Sendable (DuplicateQueryStrategy) async -> [DuplicateGroup]
    private let suggestProvider: @Sendable (String) async -> [String]
    private let configGetProvider: @Sendable (String?) async -> String?
    private let configSetProvider: @Sendable (String, String) async -> Void

    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [Task<Void, Never>] = []
    private var startTime: Date?

    // MARK: Rate Limiting

    /// Sliding-window timestamps of recent connections for rate-limit decisions.
    /// Never grows beyond `maxConnsPerSecond` because entries older than 1 s
    /// are purged on each check.
    /// Actor isolation serializes all access — no lock needed.
    private var connectionTimestamps: [Date] = []

    /// Maximum new connections allowed within a 1-second sliding window.
    private let maxConnsPerSecond: Int

    /// Maximum number of concurrently handled client connections.
    private let maxConcurrentClients: Int

    /// Count of currently in-flight client-handling tasks.
    private var activeClientCount: Int = 0

    /// Whether the server is currently listening for connections.
    var isRunning: Bool {
        listenFD >= 0
    }

    // MARK: - Init

    /// Create an IPC server.
    ///
    /// - Parameters:
    ///   - socketPath: File path for the Unix domain socket (e.g. `~/.deep-finder/session/ipc.sock`).
    ///   - coordinator: The search coordinator that processes queries.
    ///   - statsProvider: Async closure that returns current daemon statistics when called.
    ///   - indexStatusProvider: Async closure that returns current index status when called.
    ///   - duplicateProvider: Async closure that finds duplicates by strategy (REQ-1.5-06).
    ///   - maxConnsPerSecond: Maximum new connections allowed per second (default 10).
    ///   - maxConcurrentClients: Maximum concurrent client connections (default 50).
    init(
        socketPath: String,
        coordinator: SearchCoordinator,
        statsProvider: @escaping @Sendable () async -> DaemonStats = {
            DaemonStats(totalFiles: 0, indexState: "unknown", uptimeSeconds: 0, memoryUsageMB: 0)
        },
        indexStatusProvider: @escaping @Sendable () async -> DaemonIndexStatus = {
            DaemonIndexStatus(state: "unknown", filesIndexed: 0, lastScanDate: nil)
        },
        duplicateProvider: @escaping @Sendable (DuplicateQueryStrategy) async -> [DuplicateGroup] = { _ in [] },
        suggestProvider: @escaping @Sendable (String) async -> [String] = { _ in [] },
        configGetProvider: @escaping @Sendable (String?) async -> String? = { _ in nil },
        configSetProvider: @escaping @Sendable (String, String) async -> Void = { _, _ in },
        maxConnsPerSecond: Int = Constants.IPC.maxConnsPerSecond,
        maxConcurrentClients: Int = Constants.IPC.maxConcurrentClients
    ) {
        self.socketPath = socketPath
        self.coordinator = coordinator
        self.statsProvider = statsProvider
        self.indexStatusProvider = indexStatusProvider
        self.duplicateProvider = duplicateProvider
        self.suggestProvider = suggestProvider
        self.configGetProvider = configGetProvider
        self.configSetProvider = configSetProvider
        self.maxConnsPerSecond = maxConnsPerSecond
        self.maxConcurrentClients = maxConcurrentClients
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

        logger.info("Starting IPC server on \(self.socketPath, privacy: .public)")

        // Validate path fits in sockaddr_un.sun_path (104 bytes including null terminator)
        let maxPathLength = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard socketPath.utf8.count <= maxPathLength else {
            logger.error("Socket path too long: \(self.socketPath.utf8.count) bytes (max \(maxPathLength))")
            throw IPCServerError.socketCreationFailed(
                "Socket path too long (\(socketPath.utf8.count) bytes, max \(maxPathLength))"
            )
        }

        // Clean up stale socket file
        unlink(socketPath)
        logger.debug("Cleaned up stale socket file: \(self.socketPath, privacy: .public)")

        // Ensure parent directory exists
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.error("Socket creation failed: \(errMsg, privacy: .public)")
            throw IPCServerError.socketCreationFailed(errMsg)
        }

        // Set non-blocking mode on listen socket so accept() doesn't block threads
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.error("fcntl F_GETFL failed: \(errMsg, privacy: .public)")
            close(fd)
            throw IPCServerError.socketCreationFailed(errMsg)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.error("fcntl F_SETFL O_NONBLOCK failed: \(errMsg, privacy: .public)")
            close(fd)
            throw IPCServerError.socketCreationFailed(errMsg)
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
            logger.error("Socket bind failed: \(err, privacy: .public)")
            close(fd)
            throw IPCServerError.bindFailed(err)
        }

        // Listen
        guard listen(fd, Constants.IPC.listenBacklog) == 0 else {
            let err = String(cString: strerror(errno))
            logger.error("Socket listen failed: \(err, privacy: .public)")
            close(fd)
            throw IPCServerError.listenFailed(err)
        }

        self.listenFD = fd
        self.startTime = Date()

        // Ignore SIGPIPE — handle write errors explicitly
        signal(SIGPIPE, SIG_IGN)

        logger.debug("Socket fd \(fd) bound and listening, backlog \(Constants.IPC.listenBacklog)")

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

        logger.info("Stopping IPC server on \(self.socketPath, privacy: .public)")

        // Cancel accept loop
        acceptTask?.cancel()
        acceptTask = nil

        // Cancel all client tasks
        let clientCount = clientTasks.count
        for task in clientTasks {
            task.cancel()
        }
        clientTasks.removeAll()
        logger.debug("Cancelled \(clientCount) in-flight client tasks")

        // Close listen socket (unblocks non-blocking accept if still polling)
        let fd = listenFD
        listenFD = -1
        close(fd)
        logger.debug("Closed listen socket fd \(fd)")

        // Remove socket file
        unlink(socketPath)

        startTime = nil
        logger.info("IPC server stopped")
    }

    // MARK: - Rate Limiting

    /// Check whether accepting a new connection would exceed rate or concurrency limits.
    ///
    /// Side effect: records the current timestamp in the sliding window when the
    /// connection is allowed, so call this only when actually about to accept.
    ///
    /// - Returns: A tuple `(limited, reason)` — `limited` is `true` when the
    ///   connection should be rejected, with `reason` describing which limit fired.
    private func recordConnectionAndCheckRateLimit() -> (limited: Bool, reason: String?) {
        // 1. Concurrency cap
        if activeClientCount >= maxConcurrentClients {
            return (true, "Max concurrent clients (\(maxConcurrentClients)) reached (\(activeClientCount) active)")
        }

        // 2. Rate cap — sliding 1-second window
        let now = Date()
        let oneSecondAgo = now.addingTimeInterval(-1.0)

        // Purge timestamps outside the window
        connectionTimestamps.removeAll { $0 <= oneSecondAgo }

        if connectionTimestamps.count >= maxConnsPerSecond {
            return (true,
                "Rate limit: \(connectionTimestamps.count) connections in last second (max \(maxConnsPerSecond))")
        }

        // Allow — record this connection and increment the active-client counter
        connectionTimestamps.append(now)
        activeClientCount += 1
        return (false, nil)
    }

    /// Decrement the active-client counter. Called by each client-handling task
    /// after `handleClient(fd:)` returns.
    private func clientDidFinish() {
        if activeClientCount > 0 { activeClientCount -= 1 }
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
                    try? await Task.sleep(nanoseconds: Constants.IPC.acceptPollIntervalNs)
                    continue
                }
                // Other transient errors (e.g. EMFILE when out of file descriptors).
                // Brief pause prevents busy-looping; persistent errors will eventually
                // resolve or the server will be stopped via stop().
                try? await Task.sleep(nanoseconds: Constants.IPC.acceptPollIntervalNs)
                continue
            }

            // Clear O_NONBLOCK — macOS accept() inherits the non-blocking flag
            // from the listen socket, but client sockets must be blocking for
            // SO_RCVTIMEO to work correctly. Without this, read() returns
            // EAGAIN immediately instead of blocking up to the timeout.
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
            }

            // Verify peer credentials — reject connections from other users
            guard verifyPeerCredential(fd: clientFD) else {
                logger.warning("Security: Rejecting connection on fd \(clientFD) — peer credential verification failed")
                close(clientFD)
                continue
            }

            // Rate limiting — reject if over concurrency or rate cap
            let (limited, reason) = recordConnectionAndCheckRateLimit()
            if limited {
                logger.warning(
                    "Rate limit: Rejecting connection on fd \(clientFD) — \(reason ?? "unknown", privacy: .public)")
                close(clientFD)
                // Brief back-off to slow down a flooder
                try? await Task.sleep(nanoseconds: Constants.IPC.acceptBackoffNs)
                continue
            }

            // Prune cancelled tasks so the array does not grow without bound
            clientTasks.removeAll(where: \.isCancelled)
            if clientTasks.count > Constants.IPC.maxTaskArraySize {
                // Safety cap: if >200 tasks remain after pruning cancelled ones,
                // something is wrong — clear the array to prevent unbounded growth.
                logger.warning("clientTasks exceeded 200 entries (\(self.clientTasks.count)), forcing prune")
                clientTasks.removeAll()
            }

            // Note: handleClient performs blocking read() on the actor's executor.
            // This is acceptable because: (1) SO_RCVTIMEO bounds each read to 30 seconds,
            // (2) maxConcurrentClients limits concurrent blocking threads to 50,
            // (3) all clients are local Unix domain socket connections from the same user.
            // For a multi-user or network-facing server, non-blocking I/O would be required.
            let task = Task { [weak self = self] in
                guard let self else { return }
                await self.handleClient(fd: clientFD)
                await self.clientDidFinish()
            }
            clientTasks.append(task)
        }
    }

    // MARK: - Peer Credential Verification

    /// Verify that the peer process on the given socket file descriptor
    /// is running as the same user as this daemon process.
    ///
    /// Uses `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...)` to retrieve
    /// the peer's credentials (`xucred`) and compares the effective UID
    /// with `getuid()`. Also retrieves the peer PID via `LOCAL_PEERPID`
    /// and validates it is positive.
    ///
    /// - Parameter fd: The client socket file descriptor returned by `accept()`.
    /// - Returns: `true` if the peer is a valid process belonging to the same user.
    private func verifyPeerCredential(fd: Int32) -> Bool {
        // 1. Retrieve peer credentials (xucred: uid + groups)
        var peerCred = xucred()
        var peerCredLen = socklen_t(MemoryLayout<xucred>.size)
        let credResult = withUnsafeMutablePointer(to: &peerCred) { ptr in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ptr, &peerCredLen)
        }

        guard credResult == 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.warning("Security: getsockopt LOCAL_PEERCRED failed for fd \(fd): \(errMsg, privacy: .public)")
            return false
        }

        // 2. Retrieve peer PID
        var peerPID: pid_t = 0
        var peerPIDLen = socklen_t(MemoryLayout<pid_t>.size)
        let pidResult = withUnsafeMutablePointer(to: &peerPID) { ptr in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, ptr, &peerPIDLen)
        }

        guard pidResult == 0 else {
            let errMsg = String(cString: strerror(errno))
            logger.warning("Security: getsockopt LOCAL_PEERPID failed for fd \(fd): \(errMsg, privacy: .public)")
            return false
        }

        // 3. Verify PID is valid
        guard peerPID > 0 else {
            logger.warning("Security: Invalid peer PID (\(peerPID)) for fd \(fd)")
            return false
        }

        // 4. Verify same user
        let myUID = getuid()
        guard peerCred.cr_uid == myUID else {
            logger.warning("Security: Peer UID mismatch (peer=\(peerCred.cr_uid), self=\(myUID)) for fd \(fd)")
            return false
        }

        logger.debug("Security: Peer credential verified for fd \(fd): pid=\(peerPID), uid=\(peerCred.cr_uid)")
        return true
    }

    // MARK: - Client Handling

    /// Read one framed request from client, dispatch, write response.
    private func handleClient(fd: Int32) async {
        defer { close(fd) }

        // Set receive timeout to prevent slowloris-style DoS: a malicious
        // client can otherwise send data one byte at a time to keep the
        // connection open indefinitely, consuming a slot in the concurrent-
        // client limit (default 50) and blocking legitimate clients.
        var rcvTimeout = timeval(tv_sec: Constants.IPC.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
                   &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

        logger.debug("New client connection accepted on fd \(fd)")

        do {
            // Read framed request
            let requestData = try IPCFramingIO.readFramedMessage(from: fd)
            let request = try JSONDecoder().decode(IPCRequest.self, from: requestData)
            logger.debug("Received IPC request: \(String(describing: request), privacy: .public)")

            // Dispatch
            let response = await dispatchRequest(request)

            // Write framed response
            let responseData = try IPCFraming.encode(response)
            try IPCFramingIO.writeAll(to: fd, data: responseData)
            logger.debug("Sent IPC response to fd \(fd)")
        } catch let ipcError as IPCError {
            logger.error("Client fd \(fd) IPC error: \(String(describing: ipcError), privacy: .public)")
            let errorResponse = IPCResponse.error(ipcError)
            if let data = try? IPCFraming.encode(errorResponse) {
                try? IPCFramingIO.writeAll(to: fd, data: data)
            }
        } catch {
            logger.error("Client fd \(fd) error: \(error.localizedDescription, privacy: .public)")
            // Send error response if possible
            let errorResponse = IPCResponse.error(
                .invalidRequest(error.localizedDescription)
            )
            if let data = try? IPCFraming.encode(errorResponse) {
                try? IPCFramingIO.writeAll(to: fd, data: data)
            }
        }
    }

    /// Dispatch a decoded IPCRequest to the appropriate handler.
    func dispatchRequest(_ request: IPCRequest) async -> IPCResponse {
        switch request {
        case .query(let query, let limit):
            // Defense-in-depth: reject oversized queries even if the decoder
            // check was somehow bypassed (e.g. future protocol change).
            guard query.count <= maxQueryLength else {
                return .error(.queryError(
                    "Query too long (\(query.count) chars, max \(maxQueryLength))"
                ))
            }
            // Extract modifier pairs from the query and build filters
            let parsed = QueryParser.parse(query)
            let modifierPairs = parsed.modifierPairs
            let filters = modifierPairs.isEmpty
                ? []
                : FilterPipeline.parse(from: modifierPairs).filters
            let cleanQuery = parsed.textOnlyQuery

            var results = await coordinator.search(query: cleanQuery, filters: filters)
            if let limit {
                results = Array(results.prefix(limit))
            }
            let queryID = "q-\(UUID().uuidString.prefix(8))"
            return .results(results, queryID: queryID)

        case .stats:
            let stats = await statsProvider()
            return .stats(stats)

        case .cancel:
            return .ack

        case .configGet(let key):
            if let value = await configGetProvider(key) {
                return .configValue(value)
            }
            return .ack

        case .configSet(let key, let value):
            await configSetProvider(key, value)
            return .ack

        case .indexStatus:
            let status = await indexStatusProvider()
            return .indexStatus(status)

        case .duplicateQuery(let strategy):
            let groups = await duplicateProvider(strategy)
            return .duplicates(groups)

        // Bookmark & filter IPC (REQ-1.3-06) — delegated to closures.
        case .bookmarkList, .bookmarkSave, .bookmarkDelete,
             .filterList, .filterSave, .filterDelete:
            // These are handled locally by the CLI; daemon returns ack for forward compat.
            return .ack

        case .suggest(let query):
            let terms = await suggestProvider(query)
            return .suggestions(terms)
        }
    }

}
