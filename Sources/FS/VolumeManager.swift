// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import AppKit
import DeepFinderIndex
import DeepFinderPersist

// MARK: - VolumeInfo

/// Metadata about a mounted volume (filesystem).
///
/// Categorized into local (internal SSD), external (USB/Thunderbolt), and
/// network (SMB/AFP/NFS) volumes. Used by VolumeManager to decide indexing
/// policy and by the daemon to manage volume lifecycle events.
public struct VolumeInfo: Sendable, Equatable {
    /// Mount point path (e.g. "/", "/Volumes/USB Drive").
    public let path: String

    /// Display name of the volume (e.g. "Macintosh HD", "USB Drive").
    public let name: String

    /// True for removable volumes connected via USB or Thunderbolt.
    public let isExternal: Bool

    /// True for network-mounted volumes (SMB, AFP, NFS, etc.).
    public let isNetwork: Bool

    /// True if the volume can be ejected by the user.
    public let isEjectable: Bool

    /// Total storage capacity in bytes.
    public let totalSize: Int64

    /// Available storage in bytes.
    public let availableSize: Int64
}

// MARK: - VolumeEvent

/// Events emitted by VolumeManager when volumes are mounted or unmounted.
public enum VolumeEvent: Sendable, Equatable {
    /// A new volume has appeared in the filesystem.
    case mounted(VolumeInfo)
    /// A volume has been removed from the filesystem.
    case unmounted(path: String)
}

// MARK: - VolumeMonitor Protocol

/// Abstraction over volume monitoring. Production implementation uses
/// FileManager + NSWorkspace notifications; test implementations inject
/// events programmatically.
///
/// Apple platforms only — relies on `FileManager.mountedVolumeURLs` and
/// `NSWorkspace` mount/unmount notifications which are not available on Linux.
public protocol VolumeMonitor: Sendable {
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
public actor VolumeManager {

    // MARK: - Dependencies

    private let monitor: VolumeMonitor

    // MARK: - Init

    /// Create a VolumeManager with the given monitor.
    ///
    /// - Parameter monitor: The volume monitor to use for enumerating and
    ///   watching volumes. Defaults to `SystemVolumeMonitor`.
    public init(monitor: VolumeMonitor = SystemVolumeMonitor()) {
        self.monitor = monitor
    }

    // MARK: - Public API

    /// Return the current list of mounted volumes from the underlying monitor.
    public func mountedVolumes() -> [VolumeInfo] {
        monitor.mountedVolumes()
    }

    /// Return an async stream of volume mount/unmount events.
    public func monitorVolumes() -> AsyncStream<VolumeEvent> {
        monitor.monitorVolumes()
    }

    /// Determine whether a given volume should be indexed.
    ///
    /// Policy: all volumes are indexed unless their path appears in `excludedVolumes`.
    /// External and network volumes are indexed by default (consistent with v2.0 behavior).
    public func shouldIndex(volume: VolumeInfo, excludedVolumes: Set<String>) -> Bool {
        !excludedVolumes.contains(volume.path)
    }
}

// MARK: - SystemVolumeMonitor

/// Production implementation of VolumeMonitor.
///
/// Uses `FileManager.mountedVolumeURLs` to enumerate volumes and
/// `URLResourceValues` to categorize each volume. Volume events are
/// monitored via NSWorkspace notifications.
public final class SystemVolumeMonitor: VolumeMonitor {

    public init() {}

    // MARK: - VolumeMonitor Conformance

    public func mountedVolumes() -> [VolumeInfo] {
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

    public func monitorVolumes() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            // Store mounted volumes snapshot for diffing.
            // Both `nonisolated(unsafe)` variables are only mutated from NotificationCenter
            // observers dispatched to `.main` queue (serial), so mutations are serialized
            // and no data race occurs in practice.
            nonisolated(unsafe) var knownVolumes = Set(
                Self.currentMountPaths()
            )

            nonisolated(unsafe) var observers: [NSObjectProtocol] = []

            let mountedObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { _ in
                // NSDevicePath was removed from userInfo circa macOS 10.6.
                // Diff against the current mount list to detect new volumes.
                let current = Self.currentMountPaths()
                let newVolumes = current.subtracting(knownVolumes)
                for path in newVolumes {
                    knownVolumes.insert(path)
                    let url = URL(fileURLWithPath: path)
                    if let info = Self.volumeInfo(from: url) {
                        continuation.yield(.mounted(info))
                    }
                }
            }

            let unmountedObserver = NotificationCenter.default.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { _ in
                let current = Self.currentMountPaths()
                let removedVolumes = knownVolumes.subtracting(current)
                for path in removedVolumes {
                    knownVolumes.remove(path)
                    continuation.yield(.unmounted(path: path))
                }
            }

            observers = [mountedObserver, unmountedObserver]

            continuation.onTermination = { _ in
                DispatchQueue.main.async {
                    observers.forEach { NotificationCenter.default.removeObserver($0) }
                    observers.removeAll()
                }
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
