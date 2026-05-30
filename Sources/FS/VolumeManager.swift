import Foundation
import AppKit

// MARK: - VolumeInfo

/// Metadata about a mounted volume (filesystem).
///
/// Categorized into local (internal SSD), external (USB/Thunderbolt), and
/// network (SMB/AFP/NFS) volumes. Used by VolumeManager to decide indexing
/// policy and by the daemon to manage volume lifecycle events.
struct VolumeInfo: Sendable, Equatable {
    /// Mount point path (e.g. "/", "/Volumes/USB Drive").
    let path: String

    /// Display name of the volume (e.g. "Macintosh HD", "USB Drive").
    let name: String

    /// True for removable volumes connected via USB or Thunderbolt.
    let isExternal: Bool

    /// True for network-mounted volumes (SMB, AFP, NFS, etc.).
    let isNetwork: Bool

    /// True if the volume can be ejected by the user.
    let isEjectable: Bool

    /// Total storage capacity in bytes.
    let totalSize: Int64

    /// Available storage in bytes.
    let availableSize: Int64
}

// MARK: - VolumeEvent

/// Events emitted by VolumeManager when volumes are mounted or unmounted.
enum VolumeEvent: Sendable, Equatable {
    /// A new volume has appeared in the filesystem.
    case mounted(VolumeInfo)
    /// A volume has been removed from the filesystem.
    case unmounted(path: String)
}

// MARK: - VolumeMonitor Protocol

/// Abstraction over volume monitoring. Production implementation uses
/// FileManager + NSWorkspace notifications; test implementations inject
/// events programmatically.
protocol VolumeMonitor: Sendable {
    /// Return the current list of mounted volumes.
    func mountedVolumes() -> [VolumeInfo]

    /// Return an async stream of volume mount/unmount events.
    func monitorVolumes() -> AsyncStream<VolumeEvent>
}

// MARK: - VolumeManager

/// Manages external and network volume indexing policy.
///
/// Responsibilities:
/// - Enumerate currently mounted volumes (local, external, network)
/// - Monitor for volume mount/unmount events
/// - Decide whether a given volume should be indexed based on configuration
/// - Coordinate index cleanup when volumes are unmounted
///
/// The actor uses a `VolumeMonitor` protocol for testability. Production
/// uses `SystemVolumeMonitor`; tests use `MockVolumeMonitor`.
actor VolumeManager {

    // MARK: - Dependencies

    private let monitor: VolumeMonitor

    // MARK: - Init

    /// Create a VolumeManager with the given monitor.
    ///
    /// - Parameter monitor: The volume monitor to use for enumerating and
    ///   watching volumes. Defaults to `SystemVolumeMonitor`.
    init(monitor: VolumeMonitor = SystemVolumeMonitor()) {
        self.monitor = monitor
    }

    // MARK: - Public API

    /// Return the current list of mounted volumes from the underlying monitor.
    func mountedVolumes() -> [VolumeInfo] {
        monitor.mountedVolumes()
    }

    /// Return an async stream of volume mount/unmount events.
    func monitorVolumes() -> AsyncStream<VolumeEvent> {
        monitor.monitorVolumes()
    }

    /// Determine whether a given volume should be indexed based on daemon config.
    ///
    /// Policy:
    /// - Local volumes (root "/"): always indexed
    /// - External volumes (USB/Thunderbolt): indexed by default, skippable via excludedVolumes
    /// - Network volumes (SMB/AFP/NFS): indexed by default, skippable via excludedVolumes
    /// - Any volume in excludedVolumes is never indexed
    func shouldIndex(volume: VolumeInfo, config: DaemonConfig) -> Bool {
        // Check exclusion list first
        if config.excludedVolumes.contains(volume.path) {
            return false
        }

        // Local root volume is always indexed
        if !volume.isExternal && !volume.isNetwork {
            return true
        }

        // External and network volumes are indexed by default unless excluded
        return true
    }
}

// MARK: - SystemVolumeMonitor

/// Production implementation of VolumeMonitor.
///
/// Uses `FileManager.mountedVolumeURLs` to enumerate volumes and
/// `URLResourceValues` to categorize each volume. Volume events are
/// monitored via NSWorkspace notifications.
final class SystemVolumeMonitor: VolumeMonitor {

    // MARK: - VolumeMonitor Conformance

    func mountedVolumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeIsReadOnlyKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
                .volumeIsEjectableKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey,
                .volumeIsLocalKey,
            ],
            options: []
        ) else {
            return []
        }

        return urls.compactMap { url -> VolumeInfo? in
            Self.volumeInfo(from: url)
        }
    }

    func monitorVolumes() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            // Store mounted volumes snapshot for diffing
            nonisolated(unsafe) var knownVolumes = Set(
                Self.currentMountPaths()
            )

            nonisolated(unsafe) var observers: [NSObjectProtocol] = []

            let mountedObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let volumeURL = notification.userInfo?["NSDevicePath"] as? String else { return }
                guard !knownVolumes.contains(volumeURL) else { return }
                knownVolumes.insert(volumeURL)

                let url = URL(fileURLWithPath: volumeURL)
                if let info = Self.volumeInfo(from: url) {
                    continuation.yield(.mounted(info))
                }
            }

            let unmountedObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let volumePath = notification.userInfo?["NSDevicePath"] as? String else { return }
                guard knownVolumes.contains(volumePath) else { return }
                knownVolumes.remove(volumePath)

                continuation.yield(.unmounted(path: volumePath))
            }

            let willUnmountObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.willUnmountNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let volumePath = notification.userInfo?["NSDevicePath"] as? String else { return }
                guard knownVolumes.contains(volumePath) else { return }
                knownVolumes.remove(volumePath)

                continuation.yield(.unmounted(path: volumePath))
            }

            observers = [mountedObserver, unmountedObserver, willUnmountObserver]

            continuation.onTermination = { _ in
                for observer in observers {
                    NotificationCenter.default.removeObserver(observer)
                }
                observers.removeAll()
            }
        }
    }

    // MARK: - Internal Helpers

    /// Get current mount point paths.
    private static func currentMountPaths() -> Set<String> {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) else {
            return []
        }
        return Set(urls.map(\.path))
    }

    /// Build a VolumeInfo from a file URL using resource values.
    private static func volumeInfo(from url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsReadOnlyKey,
        ]) else {
            return nil
        }

        let name = values.volumeName ?? url.lastPathComponent
        let isEjectable = values.volumeIsEjectable ?? false
        let isRemovable = values.volumeIsRemovable ?? false
        let isLocal = values.volumeIsLocal ?? true

        // Classification:
        // - External: removable but not network (USB, Thunderbolt)
        // - Network: not local
        // - Local: everything else (internal SSD)
        let isExternal = (isRemovable || isEjectable) && isLocal
        let isNetwork = !isLocal

        let totalSize = Int64(values.volumeTotalCapacity ?? 0)
        let availableSize = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)

        return VolumeInfo(
            path: url.path,
            name: name,
            isExternal: isExternal,
            isNetwork: isNetwork,
            isEjectable: isEjectable,
            totalSize: totalSize,
            availableSize: availableSize
        )
    }
}
