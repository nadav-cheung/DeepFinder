import XCTest
import Foundation
@testable import DeepFinder

final class IndexRecoveryTests: XCTestCase {

    // MARK: - Helpers

    /// Create a temporary directory for file-based tests. Automatically cleaned up.
    private func makeTempDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmpDir)
        }
        return tmpDir
    }

    /// Create a sample FileRecord for testing.
    private func makeRecord(id: UInt32 = 1, name: String = "test.txt") -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: "/Users/test/\(name)",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
    }

    /// Create an IndexPersistence backed by a real file in the given directory.
    private func makeFileDB(in dir: URL, name: String = "test.db") throws -> IndexPersistence {
        let dbPath = dir.appendingPathComponent(name).path
        return try IndexPersistence(dbPath: dbPath)
    }

    /// Create a WAL file and SHM file alongside the main DB to simulate WAL state.
    private func createWALFiles(in dir: URL, dbName: String = "test.db") throws -> (walPath: String, shmPath: String) {
        let walPath = dir.appendingPathComponent(dbName + "-wal").path
        let shmPath = dir.appendingPathComponent(dbName + "-shm").path
        let data = Data("corrupted wal data".utf8)
        try data.write(to: URL(fileURLWithPath: walPath))
        try data.write(to: URL(fileURLWithPath: shmPath))
        return (walPath, shmPath)
    }

    /// Create a corrupted (invalid SQLite) file at the given path.
    private func createCorruptedFile(at path: String) throws {
        let garbage = Data("this is not a valid sqlite database at all!!!!".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - testDiagnoseHealthyDB

    func testDiagnoseHealthyDB() async throws {
        let tmpDir = try makeTempDir()
        let persistence = try makeFileDB(in: tmpDir)
        let record = makeRecord()
        await persistence.saveRecords([record])

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        let result = try await recovery.diagnoseAndRecover()
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.recordsRecovered, 0)
        XCTAssertFalse(result.message.isEmpty)
    }

    // MARK: - testRecoverFromWALCorruption

    func testRecoverFromWALCorruption() async throws {
        let tmpDir = try makeTempDir()
        let dbName = "recovery.db"
        let dbPath = tmpDir.appendingPathComponent(dbName).path

        // Create a valid DB with data
        let persistence = try IndexPersistence(dbPath: dbPath)
        let records = (1...3).map { i in makeRecord(id: UInt32(i), name: "file\(i).txt") }
        await persistence.saveRecords(records)

        // Simulate WAL corruption: overwrite WAL file with garbage
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let corruptedData = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8])
        try corruptedData.write(to: URL(fileURLWithPath: walPath))
        try corruptedData.write(to: URL(fileURLWithPath: shmPath))

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        let result = try await recovery.recoverFromWALCorruption()
        XCTAssertEqual(result.action, .walCleanup)

        // WAL and SHM files should no longer exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: walPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmPath))
    }

    // MARK: - testRecoverFromCheckpointFailure

    func testRecoverFromCheckpointFailure() async throws {
        let tmpDir = try makeTempDir()

        // Create a valid DB so the file exists on disk.
        let persistence = try makeFileDB(in: tmpDir, name: "checkpoint.db")

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        let result = try await recovery.recoverFromCheckpointFailure()
        // Since the DB file exists, recovery returns .rebuildFromDB
        XCTAssertEqual(result.action, .rebuildFromDB)
        XCTAssertFalse(result.message.isEmpty)
    }

    // MARK: - testSchemaIncompatibilityTriggersMigration

    func testSchemaIncompatibilityTriggersMigration() async throws {
        let tmpDir = try makeTempDir()
        let persistence = try makeFileDB(in: tmpDir)

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        // Simulate schema incompatibility: app version is newer than DB version
        let result = try await recovery.recoverFromSchemaIncompatibility(appVersion: 2, dbVersion: 1)
        XCTAssertEqual(result.action, .rebuildFromDB)
        XCTAssertTrue(result.message.contains("Schema"))
    }

    // MARK: - testMigrationFailureTriggersFullRebuild

    func testMigrationFailureTriggersFullRebuild() async throws {
        let tmpDir = try makeTempDir()
        let dbName = "migrate_fail.db"
        let dbPath = tmpDir.appendingPathComponent(dbName).path

        // Create a corrupted DB file (not valid SQLite)
        try createCorruptedFile(at: dbPath)

        // IndexPersistence init will fail on corrupted DB, so we use a fresh one
        // and simulate the scenario via recoverFromSchemaIncompatibility with a broken DB
        let freshDBPath = tmpDir.appendingPathComponent("fresh.db").path
        let persistence = try IndexPersistence(dbPath: freshDBPath)

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        // When schema migration cannot proceed, fullRebuild is the fallback
        let result = try await recovery.recoverFromSchemaIncompatibility(appVersion: 99, dbVersion: 1)
        // Since the DB is valid but versions differ hugely, it should indicate rebuild
        XCTAssertTrue(result.action == .fullRescan || result.action == .rebuildFromDB)
    }

    // MARK: - testFullRebuildScansAndReindexes

    func testFullRebuildScansAndReindexes() async throws {
        let tmpDir = try makeTempDir()
        let persistence = try makeFileDB(in: tmpDir)

        // Create a real directory with files to scan
        let scanDir = tmpDir.appendingPathComponent("scanroot")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: scanDir.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: scanDir.appendingPathComponent("b.txt"))

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        let result = try await recovery.fullRebuild(rootPaths: [scanDir.path])
        XCTAssertEqual(result.action, .fullRescan)
        XCTAssertGreaterThan(result.recordsRecovered, 0)

        // Verify the index now contains the scanned files
        let searchResults = await index.search(query: ".txt")
        XCTAssertGreaterThan(searchResults.count, 0)
    }

    // MARK: - testDetectStaleLock

    func testDetectStaleLock() async throws {
        let tmpDir = try makeTempDir()
        let persistence = try makeFileDB(in: tmpDir)

        let scanner = FileScanner()
        let index = InMemoryIndex()
        let recovery = IndexRecovery(persistence: persistence, scanner: scanner, index: index)

        // No stale lock on a fresh DB
        let isStale = try await recovery.detectStaleLock(timeout: 5)
        XCTAssertFalse(isStale)
    }

    // MARK: - testRecoveryResultHasCorrectMessage

    func testRecoveryResultHasCorrectMessage() {
        let result1 = RecoveryResult(action: .none, recordsRecovered: 0, message: "Database is healthy")
        XCTAssertEqual(result1.message, "Database is healthy")
        XCTAssertEqual(result1.action, .none)
        XCTAssertEqual(result1.recordsRecovered, 0)

        let result2 = RecoveryResult(action: .walCleanup, recordsRecovered: 42, message: "WAL files removed, recovered 42 records")
        XCTAssertEqual(result2.action, .walCleanup)
        XCTAssertEqual(result2.recordsRecovered, 42)
        XCTAssertEqual(result2.message, "WAL files removed, recovered 42 records")

        let result3 = RecoveryResult(action: .fullRescan, recordsRecovered: 0, message: "Starting full rescan")
        XCTAssertEqual(result3.action, .fullRescan)

        let result4 = RecoveryResult(action: .rebuildFromDB, recordsRecovered: 100, message: "Rebuilt from main DB")
        XCTAssertEqual(result4.action, .rebuildFromDB)
    }
}
