/// # Daemon Module
///
/// The background daemon that holds the in-memory index and serves search queries
/// to CLI and GUI clients over a Unix domain socket.
///
/// ## Components
/// - ``DaemonMain`` -- lifecycle manager: startup sequence, signal handling, shutdown
/// - ``IPCServer`` -- Unix domain socket server handling client connections
/// - ``IPCClient`` -- client-side connector for CLI/GUI to communicate with the daemon
/// - ``IPCProtocol`` -- request/response types and framing helpers
/// - ``ConfigStore`` -- persistent JSON configuration with atomic writes
/// - ``LaunchAgent`` -- launchd plist management for auto-start on login
///
/// ## Data Flow
/// ```
/// CLI / GUI -> IPCClient -> Unix Socket -> IPCServer -> SearchCoordinator -> results
/// ```
///
/// ## Lifecycle
/// 1. Ensure data directory and subdirectories (~/.deep-finder, permissions 700)
/// 2. Atomically acquire PID file (O_CREAT|O_EXCL + flock)
/// 3. Load SQLite index, rebuild InMemoryIndex
/// 4. Start IPCServer
/// 5. Start FSEventWatcher
/// 6. Register SIGTERM/SIGINT handlers
/// 7. On shutdown: flush SQLite, save cursor, unlink PID + close fd + remove socket
import Darwin
import Foundation
import OSLog

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
public enum DaemonState: String, Sendable, Equatable {
    case starting
    case ready
    case live
    case shuttingDown
}

// MARK: - DaemonError

/// Errors thrown during daemon lifecycle operations.
public enum DaemonError: Error, CustomStringConvertible, Equatable {
    /// Another daemon instance is already running with the given PID.
    case alreadyRunning(pid: Int32)
    /// The data directory could not be created at the given path.
    case dataDirectoryCreationFailed(String)
    /// The PID file could not be written at the given path.
    case pidWriteFailed(String)

    public var description: String {
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
/// 2. Atomically acquire PID file (O_CREAT|O_EXCL + flock)
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
public actor DaemonMain {

    // MARK: - Properties

    /// Logger for daemon lifecycle events.
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "lifecycle")

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

    /// Background initial-scan task, if one was started. Cancelled on shutdown.
    private var backgroundScanTask: Task<Void, Never>?

    /// Event stream factory for dependency injection. Defaults to FSEventStreamImpl.
    private let eventStreamProvider: @Sendable () -> FileSystemEventStream

    /// File descriptor for the locked PID file. Held open for the daemon lifetime
    /// to maintain the `flock` advisory lock. `nil` until `acquirePIDFile` succeeds.
    private var pidFileDescriptor: Int32?

    /// Continuation that signals shutdown without polling. Created in `run()`,
    /// yielded to from `shutdown()`, consumed by `waitForShutdown()`.
    private var shutdownContinuation: AsyncStream<Void>.Continuation?

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

        // When dataDir is non-default (e.g., in tests), derive all paths from it
        // so tests get isolated PID/socket/DB and don't conflict with a real daemon.
        if dataDir == Product.dataDir {
            self.resolvedPidPath = Self.expandTilde(Product.pidPath)
            self.resolvedSocketPath = Self.expandTilde(Product.socketPath)
            self.resolvedDbPath = Self.expandTilde(Product.databasePath)
        } else {
            self.resolvedPidPath = resolved + "/session/daemon.pid"
            self.resolvedSocketPath = resolved + "/session/ipc.sock"
            self.resolvedDbPath = resolved + "/cache/index.db"
        }
    }

    /// Public no-arg convenience initializer for executable entry points.
    /// Uses default data directory and production FSEventStreamImpl internally.
    public init() {
        self.init(dataDir: Product.dataDir, installSignals: true)
    }

    // MARK: - Static Utilities

    /// Expand `~` in a path to the user's home directory.
    static func expandTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// Get the current process resident memory (RSS) in megabytes.
    ///
    /// Uses `task_info` with `MACH_TASK_BASIC_INFO` to read `resident_size`.
    /// Falls back to 0 if the call fails.
    static func processMemoryMB() -> Double {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    /// Ensure the data directory and all subdirectories exist with correct permissions.
    ///
    /// Creates the root directory (permissions 700) and standard subdirectories:
    /// `cache/`, `logs/`, `session/`. Intermediate directories are created as needed.
    /// - Throws: `DaemonError.dataDirectoryCreationFailed` if creation fails.
    static func ensureDataDir(_ path: String) throws {
        let resolved = expandTilde(path)
        let fm = FileManager.default

        // Create root directory
        if !fm.fileExists(atPath: resolved) {
            try fm.createDirectory(
                atPath: resolved,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Product.privateDirPermissions]
            )
        } else {
            // Ensure permissions are correct even if directory already exists
            try fm.setAttributes(
                [.posixPermissions: Product.privateDirPermissions],
                ofItemAtPath: resolved
            )
        }

        // Create standard subdirectories
        let subdirs = [
            expandTilde(Product.cacheDir),
            expandTilde(Product.logsDir),
            expandTilde(Product.sessionDir),
        ]
        for dir in subdirs {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(
                    atPath: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: Product.privateDirPermissions]
                )
            }
        }
    }

    /// Atomically acquire the PID file for singleton enforcement.
    ///
    /// Uses `O_CREAT | O_EXCL` for atomic creation — if two daemon processes start
    /// simultaneously, exactly one will succeed and the other will see `EEXIST`
    /// and detect the live daemon. This eliminates the TOCTOU race between the
    /// old `checkExistingDaemon` → `writePIDFile` sequence.
    ///
    /// After creating the file, writes the current PID and acquires an advisory
    /// `flock(LOCK_EX | LOCK_NB)` lock. The returned file descriptor must be kept
    /// open for the daemon lifetime; the lock is released on close or process exit.
    ///
    /// Stale PID files (from a crashed daemon) are detected via `kill(pid, 0)` and
    /// automatically cleaned up before retrying.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    /// - Returns: A locked file descriptor for the PID file.
    /// - Throws: `DaemonError.alreadyRunning` if a live daemon already owns the file.
    /// - Throws: `DaemonError.pidWriteFailed` on I/O errors.
    static func acquirePIDFile(pidPath: String) throws -> Int32 {
        let flags: Int32 = O_CREAT | O_EXCL | O_WRONLY
        let mode: mode_t = mode_t(Product.pidFilePermissions)

        while true {
            let fd = open(pidPath, flags, mode)

            if fd != -1 {
                // Successfully created file exclusively — write PID and lock
                return try finalizePIDFileDescriptor(fd, at: pidPath)
            }

            guard errno == EEXIST else {
                throw DaemonError.pidWriteFailed(pidPath)
            }

            // File already exists — read PID and check if that process is alive
            guard let existingPID = readPID(from: pidPath) else {
                // Corrupted PID file — remove and retry
                unlink(pidPath)
                continue
            }

            if kill(existingPID, 0) == 0 {
                // Process is alive — another daemon is running
                throw DaemonError.alreadyRunning(pid: existingPID)
            }

            // Stale PID file from a crashed daemon — remove and retry
            unlink(pidPath)
        }
    }

    /// Write PID and acquire `flock` on an already-created PID file descriptor.
    ///
    /// On failure the file descriptor is closed and the file is unlinked.
    ///
    /// - Parameters:
    ///   - fd: File descriptor returned by `open(..., O_CREAT | O_EXCL)`.
    ///   - path: Absolute path to the PID file (for cleanup on error).
    /// - Returns: The same file descriptor, with PID written and lock held.
    /// - Throws: `DaemonError.pidWriteFailed` on write or lock failure.
    private static func finalizePIDFileDescriptor(_ fd: Int32, at path: String) throws -> Int32 {
        func cleanup() {
            close(fd)
            unlink(path)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let pidString = "\(pid)\n"
        guard let data = pidString.data(using: .utf8) else {
            cleanup()
            throw DaemonError.pidWriteFailed(path)
        }

        let written = data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            return write(fd, base, data.count)
        }
        guard written == data.count else {
            cleanup()
            throw DaemonError.pidWriteFailed(path)
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            cleanup()
            throw DaemonError.pidWriteFailed(path)
        }

        return fd
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
    public func run() async throws {
        // 1. Ensure data directory and subdirectories
        try Self.ensureDataDir(dataDir)
        try Self.ensureDataDir(resolvedDataDir + "/session")
        try Self.ensureDataDir(resolvedDataDir + "/cache")

        // 2. Atomically acquire PID file (singleton check + write + flock)
        let pidFD = try Self.acquirePIDFile(pidPath: resolvedPidPath)
        self.pidFileDescriptor = pidFD

        // 3. Load persistence layer
        let persistence = try IndexPersistence(dbPath: resolvedDbPath)
        self.persistence = persistence

        // 4. Load records and rebuild in-memory index
        let index = InMemoryIndex()
        self.index = index
        let records = try await persistence.loadAllRecords()
        for record in records {
            await index.insert(record)
        }

        // 5. Create SearchCoordinator
        let fileProvider = FileIndexProvider(index: index)
        await fileProvider.prepare()
        let coordinator = SearchCoordinator(providers: [fileProvider])
        self.coordinator = coordinator

        // 6. Start IPCServer
        let startTime = Date()
        let capturedIndex = index
        let capturedState: @Sendable () async -> DaemonState = { [weak self = self] in
            await self?._state ?? .starting
        }
        let statsProvider: @Sendable () async -> DaemonStats = {
            let fileCount = await capturedIndex.count
            let memoryMB = Self.processMemoryMB()
            return DaemonStats(
                totalFiles: fileCount,
                indexState: (await capturedState()).rawValue,
                uptimeSeconds: Date().timeIntervalSince(startTime),
                memoryUsageMB: memoryMB
            )
        }
        let indexStatusProvider: @Sendable () async -> DaemonIndexStatus = {
            let fileCount = await capturedIndex.count
            let state = await capturedState()
            return DaemonIndexStatus(
                state: state.rawValue,
                filesIndexed: fileCount,
                lastScanDate: nil
            )
        }

        let suggestProvider: @Sendable (String) async -> [String] = {
            let results = await capturedIndex.search(query: $0)
            return Array(results.prefix(5).map(\.name))
        }

        // ConfigStore for IPC config_get/config_set (REQ-0.4-05)
        let configStore = ConfigStore(configPath: resolvedDataDir + "/settings.json")

        let configGetProvider: @Sendable (String?) async -> String? = { key in
            if let key {
                return await configStore.get(key: key)
            }
            // nil key = list all config as JSON
            let config = await configStore.get()
            return (try? JSONEncoder().encode([
                "excludedPaths": (try? JSONEncoder().encode(config.excludedPaths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
                "excludedVolumes": (try? JSONEncoder().encode(config.excludedVolumes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
                "indexBatchSize": String(config.indexBatchSize),
                "maxResults": String(config.maxResults),
                "configVersion": String(config.configVersion),
            ] as [String: String])).flatMap { String(data: $0, encoding: .utf8) }
        }
        let configSetProvider: @Sendable (String, String) async -> Void = { key, value in
            try? await configStore.set(key: key, value: value)
        }

        let ipcServer = IPCServer(
            socketPath: resolvedSocketPath,
            coordinator: coordinator,
            statsProvider: statsProvider,
            indexStatusProvider: indexStatusProvider,
            suggestProvider: suggestProvider,
            configGetProvider: configGetProvider,
            configSetProvider: configSetProvider
        )
        try await ipcServer.start()
        self.ipcServer = ipcServer

        _state = .ready

        // 7. Start FSEventWatcher (uses injected event stream)
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

        // 8. Background initial scan on first run (empty index)
        if records.isEmpty {
            let bgIndex = index
            let bgPersistence = persistence
            backgroundScanTask = Task.detached {
                let scanner = FileScanner()
                let homeDir = NSHomeDirectory()
                let scanStream = await scanner.scan(
                    rootPaths: [homeDir],
                    config: ScanConfiguration(maxDepth: Constants.Scan.defaultMaxDepth)
                )
                var scannedCount = 0
                for await event in scanStream {
                    // Respect cancellation (daemon shutting down)
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .fileFound(let record):
                        await bgIndex.insert(record)
                        scannedCount += 1
                    case .scanComplete:
                        let allRecords = await bgIndex.allRecords()
                        await bgPersistence.saveRecords(allRecords)
                        let log = Logger(subsystem: Product.daemonSubsystem, category: "lifecycle")
                        log.info("Initial scan complete: \(scannedCount) files indexed, \(allRecords.count) total")
                    case .scanError(let error):
                        let log = Logger(subsystem: Product.daemonSubsystem, category: "lifecycle")
                        log.warning("Background scan error at \(error.path, privacy: .public): \(error.reason, privacy: .public)")
                    default:
                        break
                    }
                }
            }
        }

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

        // Cancel background initial scan if still running
        backgroundScanTask?.cancel()
        backgroundScanTask = nil

        // Stop file watcher (saves cursor)
        await watcher?.stopWatching()
        watcher = nil

        // Flush SQLite
        do { try await persistence?.flush() }
        catch { logger.warning("Failed to flush persistence during shutdown: \(error.localizedDescription, privacy: .public)") }

        // Remove PID file (unlink first so path is freed, then close releases flock)
        _ = unlink(resolvedPidPath)
        if let fd = pidFileDescriptor {
            close(fd)
            pidFileDescriptor = nil
        }

        // Socket file is already removed by IPCServer.stop()

        // Cancel signal sources
        sigtermSource?.cancel()
        sigtermSource = nil
        sigintSource?.cancel()
        sigintSource = nil

        // Signal the waitForShutdown() stream to wake and return
        shutdownContinuation?.yield(())
        shutdownContinuation?.finish()
        shutdownContinuation = nil
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
        let queue = DispatchQueue(label: "\(Product.identifier).daemon.signals")

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

    /// Wait for the daemon to receive a shutdown signal.
    ///
    /// Uses an AsyncStream continuation instead of a polling loop.
    /// The continuation is stored in `shutdownContinuation`, yielded to from
    /// `shutdown()`, and consumed here. This eliminates the 100ms polling
    /// overhead and wakes immediately on shutdown.
    private func waitForShutdown() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.shutdownContinuation = continuation
        for await _ in stream {}
    }
}
