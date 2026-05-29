import Foundation

// MARK: - DaemonState

/// Lifecycle state of the daemon process.
///
/// ```
/// starting → ready → live → shuttingDown
/// ```
///
/// State transitions are one-way. The daemon starts in `starting`, moves to
/// `ready` once IPC is listening, `live` once FSEventWatcher is active, and
/// `shuttingDown` when a termination signal is received.
enum DaemonState: String, Sendable, Equatable {
    case starting
    case ready
    case live
    case shuttingDown
}

// MARK: - DaemonError

enum DaemonError: Error, CustomStringConvertible, Equatable {
    case alreadyRunning(pid: Int32)
    case dataDirectoryCreationFailed(String)
    case pidWriteFailed(String)

    var description: String {
        switch self {
        case .alreadyRunning(let pid):
            return "Daemon already running (PID \(pid))"
        case .dataDirectoryCreationFailed(let path):
            return "Failed to create data directory: \(path)"
        case .pidWriteFailed(let path):
            return "Failed to write PID file: \(path)"
        }
    }
}

// MARK: - DaemonMain

/// Entry point and lifecycle manager for the DeepFinder daemon.
///
/// Orchestrates the startup sequence:
/// 1. Ensure data directory exists (permissions 700)
/// 2. Check for existing daemon (singleton via PID file)
/// 3. Load SQLite index -> rebuild InMemoryIndex
/// 4. Start IPCServer (Unix domain socket)
/// 5. Start FSEventWatcher
/// 6. Register signal handlers (SIGTERM / SIGINT)
///
/// On shutdown (signal or explicit `shutdown()`):
/// 1. Stop IPCServer
/// 2. Stop FSEventWatcher (saves cursor)
/// 3. Flush SQLite
/// 4. Remove PID file
/// 5. Remove socket file
///
/// Thread-safe via actor isolation.
actor DaemonMain {

    // MARK: - Properties

    /// Root data directory (e.g. ~/.deep-finder).
    private let dataDir: String

    /// Current lifecycle state.
    private var _state: DaemonState = .starting

    /// Resolved (tilde-expanded) paths.
    private let resolvedDataDir: String
    private let resolvedPidPath: String
    private let resolvedSocketPath: String
    private let resolvedDbPath: String

    /// Component references. Created during `run()`.
    private var persistence: IndexPersistence?
    private var index: InMemoryIndex?
    private var coordinator: SearchCoordinator?
    private var ipcServer: IPCServer?
    private var watcher: FSEventWatcher?

    /// Signal source for SIGTERM.
    private var sigtermSource: DispatchSourceSignal?
    /// Signal source for SIGINT.
    private var sigintSource: DispatchSourceSignal?

    /// Whether shutdown has been initiated (prevents double-shutdown).
    private var isShuttingDown = false

    /// Whether to install signal handlers during `run()`. Disabled in tests.
    private let installSignals: Bool

    /// Event stream factory for dependency injection. Defaults to FSEventStreamImpl.
    private let eventStreamProvider: @Sendable () -> FileSystemEventStream

    // MARK: - Public Accessors

    /// Current daemon lifecycle state.
    var state: DaemonState {
        _state
    }

    // MARK: - Init

    /// Create a new DaemonMain with the given data directory.
    ///
    /// - Parameters:
    ///   - dataDir: Path to the data directory. Supports `~` expansion.
    ///     Default is `Product.dataDir` (`~/.deep-finder`).
    ///   - installSignals: Whether to install SIGTERM/SIGINT handlers.
    ///     Set to `false` in tests. Default is `true`.
    ///   - eventStreamProvider: Factory for creating the FileSystemEventStream.
    ///     Defaults to `FSEventStreamImpl`. Inject `MockEventStream` in tests.
    init(
        dataDir: String = Product.dataDir,
        installSignals: Bool = true,
        eventStreamProvider: @escaping @Sendable () -> FileSystemEventStream = { FSEventStreamImpl() }
    ) {
        self.dataDir = dataDir
        self.installSignals = installSignals
        self.eventStreamProvider = eventStreamProvider
        let resolved = Self.expandTilde(dataDir)
        self.resolvedDataDir = resolved
        self.resolvedPidPath = (resolved as NSString).appendingPathComponent("daemon.pid")
        self.resolvedSocketPath = (resolved as NSString).appendingPathComponent("ipc.sock")
        self.resolvedDbPath = (resolved as NSString).appendingPathComponent("index.db")
    }

    // MARK: - Static Utilities

    /// Expand `~` in a path to the user's home directory.
    static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// Ensure the data directory exists with permissions 700.
    ///
    /// Creates the directory and all intermediate directories if needed.
    /// - Throws: `DaemonError.dataDirectoryCreationFailed` if creation fails.
    static func ensureDataDir(_ path: String) throws {
        let resolved = expandTilde(path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: resolved) {
            try fm.createDirectory(
                atPath: resolved,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            // Ensure permissions are correct even if directory already exists
            try fm.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: resolved
            )
        }
    }

    /// Write the current process PID to the given file path.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    /// - Throws: `DaemonError.pidWriteFailed` if the file cannot be written.
    static func writePIDFile(pidPath: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = (pidPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // Ensure parent directory exists
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let pidString = "\(pid)\n"
        guard let data = pidString.data(using: .utf8) else {
            throw DaemonError.pidWriteFailed(pidPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: pidPath), options: .atomic)
        } catch {
            throw DaemonError.pidWriteFailed(pidPath)
        }
    }

    /// Check whether another daemon instance is already running.
    ///
    /// Reads the PID file at `pidPath`. If the file exists and the process
    /// with that PID is alive, returns `true`. If the file exists but the
    /// process is dead (stale PID file), cleans up the file and returns `false`.
    /// If the file does not exist, returns `false`.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    /// - Returns: `true` if a live daemon is already running.
    static func checkExistingDaemon(pidPath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pidPath) else {
            return false
        }

        // Read PID from file
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let pidString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else {
            // Corrupted PID file -- remove it
            try? fm.removeItem(atPath: pidPath)
            return false
        }

        // Check if the process is alive (signal 0 = existence check)
        let result = kill(pid, 0)
        if result == 0 {
            return true
        }

        // Process doesn't exist -- stale PID file, clean it up
        try? fm.removeItem(atPath: pidPath)
        return false
    }

    // MARK: - Lifecycle

    /// Run the daemon's main lifecycle.
    ///
    /// This method performs the full startup sequence and then suspends,
    /// waiting for a shutdown signal. It returns when shutdown is complete.
    ///
    /// - Throws: `DaemonError` on startup failures.
    func run() async throws {
        // 1. Ensure data directory
        try Self.ensureDataDir(dataDir)

        // 2. Singleton check
        guard !Self.checkExistingDaemon(pidPath: resolvedPidPath) else {
            let pid = Self.readPID(from: resolvedPidPath) ?? -1
            throw DaemonError.alreadyRunning(pid: pid)
        }

        // 3. Write PID file
        try Self.writePIDFile(pidPath: resolvedPidPath)

        // 4. Load persistence layer
        let persistence = try IndexPersistence(dbPath: resolvedDbPath)
        self.persistence = persistence

        // 5. Load records and rebuild in-memory index
        let index = InMemoryIndex()
        self.index = index
        let records = try await persistence.loadAllRecords()
        for record in records {
            await index.insert(record)
        }

        // 6. Create SearchCoordinator
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])
        self.coordinator = coordinator

        // 7. Start IPCServer
        let startTime = Date()
        let statsProvider: @Sendable () -> DaemonStats = {
            DaemonStats(
                totalFiles: 0,
                indexState: "live",
                uptimeSeconds: Date().timeIntervalSince(startTime),
                memoryUsageMB: 0
            )
        }

        let ipcServer = IPCServer(
            socketPath: resolvedSocketPath,
            coordinator: coordinator,
            statsProvider: statsProvider
        )
        try await ipcServer.start()
        self.ipcServer = ipcServer

        _state = .ready

        // 8. Start FSEventWatcher (uses injected event stream)
        let eventStream = eventStreamProvider()
        let cursor = await persistence.loadEventCursor()
        let watcher = FSEventWatcher(
            eventStream: eventStream,
            index: index,
            persistence: persistence
        )
        self.watcher = watcher
        try await watcher.startWatching(
            paths: ["/"],
            sinceEventID: cursor ?? 0
        )

        _state = .live

        // 9. Register signal handlers (production only)
        if installSignals {
            installSignalHandlers()
        }

        // 10. Suspend -- wait for shutdown signal
        await waitForShutdown()
    }

    /// Initiate graceful shutdown.
    ///
    /// Safe to call multiple times -- subsequent calls are no-ops.
    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        _state = .shuttingDown

        // Stop accepting new IPC connections
        await ipcServer?.stop()
        ipcServer = nil

        // Stop file watcher (saves cursor)
        await watcher?.stopWatching()
        watcher = nil

        // Flush SQLite
        try? await persistence?.flush()

        // Remove PID file
        try? FileManager.default.removeItem(atPath: resolvedPidPath)

        // Socket file is already removed by IPCServer.stop()

        // Cancel signal sources
        sigtermSource?.cancel()
        sigtermSource = nil
        sigintSource?.cancel()
        sigintSource = nil
    }

    // MARK: - Internal

    /// Read PID from file, returning nil on any failure.
    private static func readPID(from path: String) -> Int32? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let str = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(str) else {
            return nil
        }
        return pid
    }

    /// Install DispatchSourceSignal handlers for SIGTERM and SIGINT.
    ///
    /// When triggered, these call `shutdown()` on the daemon. The handlers
    /// run on a dedicated serial queue to avoid blocking the main queue.
    private func installSignalHandlers() {
        let queue = DispatchQueue(label: "com.nadav.deepfinder.daemon.signals")

        // SIGTERM
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        signal(SIGTERM, SIG_IGN)
        termSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.shutdown()
            }
        }
        termSource.resume()
        self.sigtermSource = termSource

        // SIGINT
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        signal(SIGINT, SIG_IGN)
        intSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.shutdown()
            }
        }
        intSource.resume()
        self.sigintSource = intSource
    }

    /// Wait for the daemon to enter `shuttingDown` state.
    ///
    /// Polls at a reasonable interval. In production, the daemon would use
    /// `DispatchMain()` or `NSRunLoop`, but in our actor-based model we
    /// use a simple async poll loop that yields to the cooperative thread pool.
    private func waitForShutdown() async {
        while _state != .shuttingDown {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
}
