import Foundation
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - IndexHealthState

/// Typed representation of the daemon's index health state.
///
/// Combines the daemon-reported index status with local permission checks
/// to produce a unified health state that the UI can observe.
public enum IndexHealthState: Sendable, Equatable {
    /// Index is fully built and FSEventWatcher is active.
    case live(filesIndexed: Int, lastScanDate: Date?)
    /// Index is currently being built or verified.
    case indexing(filesIndexed: Int)
    /// Index health is degraded — user action required.
    case degraded(reason: DegradationReason)
    /// State could not be determined (daemon not reachable, etc.).
    case unknown
}

// MARK: - DegradationReason

/// Specific reason for degraded index health.
public enum DegradationReason: Sendable, Equatable {
    /// Full Disk Access is not granted — some directories silently skipped.
    case fdaMissing
    /// Daemon is not running or IPC connection lost.
    case daemonDisconnected
    /// Index state is stale but daemon is reachable.
    case indexStale
}

// MARK: - IndexHealthMonitor

/// Polls the daemon's index status at a configurable interval and publishes
/// a typed health state.
///
/// Combines `DaemonIndexStatus` (from IPC) with `PermissionChecker.isFDAGranted()`
/// to detect degraded states like FDA missing. The UI observes `healthState` to
/// show/hide health banners and progress indicators.
///
/// Accepts `IPCClientProtocol` via init for testability.
@MainActor
@Observable
public final class IndexHealthMonitor {

    // MARK: - Published State

    /// Current index health state, updated by the polling loop.
    private(set) var healthState: IndexHealthState = .unknown

    /// The most recent raw daemon stats, if available.
    private(set) var daemonStats: DaemonStats?

    // MARK: - Dependencies

    /// IPC client for querying the daemon. Optional — if nil, polling yields `.unknown`.
    private let ipcClient: (any IPCClientProtocol)?

    /// Polling interval while indexing (active progress updates).
    private static let activeInterval: TimeInterval = 5

    /// Polling interval when live or degraded (reduced IPC traffic).
    private static let idleInterval: TimeInterval = 30

    /// Task holding the active polling loop.
    /// `nonisolated(unsafe)` because `Task.cancel()` is safe to call from any context
    /// (including nonisolated `deinit`).
    private nonisolated(unsafe) var pollingTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates an index health monitor.
    ///
    /// - Parameters:
    ///   - ipcClient: IPC client for daemon queries. Pass `nil` in previews/tests.
    ///   - pollingInterval: Ignored — kept for backward compatibility. Polling is adaptive.
    public init(
        ipcClient: (any IPCClientProtocol)?,
        pollingInterval: TimeInterval = 5
    ) {
        self.ipcClient = ipcClient
    }

    // MARK: - Lifecycle

    /// Starts the polling loop. Safe to call multiple times — stops previous loop first.
    ///
    /// Uses adaptive intervals: 5s while indexing, 30s when live or degraded.
    public func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshState()
                let interval = self?.currentInterval ?? Self.activeInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stops the polling loop.
    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Manually triggers a single state refresh. Useful for immediate UI updates.
    public func refreshNow() async {
        await refreshState()
    }

    // MARK: - Private

    /// Adaptive polling interval based on current health state.
    private var currentInterval: TimeInterval {
        switch healthState {
        case .indexing:
            return Self.activeInterval
        default:
            return Self.idleInterval
        }
    }

    /// Queries the daemon and updates `healthState`.
    private func refreshState() async {
        guard let ipcClient else {
            healthState = .unknown
            return
        }

        // Query both stats and index status in parallel.
        async let statsResponse = try? ipcClient.send(.stats)
        async let indexStatusResponse = try? ipcClient.send(.indexStatus)

        let stats = await statsResponse
        let indexStatus = await indexStatusResponse

        // Extract daemon stats.
        if let stats, case .stats(let daemonStats) = stats {
            self.daemonStats = daemonStats
        }

        // Extract index status.
        guard let indexStatus, case .indexStatus(let status) = indexStatus else {
            // Could not reach daemon.
            if !PermissionChecker.isFDAGranted() {
                healthState = .degraded(reason: .fdaMissing)
            } else {
                healthState = .degraded(reason: .daemonDisconnected)
            }
            return
        }

        // Check FDA first — overrides everything else.
        if !PermissionChecker.isFDAGranted() {
            healthState = .degraded(reason: .fdaMissing)
            return
        }

        // Map daemon state string to typed state.
        let stateString = status.state.lowercased()
        switch stateString {
        case "live":
            healthState = .live(
                filesIndexed: status.filesIndexed,
                lastScanDate: status.lastScanDate
            )
        case "verifying", "indexing", "polling":
            healthState = .indexing(filesIndexed: status.filesIndexed)
        case "stale":
            healthState = .degraded(reason: .indexStale)
        default:
            healthState = .unknown
        }
    }

    // deinit is nonisolated — Task cancellation is safe to call from any context.
    // The pollingTask itself is actor-isolated but `cancel()` is safe to call
    // from nonisolated deinit in Swift 6 concurrency.
    deinit {
        pollingTask?.cancel()
    }
}
