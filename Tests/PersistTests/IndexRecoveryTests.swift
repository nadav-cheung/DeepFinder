// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderPersist

struct IndexRecoveryTests {

    // MARK: - Helpers

    /// Create a fresh temporary directory for each test.
    private func makeTempDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    /// Derive the `.bin` path from a `.db` path the same way IndexPersistence does.
    private func binPath(for dbPath: String) -> String {
        IndexRecovery.binPath(for: dbPath)
    }

    /// Derive the `.cursor` sidecar path the same way BinaryIndex does.
    private func cursorPath(for binPath: String) -> String {
        let url = URL(fileURLWithPath: binPath)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base).cursor").path
    }

    /// Write a valid DFIX header (version 1) with zero records into the bin file.
    /// Magic "DFIX" + UInt16 LE version (1) + flags (0) + reserved (0)
    /// + UInt32 LE num_records (0) + UInt32 LE reserved (0) = 16 bytes.
    private func createValidHeader(at binPath: String) throws {
        var data = Data()
        data.append(contentsOf: [0x44, 0x46, 0x49, 0x58]) // "DFIX"
        data.append(UInt8(1)); data.append(UInt8(0))      // version LE = 1
        data.append(UInt8(0))                              // flags
        data.append(UInt8(0))                              // reserved
        data.append(UInt8(0)); data.append(UInt8(0))
        data.append(UInt8(0)); data.append(UInt8(0))       // num_records = 0
        data.append(UInt8(0)); data.append(UInt8(0))
        data.append(UInt8(0)); data.append(UInt8(0))       // reserved2 = 0
        try data.write(to: URL(fileURLWithPath: binPath))
    }

    /// Write garbage bytes that are NOT a valid DFIX file.
    private func createCorruptFile(at path: String) throws {
        let garbage = Data("NOT A VALID DFIX FILE CORRUPTED GARBAGE DATA!!!!!!!!!!".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))
    }

    /// Write a valid DFIX magic but an unsupported (future) version.
    private func createUnsupportedVersion(at binPath: String) throws {
        var data = Data()
        data.append(contentsOf: [0x44, 0x46, 0x49, 0x58]) // "DFIX"
        data.append(UInt8(0xFF)); data.append(UInt8(0xFF)) // version LE = 65535
        data.append(UInt8(0))                              // flags
        data.append(UInt8(0))                              // reserved
        data.append(UInt8(0)); data.append(UInt8(0))
        data.append(UInt8(0)); data.append(UInt8(0))       // num_records = 0
        data.append(UInt8(0)); data.append(UInt8(0))
        data.append(UInt8(0)); data.append(UInt8(0))       // reserved2 = 0
        try data.write(to: URL(fileURLWithPath: binPath))
    }

    // MARK: - Integrity Check — absent index (first run)

    @Test func integrityCheckWithMissingDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("nonexistent.db").path
        // Missing index.bin returns true (first run — not corruption)
        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == true)
    }

    // MARK: - Integrity Check — valid header

    @Test func integrityCheckWithValidHeader() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createValidHeader(at: binPath(for: dbPath))

        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == true)
    }

    // MARK: - Integrity Check — corrupt/garbage header

    @Test func integrityCheckWithCorruptFile() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createCorruptFile(at: binPath(for: dbPath))

        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == false)
    }

    // MARK: - Integrity Check — unsupported version

    @Test func integrityCheckWithUnsupportedVersion() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createUnsupportedVersion(at: binPath(for: dbPath))

        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == false)
    }

    // MARK: - Auto-rebuild on corruption

    @Test func autoRebuildOnCorruptionDeletesBinAndCursor() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let bin = binPath(for: dbPath)
        let cursor = cursorPath(for: bin)
        try createCorruptFile(at: bin)
        // Also drop a cursor sidecar to confirm it gets cleaned up too.
        try Data("DFCR".utf8).write(to: URL(fileURLWithPath: cursor))

        #expect(!IndexRecovery.verifyIntegrity(dbPath: dbPath))

        try IndexRecovery.recover(dbPath: dbPath, dbDirectory: tmpDir.path)

        // Both index.bin and the cursor sidecar should be gone.
        #expect(!FileManager.default.fileExists(atPath: bin))
        #expect(!FileManager.default.fileExists(atPath: cursor))
    }

    @Test func recoverIsIdempotentWhenFilesAbsent() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        // Nothing to recover — should not throw.
        try IndexRecovery.recover(dbPath: dbPath, dbDirectory: tmpDir.path)
    }

    // MARK: - Stale Lock Detection (FS-level, unchanged)

    @Test func staleLockDetectionWithDeadProcess() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        let stalePID = "99999999\n"
        try stalePID.write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == true)
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    @Test func staleLockWithNoFile() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("nonexistent.pid").path
        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == false)
    }

    @Test func staleLockWithLiveProcess() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        let currentPID = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try currentPID.write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == false)
        #expect(FileManager.default.fileExists(atPath: pidPath))
    }

    @Test func staleLockWithCorruptedPID() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try "not a number".write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == true)
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - Full Startup Recovery

    @Test func fullStartupRecoveryWithHealthyIndex() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try createValidHeader(at: binPath(for: dbPath))

        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )

        // Valid index.bin should be left in place.
        #expect(FileManager.default.fileExists(atPath: binPath(for: dbPath)))
    }

    @Test func fullStartupRecoveryWithMissingIndex() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path

        // First run — no file at all. Should not throw and should not create one.
        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )
        #expect(!FileManager.default.fileExists(atPath: binPath(for: dbPath)))
    }

    @Test func fullStartupRecoveryWithCorruptIndex() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try createCorruptFile(at: binPath(for: dbPath))

        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )

        // Corrupt index.bin should be removed.
        #expect(!FileManager.default.fileExists(atPath: binPath(for: dbPath)))
    }

    @Test func fullStartupRecoveryWithStalePID() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try "99999999\n".write(toFile: pidPath, atomically: true, encoding: .utf8)

        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )
        // Stale PID file should be cleaned up.
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - Recovery → IndexPersistence opens fresh

    @Test func recoveryThenOpenFreshIndex() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let bin = binPath(for: dbPath)
        try createCorruptFile(at: bin)
        #expect(!IndexRecovery.verifyIntegrity(dbPath: dbPath))

        try IndexRecovery.recover(dbPath: dbPath, dbDirectory: tmpDir.path)
        #expect(!FileManager.default.fileExists(atPath: bin))

        let persistence = try IndexPersistence(dbPath: dbPath)
        let records = try await persistence.loadAllRecords()
        #expect(records.isEmpty)

        let record = FileRecord(
            id: 1,
            name: "test.txt",
            originalName: "test.txt",
            path: "/Users/test/test.txt",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
        await persistence.saveRecords([record])

        let loaded = try await persistence.loadAllRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "test.txt")

        // Fresh written index should pass the header check.
        #expect(IndexRecovery.verifyIntegrity(dbPath: dbPath))
    }
}
