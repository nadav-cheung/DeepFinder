// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
import SQLite3
import DeepFinderIndex
@testable import DeepFinderPersist

/// P4 one-time SQLite→binary migration tests.
///
/// These cover ``LegacySQLiteReader/readRecords(at:pathEncryption:)`` and the
/// migration hook in ``IndexPersistence/init(dbPath:)`` that seeds `index.bin`
/// from a legacy `index.db` when no binary snapshot exists yet.
///
/// `IndexPersistence(dbPath:)` constructs its own ``PathEncryption`` from the
/// default ``SecretsStore`` (`~/.deep-finder/.env`). For the encrypted-path
/// round-trip to work, the legacy fixture is therefore written with a
/// ``PathEncryption`` bound to the SAME default store — the production
/// scenario. The suite is `.serialized` because it touches that shared
/// secrets file (consistent with the other on-disk PersistTests).
@Suite("SQLiteMigration", .serialized)
struct SQLiteMigrationTests {

    // MARK: - Helpers

    /// Temp dir handle. `defer cleanup()` removes it.
    private func makeTempDir() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("df-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: dir) }
        return (dir, cleanup)
    }

    /// Sample record for the legacy fixture.
    private func makeRecord(id: UInt32, name: String = "test.txt") -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: "/Users/test/\(name)",
            parentPath: "/Users/test",
            isDirectory: false,
            size: Int64(id) * 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(id)),
            extension: "txt"
        )
    }

    /// Write a legacy `index.db` at `dbPath` containing the given records, with
    /// `path` and `parent_path` encrypted by `pathEncryption` (matching the old
    /// pre-P3 write path). If `pathEncryption` is nil, paths are stored in
    /// plaintext. Creates the `file_records` table via the real
    /// ``SchemaMigrator/createFileRecordsSQL`` so the column set is identical
    /// to what the old layer produced.
    private func writeLegacyDB(
        at dbPath: String,
        records: [FileRecord],
        pathEncryption: PathEncryption?
    ) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let openRC = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard openRC == SQLITE_OK, let db else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw PersistenceError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        try SchemaMigrator.execSQL(db, SchemaMigrator.createFileRecordsSQL)

        let sql = """
            INSERT OR REPLACE INTO file_records
                (id, name, original_name, path, parent_path, is_directory,
                 size, created_at, modified_at, ext, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, prepRC)
        }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            let pathValue: String
            let parentValue: String
            if let pathEncryption {
                pathValue = try pathEncryption.encrypt(record.path)
                parentValue = try pathEncryption.encrypt(record.parentPath)
            } else {
                pathValue = record.path
                parentValue = record.parentPath
            }

            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(record.id))
            sqlite3_bind_text(stmt, 2, record.name, -1, SQLTransient)
            sqlite3_bind_text(stmt, 3, record.originalName, -1, SQLTransient)
            sqlite3_bind_text(stmt, 4, pathValue, -1, SQLTransient)
            sqlite3_bind_text(stmt, 5, parentValue, -1, SQLTransient)
            sqlite3_bind_int(stmt, 6, record.isDirectory ? 1 : 0)
            sqlite3_bind_int64(stmt, 7, sqlite3_int64(record.size))
            sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, record.modifiedAt.timeIntervalSince1970)
            if let ext = record.extension {
                sqlite3_bind_text(stmt, 10, ext, -1, SQLTransient)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let metadata = record.metadata,
               let jsonData = try? JSONEncoder().encode(metadata),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                sqlite3_bind_text(stmt, 11, jsonStr, -1, SQLTransient)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            let stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_DONE else {
                throw PersistenceError.stepFailed(stepRC)
            }
        }
    }

    // MARK: - Tests

    // MARK: 1. Happy path — legacy index.db seeds index.bin, paths decrypt

    @Test("Legacy index.db migrates to index.bin with correct records")
    func happyPath() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let dbPath = dir.appendingPathComponent("index.db").path
        let binPath = dir.appendingPathComponent("index.bin").path

        // Build the legacy db with the SAME default-store PathEncryption that
        // IndexPersistence will construct internally, so the ciphertext round-trips.
        let encryption = try PathEncryption()
        let records = [
            makeRecord(id: 1, name: "alpha.txt"),
            makeRecord(id: 2, name: "beta.txt"),
            makeRecord(id: 3, name: "gamma.txt"),
        ]
        try writeLegacyDB(at: dbPath, records: records, pathEncryption: encryption)

        // Precondition: no index.bin yet, legacy db present.
        #expect(!FileManager.default.fileExists(atPath: binPath))
        #expect(FileManager.default.fileExists(atPath: dbPath))

        // Construct IndexPersistence — this triggers the migration hook.
        let persistence = try IndexPersistence(dbPath: dbPath)

        // index.bin must now exist.
        #expect(FileManager.default.fileExists(atPath: binPath))
        #expect(BinaryIndex.exists(at: binPath))

        // loadAllRecords must return the migrated records, paths decrypted.
        let loaded = try await persistence.loadAllRecords()
        #expect(loaded.count == 3)

        let loadedById = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for original in records {
            let got = try #require(loadedById[original.id])
            #expect(got.name == original.name)
            #expect(got.originalName == original.originalName)
            #expect(got.path == original.path)             // decrypted back to plaintext
            #expect(got.parentPath == original.parentPath)
            #expect(got.isDirectory == original.isDirectory)
            #expect(got.size == original.size)
            #expect(got.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
            #expect(got.modifiedAt.timeIntervalSince1970 == original.modifiedAt.timeIntervalSince1970)
            #expect(got.extension == original.extension)
        }
    }

    // MARK: 2. Idempotent — second open does not re-migrate

    @Test("Second open with existing index.bin does not re-migrate")
    func idempotent() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let dbPath = dir.appendingPathComponent("index.db").path
        let binPath = dir.appendingPathComponent("index.bin").path

        let encryption = try PathEncryption()
        let records = [makeRecord(id: 10, name: "first.txt"),
                       makeRecord(id: 11, name: "second.txt")]
        try writeLegacyDB(at: dbPath, records: records, pathEncryption: encryption)

        // First open — migrates.
        let p1 = try IndexPersistence(dbPath: dbPath)
        await p1.close()
        let firstSnapshot = try Data(contentsOf: URL(fileURLWithPath: binPath))
        #expect(firstSnapshot.count > 0)

        // Mutate the legacy db AFTER the first migration so that a re-migration
        // would observably change the record set. The second open must NOT
        // pick up this extra row — it should load from the existing index.bin.
        try writeLegacyDB(at: dbPath, records: records + [makeRecord(id: 99, name: "post-migration.txt")],
                          pathEncryption: encryption)

        // Second open — index.bin exists, so no re-migration.
        let p2 = try IndexPersistence(dbPath: dbPath)
        let loaded = try await p2.loadAllRecords()
        #expect(loaded.count == 2)  // not 3
        #expect(loaded.contains { $0.id == 99 } == false)
    }

    // MARK: 3. No legacy db → no migration, empty load (first run)

    @Test("No legacy db and no index.bin → empty load, no migration")
    func firstRun() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let dbPath = dir.appendingPathComponent("index.db").path
        let binPath = dir.appendingPathComponent("index.bin").path

        // Neither file exists.
        #expect(!FileManager.default.fileExists(atPath: dbPath))
        #expect(!FileManager.default.fileExists(atPath: binPath))

        let persistence = try IndexPersistence(dbPath: dbPath)

        // No migration ran; index.bin still absent (created lazily on save).
        #expect(!FileManager.default.fileExists(atPath: binPath))
        let loaded = try await persistence.loadAllRecords()
        #expect(loaded.isEmpty)
    }

    // MARK: 4. Corrupt legacy db → graceful fallback (no throw out of init)

    @Test("Corrupt legacy index.db falls back to rescan without throwing")
    func corruptLegacyFallback() async throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let dbPath = dir.appendingPathComponent("index.db").path
        let binPath = dir.appendingPathComponent("index.bin").path

        // Write garbage bytes — NOT a valid SQLite file.
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03,
                            0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        try garbage.write(to: URL(fileURLWithPath: dbPath))
        #expect(FileManager.default.fileExists(atPath: dbPath))

        // init must NOT throw — migration failure is caught and we fall back.
        let persistence = try IndexPersistence(dbPath: dbPath)

        // index.bin was NOT created by the failed migration.
        #expect(!FileManager.default.fileExists(atPath: binPath))

        // loadAllRecords returns [] — the rescan path.
        let loaded = try await persistence.loadAllRecords()
        #expect(loaded.isEmpty)
    }

    // MARK: 5. Plaintext legacy db (pathEncryption = nil) — reader returns plaintext paths

    @Test("readRecords with nil pathEncryption returns plaintext paths")
    func plaintextReader() throws {
        let (dir, cleanup) = try makeTempDir()
        defer { cleanup() }

        let dbPath = dir.appendingPathComponent("plaintext.db").path

        let records = [makeRecord(id: 1, name: "plain.txt"),
                       makeRecord(id: 2, name: "report.pdf")]

        // Write the legacy db WITHOUT encryption.
        try writeLegacyDB(at: dbPath, records: records, pathEncryption: nil)

        // readRecords with nil pathEncryption must return the plaintext paths.
        let loaded = try LegacySQLiteReader.readRecords(at: dbPath, pathEncryption: nil)
        #expect(loaded.count == 2)
        #expect(loaded.contains { $0.path == "/Users/test/plain.txt" })
        #expect(loaded.contains { $0.path == "/Users/test/report.pdf" })
    }
}
