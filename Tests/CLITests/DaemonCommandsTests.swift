import Testing
import Foundation
import DeepFinderDaemon
import DeepFinderSearch
@testable import DeepFinderCLILib

@Suite("DaemonCommands")
struct DaemonCommandsTests {

    // MARK: - Helpers

    /// Create a unique temp directory for each test.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-cmd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Our own PID is always alive (signal 0 succeeds).
    private var ownPID: Int32 { ProcessInfo.processInfo.processIdentifier }

    // MARK: - 1. start when not running -> spawns daemon

    @Test("start when not running spawns daemon process")
    func testStartWhenNotRunning() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path
        let spawnTracker = MockProcessSpawner()
        let socketWaiter = MockSocketWaiter(shouldFind: true)
        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: spawnTracker,
            processSignaler: MockProcessSignaler(),
            socketWaiter: socketWaiter,
            pidReader: MockPIDReader(stubbedPID: nil)
        )

        let result = await runner.run(.start, client: MockIPCClient(response: .ack))
        #expect(result == 0)
        #expect(spawnTracker.spawnCalled)
        #expect(spawnTracker.lastBinaryPath == "/usr/local/bin/deepfinder")
    }

    // MARK: - 2. start when already running -> friendly message

    @Test("start when already running prints friendly message")
    func testStartAlreadyRunning() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        // PID reader reports our own PID, signaler reports it as alive
        let pidReader = MockPIDReader(stubbedPID: ownPID)
        let spawnTracker = MockProcessSpawner()

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: spawnTracker,
            processSignaler: MockProcessSignaler(livePID: ownPID),
            socketWaiter: MockSocketWaiter(shouldFind: false),
            pidReader: pidReader
        )

        let result = await runner.run(.start, client: MockIPCClient(response: .ack))
        #expect(result == 0) // not an error, just informational
        #expect(!spawnTracker.spawnCalled) // should NOT attempt to spawn
    }

    // MARK: - 3. stop running daemon -> sends SIGTERM

    @Test("stop running daemon sends SIGTERM and waits for exit")
    func testStopRunningDaemon() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        let pidReader = MockPIDReader(stubbedPID: ownPID)
        // Signaler: our PID is alive until SIGTERM is sent, then it dies
        let signaler = MockProcessSignaler(livePID: ownPID)

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: MockProcessSpawner(),
            processSignaler: signaler,
            socketWaiter: MockSocketWaiter(shouldFind: false),
            pidReader: pidReader
        )

        let result = await runner.run(.stop, client: MockIPCClient(response: .ack))
        #expect(result == 0)
        #expect(signaler.sigtermSent)
        #expect(signaler.lastSignaledPID == ownPID)
    }

    // MARK: - 4. stop non-running daemon -> "daemon not running"

    @Test("stop non-running daemon prints not running message")
    func testStopNotRunning() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        // No PID file -> pidReader returns nil
        let pidReader = MockPIDReader(stubbedPID: nil)
        let signaler = MockProcessSignaler()

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: MockProcessSpawner(),
            processSignaler: signaler,
            socketWaiter: MockSocketWaiter(shouldFind: false),
            pidReader: pidReader
        )

        let result = await runner.run(.stop, client: MockIPCClient(response: .ack))
        #expect(result == 2) // daemonError
        #expect(!signaler.sigtermSent) // should NOT send signal
    }

    // MARK: - 5. restart -> stop + start

    @Test("restart performs stop then start")
    func testRestart() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        let pidReader = MockPIDReader(stubbedPID: nil) // not running initially
        let signaler = MockProcessSignaler()
        let spawnTracker = MockProcessSpawner()
        let socketWaiter = MockSocketWaiter(shouldFind: true)

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: spawnTracker,
            processSignaler: signaler,
            socketWaiter: socketWaiter,
            pidReader: pidReader
        )

        let result = await runner.run(.restart, client: MockIPCClient(response: .ack))
        #expect(result == 0)
        #expect(spawnTracker.spawnCalled)
    }

    // MARK: - 6. status running -> shows PID, uptime, index state

    @Test("status when running shows daemon info via IPC")
    func testStatusRunning() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        let pidReader = MockPIDReader(stubbedPID: ownPID)
        let stats = DaemonStats(
            totalFiles: 12345,
            indexState: "live",
            uptimeSeconds: 3600.0,
            memoryUsageMB: 128.5
        )
        let mockClient = MockIPCClient(response: .stats(stats))

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: MockProcessSpawner(),
            processSignaler: MockProcessSignaler(livePID: ownPID),
            socketWaiter: MockSocketWaiter(shouldFind: true),
            pidReader: pidReader
        )

        let result = await runner.run(.status, client: mockClient)
        let lastReq = await mockClient.lastRequest
        #expect(result == 0)
        #expect(lastReq != nil)
    }

    // MARK: - 7. status not running -> "daemon not running"

    @Test("status when not running prints not running message")
    func testStatusNotRunning() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        let pidReader = MockPIDReader(stubbedPID: nil)
        let mockClient = MockIPCClient(response: .ack)

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: MockProcessSpawner(),
            processSignaler: MockProcessSignaler(),
            socketWaiter: MockSocketWaiter(shouldFind: false),
            pidReader: pidReader
        )

        let result = await runner.run(.status, client: mockClient)
        let lastReq = await mockClient.lastRequest
        #expect(result == 2) // daemonError: daemon not running
        #expect(lastReq == nil)
    }

    // MARK: - 8. start timeout -> error message

    @Test("start timeout waiting for socket returns error")
    func testStartTimeout() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pidPath = tmp.appendingPathComponent("daemon.pid").path
        let socketPath = tmp.appendingPathComponent("ipc.sock").path

        let pidReader = MockPIDReader(stubbedPID: nil) // not running
        let spawnTracker = MockProcessSpawner()
        // Socket never becomes available
        let socketWaiter = MockSocketWaiter(shouldFind: false)

        let runner = DaemonCommandRunner(
            pidPath: pidPath,
            socketPath: socketPath,
            daemonBinaryPath: "/usr/local/bin/deepfinder",
            processSpawner: spawnTracker,
            processSignaler: MockProcessSignaler(),
            socketWaiter: socketWaiter,
            pidReader: pidReader
        )

        let result = await runner.run(.start, client: MockIPCClient(response: .ack))
        #expect(result == 2) // daemonError: timeout
        #expect(spawnTracker.spawnCalled) // did attempt to spawn
    }
}

// MARK: - Mock ProcessSpawner

/// Records whether spawnDaemon was called and with which binary path.
final class MockProcessSpawner: ProcessSpawner, @unchecked Sendable {
    private(set) var spawnCalled = false
    private(set) var lastBinaryPath: String?

    func spawnDaemon(binaryPath: String, arguments: [String]) -> Result<Void, Error> {
        spawnCalled = true
        lastBinaryPath = binaryPath
        return .success(())
    }
}

// MARK: - Mock ProcessSignaler

/// Records whether SIGTERM was sent and to which PID.
///
/// When initialized with `livePID`, reports that PID as alive until SIGTERM
/// is sent to it, after which it reports the PID as dead (simulating process exit).
final class MockProcessSignaler: ProcessSignaler, @unchecked Sendable {
    private(set) var sigtermSent = false
    private(set) var lastSignaledPID: Int32?
    private let livePID: Int32?

    /// Initialize with an optional PID that is considered alive.
    /// After SIGTERM is sent to that PID, it becomes "dead".
    init(livePID: Int32? = nil) {
        self.livePID = livePID
    }

    func sendSIGTERM(to pid: Int32) -> Bool {
        sigtermSent = true
        lastSignaledPID = pid
        return true
    }

    func isProcessAlive(_ pid: Int32) -> Bool {
        // The livePID is alive only if SIGTERM hasn't been sent to it yet.
        // Other PIDs are always dead in this mock.
        if let livePID, pid == livePID {
            return !sigtermSent
        }
        return false
    }
}

// MARK: - Mock SocketWaiter

/// Controls whether waitForSocket returns success or timeout.
struct MockSocketWaiter: SocketWaiter, Sendable {
    let shouldFind: Bool

    init(shouldFind: Bool) {
        self.shouldFind = shouldFind
    }

    func waitForSocket(at path: String, timeout: TimeInterval) -> Bool {
        shouldFind
    }
}

// MARK: - Mock PIDReader

/// Returns a fixed PID (or nil) to simulate PID file contents.
struct MockPIDReader: PIDReader, Sendable {
    let stubbedPID: Int32?

    init(stubbedPID: Int32?) {
        self.stubbedPID = stubbedPID
    }

    func readPID(from path: String) -> Int32? {
        stubbedPID
    }

    func removePIDFile(at path: String) {
        // no-op in tests
    }
}
