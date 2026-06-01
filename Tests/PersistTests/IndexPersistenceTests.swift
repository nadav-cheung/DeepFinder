import Testing
import Foundation
@testable import DeepFinder

struct IndexPersistenceTests {

    // MARK: - Helpers

    /// Create a fresh in-memory database for each test.
    private func makeDB() throws -> IndexPersistence {
        try IndexPersistence(dbPath: ":memory:")
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

    // MARK: - Database Creation

    @Test func createDatabase() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("test.db").path
        let _ = try IndexPersistence(dbPath: dbPath)
        #expect(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - Save & Load Round-Trip

    @Test func saveAndLoadRecords() async throws {
        let db = try makeDB()
        let record = makeRecord()
        await db.saveRecords([record])
        let loaded = try await db.loadAllRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == record.id)
        #expect(loaded[0].name == record.name)
        #expect(loaded[0].originalName == record.originalName)
        #expect(loaded[0].path == record.path)
        #expect(loaded[0].parentPath == record.parentPath)
        #expect(loaded[0].isDirectory == record.isDirectory)
        #expect(loaded[0].size == record.size)
        #expect(loaded[0].createdAt.timeIntervalSince1970 == record.createdAt.timeIntervalSince1970)
        #expect(loaded[0].modifiedAt.timeIntervalSince1970 == record.modifiedAt.timeIntervalSince1970)
        #expect(loaded[0].extension == record.extension)
    }

    @Test func saveMultipleRecords() async throws {
        let db = try makeDB()
        let records = (1...5).map { i in
            makeRecord(id: UInt32(i), name: "file\(i).txt")
        }
        await db.saveRecords(records)
        let loaded = try await db.loadAllRecords()
        #expect(loaded.count == 5)
    }

    // MARK: - Delete

    @Test func deleteRecords() async throws {
        let db = try makeDB()
        let records = (1...3).map { i in
            makeRecord(id: UInt32(i), name: "file\(i).txt")
        }
        await db.saveRecords(records)
        await db.deleteRecords([1, 3])
        let loaded = try await db.loadAllRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == 2)
    }

    // MARK: - Update (Upsert)

    @Test func updateRecords() async throws {
        let db = try makeDB()
        let original = makeRecord(id: 1, name: "old.txt")
        await db.saveRecords([original])

        let updated = FileRecord(
            id: 1,
            name: "new.txt",
            originalName: "new.txt",
            path: "/Users/test/new.txt",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 2048,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_200),
            extension: "txt"
        )
        await db.saveRecords([updated])

        let loaded = try await db.loadAllRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "new.txt")
        #expect(loaded[0].size == 2048)
    }

    // MARK: - Event Cursor

    @Test func eventCursorRoundTrip() async throws {
        let db = try makeDB()
        // Initially nil
        let initial = await db.loadEventCursor()
        #expect(initial == nil)

        let cursor: UInt64 = 12345678
        await db.saveEventCursor(cursor)
        let loaded = await db.loadEventCursor()
        #expect(loaded == cursor)
    }

    // MARK: - Integrity Check

    @Test func verifyIntegrityOnValidDB() async throws {
        let db = try makeDB()
        let valid = try await db.verifyIntegrity()
        #expect(valid)
    }

    // MARK: - WAL Mode

    @Test func walModeEnabled() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("wal_test.db").path
        let db = try IndexPersistence(dbPath: dbPath)
        let mode = try await db.readJournalMode()
        #expect(mode == "wal")
    }

    // MARK: - Schema Version

    @Test func schemaVersion() async throws {
        let db = try makeDB()
        let version = try await db.schemaVersion()
        #expect(version > 0)
    }

    // MARK: - Empty Load

    @Test func emptyLoadReturnsEmptyArray() async throws {
        let db = try makeDB()
        let loaded = try await db.loadAllRecords()
        #expect(loaded.isEmpty)
    }

    // MARK: - File Permissions

    @Test func filePermissions() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("perm_test.db").path
        _ = try IndexPersistence(dbPath: dbPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    // MARK: - Migration Transaction

    @Test func migrationTransaction() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("migration_test.db").path

        // First open — creates schema
        let db1 = try IndexPersistence(dbPath: dbPath)
        let record = makeRecord()
        await db1.saveRecords([record])

        // Second open — migration should be idempotent
        let db2 = try IndexPersistence(dbPath: dbPath)
        let loaded = try await db2.loadAllRecords()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "test.txt")
    }
}
