import Testing
import Foundation
@testable import DeepFinder

@Suite("DaemonMain lifecycle")
struct DaemonMainTests {

    // MARK: - Helpers

    /// Create a unique temp directory for each test.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-daemon-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Create a DaemonMain pointing at a temp data dir, with MockEventStream
    /// and signal handlers disabled for safe testing.
    private func makeDaemon(dataDir: String) -> DaemonMain {
        DaemonMain(
            dataDir: dataDir,
            installSignals: false,
            eventStreamProvider: { MockEventStream() }
        )
    }

    // MARK: - 1. Data directory created with 700 permissions

    @Test("ensureDataDir creates directory with 700 permissions")
    func testEnsureDataDirCreatesWithCorrectPerms() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("data").path
        try DaemonMain.ensureDataDir(dataDir)

        let attrs = try FileManager.default.attributesOfItem(atPath: dataDir)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    // MARK: - 2. Data directory idempotent on existing path

    @Test("ensureDataDir is idempotent on existing directory")
    func testEnsureDataDirIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDir = dir.appendingPathComponent("data").path
        try DaemonMain.ensureDataDir(dataDir)
        try DaemonMain.ensureDataDir(dataDir)

        #expect(FileManager.default.fileExists(atPath: dataDir))
        let attrs = try FileManager.default.attributesOfItem(atPath: dataDir)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    // MARK: - 3. acquirePIDFile creates file with current PID

    @Test("acquirePIDFile creates file with current PID and returns valid fd")
    func testAcquirePIDFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path
        let fd = try DaemonMain.acquirePIDFile(pidPath: pidPath)
        defer {
            close(fd)
            unlink(pidPath)
        }

        // fd should be valid
        #expect(fd >= 0)

        // File should contain our PID
        let data = try Data(contentsOf: URL(fileURLWithPath: pidPath))
        let content = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let writtenPID = Int32(content ?? "")

        #expect(writtenPID == ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - 3b. acquirePIDFile succeeds with stale PID (auto-cleanup)

    @Test("acquirePIDFile succeeds when stale PID file exists")
    func testAcquirePIDFileStalePID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path

        // Write a PID that definitely doesn't exist
        try "99999999\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pidPath))

        // acquirePIDFile should clean up the stale file and succeed
        let fd = try DaemonMain.acquirePIDFile(pidPath: pidPath)
        defer {
            close(fd)
            unlink(pidPath)
        }

        // Verify it wrote our PID
        let data = try Data(contentsOf: URL(fileURLWithPath: pidPath))
        let content = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(content ?? "") == ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - 3c. acquirePIDFile succeeds with corrupted PID file (auto-cleanup)

    @Test("acquirePIDFile succeeds when corrupted PID file exists")
    func testAcquirePIDFileCorrupted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path
        try "not a number\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

        let fd = try DaemonMain.acquirePIDFile(pidPath: pidPath)
        defer {
            close(fd)
            unlink(pidPath)
        }

        // Should have succeeded and written our PID
        let data = try Data(contentsOf: URL(fileURLWithPath: pidPath))
        let content = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(content ?? "") == ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - 3d. acquirePIDFile throws when live daemon owns PID file

    @Test("acquirePIDFile throws alreadyRunning when PID file owned by live process")
    func testAcquirePIDFileLiveProcess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path

        // Write our own PID (simulating a live daemon)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        try "\(ownPID)\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

        do {
            _ = try DaemonMain.acquirePIDFile(pidPath: pidPath)
            Issue.record("Expected DaemonError.alreadyRunning but no error was thrown")
        } catch let error as DaemonError {
            if case .alreadyRunning(let pid) = error {
                #expect(pid == ownPID)
            } else {
                Issue.record("Expected alreadyRunning error, got: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - 4. Stale PID file detection and cleanup

    @Test("checkExistingDaemon returns false for stale PID and cleans up file")
    func testStalePIDFileDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path

        // Write a PID that definitely doesn't exist (99999999)
        let stalePID = "99999999\n"
        try stalePID.write(toFile: pidPath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: pidPath))

        let running = DaemonMain.checkExistingDaemon(pidPath: pidPath)
        #expect(!running)

        // Stale PID file should have been cleaned up
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - 5. No PID file means no existing daemon

    @Test("checkExistingDaemon returns false when no PID file exists")
    func testNoPIDFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path
        let running = DaemonMain.checkExistingDaemon(pidPath: pidPath)
        #expect(!running)
    }

    // MARK: - 6. Corrupted PID file is cleaned up

    @Test("checkExistingDaemon handles corrupted PID file")
    func testCorruptedPIDFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidPath = dir.appendingPathComponent("daemon.pid").path
        try "not a number\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

        let running = DaemonMain.checkExistingDaemon(pidPath: pidPath)
        #expect(!running)
        // Corrupted file should be cleaned up
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - 7. State transitions: starting -> ready -> live -> shuttingDown

    @Test("Daemon state transitions follow the correct sequence")
    func testStateTransitions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDirPath = dir.appendingPathComponent("data").path
        let daemon = makeDaemon(dataDir: dataDirPath)

        // Initial state
        let initialState = await daemon.state
        #expect(initialState == .starting)

        // Run daemon in background
        let daemonTask = Task {
            try await daemon.run()
        }

        // Wait for daemon to reach live state (timeout ~5s)
        var reachedLive = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let state = await daemon.state
            if state == .live {
                reachedLive = true
                break
            }
        }
        #expect(reachedLive)

        // Trigger shutdown
        await daemon.shutdown()
        let finalState = await daemon.state
        #expect(finalState == .shuttingDown)

        // Cancel the daemon task to clean up
        daemonTask.cancel()
    }

    // MARK: - 8. Shutdown cleanup removes PID file

    @Test("Shutdown removes PID file")
    func testShutdownRemovesPIDFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDirPath = dir.appendingPathComponent("data").path
        let daemon = makeDaemon(dataDir: dataDirPath)

        let daemonTask = Task {
            try await daemon.run()
        }

        // Wait for live state
        var reachedLive = false
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let state = await daemon.state
            if state == .live {
                reachedLive = true
                break
            }
        }
        #expect(reachedLive)

        // PID file should exist while daemon is running
        let pidPath = dir.appendingPathComponent("data")
            .appendingPathComponent("daemon.pid").path
        #expect(FileManager.default.fileExists(atPath: pidPath))

        // Shutdown
        await daemon.shutdown()
        daemonTask.cancel()

        // Give cleanup a moment
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - 9. Singleton detection: running daemon blocks second start

    @Test("run() throws when another daemon is already running (own PID)")
    func testSingletonDetection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dataDirPath = dir.appendingPathComponent("data").path
        let pidPath = (dataDirPath as NSString).appendingPathComponent("daemon.pid")

        // Write our own PID to simulate an already-running daemon
        try DaemonMain.ensureDataDir(dataDirPath)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        try "\(ownPID)\n".write(
            toFile: pidPath,
            atomically: true,
            encoding: .utf8
        )

        let daemon = makeDaemon(dataDir: dataDirPath)
        do {
            try await daemon.run()
            Issue.record("Expected DaemonError.alreadyRunning but no error was thrown")
        } catch let error as DaemonError {
            if case .alreadyRunning(let pid) = error {
                #expect(pid == ownPID)
            } else {
                Issue.record("Expected alreadyRunning error, got: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
