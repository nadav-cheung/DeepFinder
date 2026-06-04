import Testing
import Foundation
@testable import DeepFinder

@Suite("Daemon lifecycle management (REQ-0.4-04)")
struct LifecycleTests {

    // MARK: - Helpers

    /// Create a unique temp directory for each test.
    /// Paths stay short because sockaddr_un.sun_path is limited to ~104 chars.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-lc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Socket path inside the temp directory.
    private func socketPath(in dir: URL) -> String {
        dir.appendingPathComponent("s").path
    }

    // MARK: - 1. IPCClient connect and disconnect

    @Test("IPCClient connects to a running server and disconnects cleanly")
    func testConnectDisconnect() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sockPath = socketPath(in: dir)
        let coordinator = SearchCoordinator(providers: [])
        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)

        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000) // let accept loop start

        let client = IPCClient(socketPath: sockPath)
        try await client.connect()
        #expect(await client.isConnected)

        await client.disconnect()
        #expect(!(await client.isConnected))

        await server.stop()
    }

    // MARK: - 2. IPCClient sends query and receives results

    @Test("IPCClient sends query and receives results through server")
    func testSendQueryRoundTrip() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = FileRecord(
            id: 42,
            name: "lifecycle.txt",
            originalName: "lifecycle.txt",
            path: "/tmp/lifecycle.txt",
            parentPath: "/tmp",
            isDirectory: false,
            size: 200,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
        let result = SearchResult(record: record, providerID: "test", score: 1.0, matchType: .exact)
        let provider = MockSearchProvider(results: [result])
        let coordinator = SearchCoordinator(providers: [provider])

        let sockPath = socketPath(in: dir)
        let server = IPCServer(socketPath: sockPath, coordinator: coordinator)
        try await server.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = IPCClient(socketPath: sockPath)
        try await client.connect()

        let response = try await client.send(.query("lifecycle", limit: nil))
        switch response {
        case .results(let results, let queryID):
            #expect(results.count == 1)
            #expect(results[0].record.name == "lifecycle.txt")
            #expect(!queryID.isEmpty)
        case .error(let err):
            Issue.record("Expected results but got error: \(err)")
        default:
            Issue.record("Unexpected response type")
        }

        await client.disconnect()
        await server.stop()
    }

    // MARK: - 3. Safe disconnect when not connected

    @Test("Disconnect on unconnected client is a safe no-op")
    func testSafeDisconnectWhenNotConnected() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sockPath = socketPath(in: dir)
        let client = IPCClient(socketPath: sockPath)

        // Not connected — should not crash
        await client.disconnect()
        #expect(!(await client.isConnected))
    }

    // MARK: - 4. Send to non-existent socket throws

    @Test("Send to non-existent socket throws an error")
    func testSendToNonExistentSocket() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sockPath = socketPath(in: dir)
        let client = IPCClient(socketPath: sockPath)

        do {
            try await client.send(.stats)
            Issue.record("Expected an error when sending to non-existent socket")
        } catch {
            // Expected — connection refused or similar
        }
    }

    // MARK: - 5. isDaemonRunning returns false for stale PID

    @Test("isDaemonRunning returns false and cleans up stale PID file")
    func testIsDaemonRunningStalePID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path

        // Write a PID that definitely doesn't exist
        try "99999999\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pidPath))

        let running = IPCClient.isDaemonRunning(pidPath: pidPath)
        #expect(!running)
        // Stale PID file should be cleaned up
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - 6. isDaemonRunning returns false when no PID file

    @Test("isDaemonRunning returns false when PID file does not exist")
    func testIsDaemonRunningNoPIDFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path
        let running = IPCClient.isDaemonRunning(pidPath: pidPath)
        #expect(!running)
    }

    // MARK: - 7. cleanupStalePID removes stale PID file

    @Test("cleanupStalePID removes file when process is dead")
    func testCleanupStalePID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path

        // Write stale PID
        try "99999999\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pidPath))

        IPCClient.cleanupStalePID(pidPath: pidPath)
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - 8. LaunchAgent plist generation contains required keys

    @Test("LaunchAgent plist generation contains all required keys")
    func testLaunchAgentPlistGeneration() throws {
        let plist = LaunchAgent.generatePlist()

        // Must contain the label
        #expect(plist.contains(Product.identifier))
        // Must contain the program key (deepfinder daemon)
        #expect(plist.contains("Program"))
        // Must contain RunAtLoad
        #expect(plist.contains("RunAtLoad"))
        // Must contain KeepAlive
        #expect(plist.contains("KeepAlive"))
        // Must be valid plist XML
        #expect(plist.contains("<?xml version=\"1.0\""))
        #expect(plist.contains("<!DOCTYPE plist"))
        #expect(plist.contains("<plist version=\"1.0\">"))
    }

    // MARK: - 9. LaunchAgent install and uninstall

    @Test("LaunchAgent install creates plist file and uninstall removes it")
    func testLaunchAgentInstallUninstall() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plistPath = dir.appendingPathComponent("cn.com.nadav.deepfinder.daemon.plist").path

        // Install
        try LaunchAgent.installPlist(at: plistPath)
        #expect(FileManager.default.fileExists(atPath: plistPath))

        // Verify content
        let content = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(content.contains(Product.identifier))

        // Uninstall
        try LaunchAgent.uninstallPlist(at: plistPath)
        #expect(!FileManager.default.fileExists(atPath: plistPath))
    }
}
