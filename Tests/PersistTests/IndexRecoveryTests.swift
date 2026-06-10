import Testing
import Foundation
import SQLite3
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

    /// Create a valid SQLite database at the given path (with schema).
    private func createValidDB(at path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)
            Issue.record("Failed to create test database")
            return
        }

        // Create schema to match IndexPersistence
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, SchemaMigrator.createFileRecordsSQL, nil, nil, nil)
        sqlite3_exec(db, SchemaMigrator.createMetadataSQL, nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = \(SchemaMigrator.currentSchemaVersion)", nil, nil, nil)
        sqlite3_close(db)
    }

    /// Create a corrupted file at the given path (not a valid SQLite database).
    private func createCorruptedFile(at path: String) throws {
        let garbage = Data("NOT A VALID SQLITE DATABASE CORRUPTED GARBAGE DATA!!!!!!".utf8)
        try garbage.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Integrity Check with Valid DB

    @Test func integrityCheckWithValidDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createValidDB(at: dbPath)

        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == true)
    }

    // MARK: - Integrity Check with Missing DB (first run)

    @Test func integrityCheckWithMissingDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("nonexistent.db").path
        // Missing DB returns true (not corruption — first run)
        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == true)
    }

    // MARK: - Integrity Check with Corrupted DB

    @Test func integrityCheckWithCorruptedDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createCorruptedFile(at: dbPath)

        let result = IndexRecovery.verifyIntegrity(dbPath: dbPath)
        #expect(result == false)
    }

    // MARK: - Auto-Rebuild on Corruption

    @Test func autoRebuildOnCorruption() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createCorruptedFile(at: dbPath)

        // Verify it's corrupted
        #expect(!IndexRecovery.verifyIntegrity(dbPath: dbPath))

        // Recover
        try IndexRecovery.recover(dbPath: dbPath, dbDirectory: tmpDir.path)

        // After recovery, the file should be gone
        #expect(!FileManager.default.fileExists(atPath: dbPath))

        // IndexPersistence should be able to create a fresh database
        let persistence = try IndexPersistence(dbPath: dbPath)
        let records = try await persistence.loadAllRecords()
        #expect(records.isEmpty)
    }

    // MARK: - WAL Cleanup

    @Test func walCleanup() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let walPath = tmpDir.appendingPathComponent("index.db-wal").path
        let shmPath = tmpDir.appendingPathComponent("index.db-shm").path

        // Create a valid database with WAL files
        try createValidDB(at: dbPath)

        // Write some data to generate WAL activity
        var db: OpaquePointer?
        sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        if let db {
            sqlite3_exec(db, "INSERT INTO file_records (id, name, original_name, path, parent_path, is_directory, size, created_at, modified_at) VALUES (1, 'test', 'test', '/test', '/', 0, 100, 0, 0)", nil, nil, nil)
            // Don't checkpoint — leave WAL active
            sqlite3_close(db)
        }

        // Create dummy WAL and SHM files if SQLite didn't generate them
        if !FileManager.default.fileExists(atPath: walPath) {
            try Data("dummy wal".utf8).write(to: URL(fileURLWithPath: walPath))
        }
        if !FileManager.default.fileExists(atPath: shmPath) {
            try Data("dummy shm".utf8).write(to: URL(fileURLWithPath: shmPath))
        }

        // Verify WAL/SHM exist
        #expect(FileManager.default.fileExists(atPath: walPath))
        #expect(FileManager.default.fileExists(atPath: shmPath))

        // Run cleanup
        IndexRecovery.cleanupWALFiles(dbDirectory: tmpDir.path)

        // WAL and SHM should be removed
        #expect(!FileManager.default.fileExists(atPath: walPath))
        #expect(!FileManager.default.fileExists(atPath: shmPath))

        // Main DB should still exist (cleanupWALFiles doesn't delete it)
        #expect(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - WAL Cleanup with No Files

    @Test func walCleanupWithNoFiles() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Should not crash or error when no WAL/SHM files exist
        IndexRecovery.cleanupWALFiles(dbDirectory: tmpDir.path)
    }

    // MARK: - Stale Lock Detection

    @Test func staleLockDetectionWithDeadProcess() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path

        // Write a PID that definitely doesn't exist (99999999)
        let stalePID = "99999999\n"
        try stalePID.write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == true)

        // PID file should be removed
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

        // Write the current process PID (which is alive)
        let currentPID = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try currentPID.write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == false)

        // PID file should still exist
        #expect(FileManager.default.fileExists(atPath: pidPath))
    }

    @Test func staleLockWithCorruptedPID() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path

        // Write non-numeric garbage
        try "not a number".write(toFile: pidPath, atomically: true, encoding: .utf8)

        let result = IndexRecovery.detectStaleLock(pidPath: pidPath)
        #expect(result == true)

        // Corrupted file should be removed
        #expect(!FileManager.default.fileExists(atPath: pidPath))
    }

    // MARK: - Schema Compatibility

    @Test func schemaCompatibilityWithCurrentVersion() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createValidDB(at: dbPath)

        let result = IndexRecovery.verifySchemaCompatibility(dbPath: dbPath)
        #expect(result == true)
    }

    @Test func schemaCompatibilityWithMissingDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("nonexistent.db").path
        let result = IndexRecovery.verifySchemaCompatibility(dbPath: dbPath)
        #expect(result == true)
    }

    @Test func schemaCompatibilityWithNewerVersion() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        try createValidDB(at: dbPath)

        // Set the schema version to something higher than current
        var db: OpaquePointer?
        sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        if let db {
            let futureVersion = SchemaMigrator.currentSchemaVersion + 10
            sqlite3_exec(db, "PRAGMA user_version = \(futureVersion)", nil, nil, nil)
            sqlite3_close(db)
        }

        let result = IndexRecovery.verifySchemaCompatibility(dbPath: dbPath)
        #expect(result == false)
    }

    // MARK: - Full Startup Recovery

    @Test func fullStartupRecoveryWithHealthyDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try createValidDB(at: dbPath)

        // Should not throw
        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )

        // DB should still exist
        #expect(FileManager.default.fileExists(atPath: dbPath))
    }

    @Test func fullStartupRecoveryWithCorruptedDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try createCorruptedFile(at: dbPath)

        try IndexRecovery.runStartupRecovery(
            dbPath: dbPath,
            dbDirectory: tmpDir.path,
            pidPath: pidPath
        )

        // Corrupted DB should be removed
        #expect(!FileManager.default.fileExists(atPath: dbPath))
    }

    @Test func fullStartupRecoveryThrowsOnSchemaIncompatibility() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let pidPath = tmpDir.appendingPathComponent("daemon.pid").path
        try createValidDB(at: dbPath)

        // Set the schema version to something higher
        var db: OpaquePointer?
        sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        if let db {
            let futureVersion = SchemaMigrator.currentSchemaVersion + 5
            sqlite3_exec(db, "PRAGMA user_version = \(futureVersion)", nil, nil, nil)
            sqlite3_close(db)
        }

        #expect(throws: IndexRecoveryError.self) {
            try IndexRecovery.runStartupRecovery(
                dbPath: dbPath,
                dbDirectory: tmpDir.path,
                pidPath: pidPath
            )
        }
    }

    // MARK: - Recovery After IndexPersistence Can Open Fresh DB

    @Test func recoveryThenOpenFreshDB() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path

        // Create and corrupt
        try createCorruptedFile(at: dbPath)
        #expect(!IndexRecovery.verifyIntegrity(dbPath: dbPath))

        // Recover
        try IndexRecovery.recover(dbPath: dbPath, dbDirectory: tmpDir.path)
        #expect(!FileManager.default.fileExists(atPath: dbPath))

        // Open fresh DB
        let persistence = try IndexPersistence(dbPath: dbPath)
        let records = try await persistence.loadAllRecords()
        #expect(records.isEmpty)

        // Insert and verify
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

        // Verify the fresh DB passes integrity
        #expect(IndexRecovery.verifyIntegrity(dbPath: dbPath))
    }

    // MARK: - Checkpoint Fallback

    @Test func checkpointFallbackOnCorruptedDB() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("index.db").path
        let walPath = tmpDir.appendingPathComponent("index.db-wal").path

        // Create corrupted DB + WAL file
        try createCorruptedFile(at: dbPath)
        try Data("wal data".utf8).write(to: URL(fileURLWithPath: walPath))

        // Cleanup should not crash even when checkpoint fails on corrupted DB
        IndexRecovery.cleanupWALFiles(dbDirectory: tmpDir.path)

        // WAL should be removed despite checkpoint failure
        #expect(!FileManager.default.fileExists(atPath: walPath))
    }
}
