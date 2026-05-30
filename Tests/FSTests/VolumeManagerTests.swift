import Testing
import Foundation
@testable import DeepFinder

@Suite("VolumeManager")
struct VolumeManagerTests {

    // MARK: - Helpers

    /// Create a VolumeManager with a mock monitor for deterministic testing.
    private func makeManager(
        volumes: [VolumeInfo] = [],
        events: [VolumeEvent] = []
    ) -> (manager: VolumeManager, monitor: MockVolumeMonitor) {
        let monitor = MockVolumeMonitor(volumes: volumes, events: events)
        let manager = VolumeManager(monitor: monitor)
        return (manager, monitor)
    }

    /// A sample local root volume.
    private var localVolume: VolumeInfo {
        VolumeInfo(
            path: "/",
            name: "Macintosh HD",
            isExternal: false,
            isNetwork: false,
            isEjectable: false,
            totalSize: 1_000_000_000_000,
            availableSize: 500_000_000_000
        )
    }

    /// A sample external USB volume.
    private var externalVolume: VolumeInfo {
        VolumeInfo(
            path: "/Volumes/USB Drive",
            name: "USB Drive",
            isExternal: true,
            isNetwork: false,
            isEjectable: true,
            totalSize: 128_000_000_000,
            availableSize: 64_000_000_000
        )
    }

    /// A sample network SMB volume.
    private var networkVolume: VolumeInfo {
        VolumeInfo(
            path: "/Volumes/shared",
            name: "shared",
            isExternal: false,
            isNetwork: true,
            isEjectable: false,
            totalSize: 2_000_000_000_000,
            availableSize: 1_000_000_000_000
        )
    }

    // MARK: - Tests

    @Test("List mounted volumes returns all volumes from monitor")
    func testListMountedVolumes() async {
        let volumes = [localVolume, externalVolume, networkVolume]
        let (manager, _) = makeManager(volumes: volumes)

        let result = await manager.mountedVolumes()

        #expect(result.count == 3)
        #expect(result.contains { $0.path == "/" })
        #expect(result.contains { $0.path == "/Volumes/USB Drive" })
        #expect(result.contains { $0.path == "/Volumes/shared" })
    }

    @Test("External volume detected correctly")
    func testExternalVolumeDetection() async {
        let vol = externalVolume
        #expect(vol.isExternal == true)
        #expect(vol.isNetwork == false)
        #expect(vol.isEjectable == true)
        #expect(vol.name == "USB Drive")
        #expect(vol.path == "/Volumes/USB Drive")
    }

    @Test("Network volume detected correctly")
    func testNetworkVolumeDetection() async {
        let vol = networkVolume
        #expect(vol.isExternal == false)
        #expect(vol.isNetwork == true)
        #expect(vol.isEjectable == false)
        #expect(vol.name == "shared")
        #expect(vol.path == "/Volumes/shared")
    }

    @Test("shouldIndex: local volume always indexed")
    func testShouldIndexLocalAlways() async {
        let (manager, _) = makeManager(volumes: [localVolume])
        let config = DaemonConfig.defaults

        let result = await manager.shouldIndex(volume: localVolume, config: config)
        #expect(result == true)
    }

    @Test("shouldIndex: external volume indexed by default")
    func testShouldIndexExternalByDefault() async {
        let (manager, _) = makeManager(volumes: [externalVolume])
        let config = DaemonConfig.defaults

        let result = await manager.shouldIndex(volume: externalVolume, config: config)
        #expect(result == true)
    }

    @Test("shouldIndex: excluded volume skipped")
    func testShouldIndexExcludedSkipped() async {
        let (manager, _) = makeManager(volumes: [externalVolume])
        var config = DaemonConfig.defaults
        config.excludedVolumes = ["/Volumes/USB Drive"]

        let result = await manager.shouldIndex(volume: externalVolume, config: config)
        #expect(result == false)
    }

    @Test("Volume unmount removes records from index")
    func testVolumeUnmountRemovesRecords() async throws {
        let index = InMemoryIndex()

        // Insert records on two different volumes
        await index.insert(
            name: "local.txt",
            path: "/Users/test/local.txt",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 10,
            extension: "txt"
        )
        await index.insert(
            name: "usb-file.txt",
            path: "/Volumes/USB Drive/docs/usb-file.txt",
            parentPath: "/Volumes/USB Drive/docs",
            isDirectory: false,
            size: 20,
            extension: "txt"
        )
        await index.insert(
            name: "usb-dir",
            path: "/Volumes/USB Drive/docs",
            parentPath: "/Volumes/USB Drive",
            isDirectory: true
        )

        // Verify 3 records in index
        let countBefore = await index.count
        #expect(countBefore == 3)

        // Remove all records for the USB volume
        let removedIDs = await index.removeRecordsForVolume(volumePath: "/Volumes/USB Drive")
        #expect(removedIDs.count == 2)

        // Only the local file should remain
        let countAfter = await index.count
        #expect(countAfter == 1)

        // The remaining record should be the local one
        let remaining = await index.allRecords()
        #expect(remaining.count == 1)
        #expect(remaining[0].name == "local.txt")
    }

    @Test("Volume mount event triggers scan via AsyncStream")
    func testVolumeMountTriggersScan() async {
        let mountEvent = VolumeEvent.mounted(externalVolume)
        let (manager, monitor) = makeManager(volumes: [], events: [mountEvent])

        let stream = await manager.monitorVolumes()

        // Feed the mount event
        monitor.emitPendingEvents()

        // Collect first event from the stream
        var receivedEvent: VolumeEvent?
        for await event in stream {
            receivedEvent = event
            break
        }

        #expect(receivedEvent != nil)
        switch receivedEvent {
        case .mounted(let vol):
            #expect(vol.path == "/Volumes/USB Drive")
            #expect(vol.isExternal == true)
        case .unmounted:
            Issue.record("Expected mounted event, got unmounted")
        case nil:
            Issue.record("No event received")
        }
    }
}

// MARK: - Test Double

/// Mock implementation of VolumeMonitor for deterministic testing.
///
/// `@unchecked Sendable` because all mutable state is accessed only from
/// the test thread (synchronous test harness, no real concurrency).
final class MockVolumeMonitor: VolumeMonitor, @unchecked Sendable {

    private let _volumes: [VolumeInfo]
    private var pendingEvents: [VolumeEvent] = []
    private var continuation: AsyncStream<VolumeEvent>.Continuation?

    init(volumes: [VolumeInfo], events: [VolumeEvent] = []) {
        self._volumes = volumes
        self.pendingEvents = events
    }

    func mountedVolumes() -> [VolumeInfo] {
        _volumes
    }

    func monitorVolumes() -> AsyncStream<VolumeEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.continuation = nil
            }
        }
    }

    /// Emit all pending events to the continuation. Used by tests to
    /// simulate volume mount/unmount after the stream is consumed.
    func emitPendingEvents() {
        for event in pendingEvents {
            continuation?.yield(event)
        }
        pendingEvents = []
    }

    /// Inject a single event into the stream.
    func inject(_ event: VolumeEvent) {
        continuation?.yield(event)
    }
}
