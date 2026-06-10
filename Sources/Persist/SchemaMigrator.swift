import Foundation
import OSLog
import SQLite3
import DeepFinderIndex

/// Schema versioning, migration, and static SQLite utilities for ``IndexPersistence``.
///
/// All methods are static (no instances). Separated from IndexPersistence to keep
/// the actor focused on record CRUD while schema management lives in its own namespace.
///
/// ## Schema History
/// - v1: initial schema (id, name, original_name, path, parent_path, is_directory, size, created_at, modified_at, ext)
/// - v2: added metadata_json column (media metadata)
/// - v3: path encryption — path and parent_path columns now store AES-256-GCM ciphertext
public enum SchemaMigrator {

    // MARK: - Schema Constants

    /// Current schema version. Bumped when the schema changes.
    public static let currentSchemaVersion: Int = 3

    /// SQL to create the file_records table.
    static let createFileRecordsSQL = """
        CREATE TABLE IF NOT EXISTS file_records (
            id          INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            original_name TEXT NOT NULL,
            path        TEXT NOT NULL UNIQUE,
            parent_path TEXT NOT NULL,
            is_directory INTEGER NOT NULL DEFAULT 0,
            size        INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL,
            modified_at REAL NOT NULL,
            ext         TEXT,
            metadata_json TEXT
        )
        """

    /// SQL to create the metadata key-value table (cursor, etc.).
    static let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """

    // MARK: - Logging

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

    // MARK: - Schema Migration

    /// Run schema migrations in a transaction.
    ///
    /// Uses `PRAGMA user_version` to track the current schema version.
    /// Each migration step runs inside a transaction; on failure the transaction
    /// is rolled back and the database is marked as corrupted.
    public static func migrateSchema(on db: OpaquePointer) throws {
        let currentVersion = readSchemaVersion(on: db)

        // Downgrade detection: DB was created by a newer version
        if currentVersion > currentSchemaVersion {
            throw PersistenceError.migrationFailed(
                "Database schema v\(currentVersion) is newer than app v\(currentSchemaVersion). " +
                "Please delete the index and rebuild."
            )
        }

        // Already at the latest version
        if currentVersion == currentSchemaVersion {
            return
        }

        // Run migrations in a transaction
        try execSQL(db, "BEGIN")

        do {
            // v1 → v2: Add metadata_json column for media metadata
            if currentVersion < 2 { try migrateToV2(db) }
            // v2 → v3: Path encryption. No schema change (same columns), but existing
            // plaintext paths will be encrypted by ``migratePlaintextPathsIfNeeded()``
            // after the migration transaction commits and the encryption key is loaded.
            if currentVersion < 3 { try migrateToV3(db) }

            // Update schema version
            try execSQL(db, "PRAGMA user_version = \(currentSchemaVersion)")
            try execSQL(db, "COMMIT")
        } catch {
            // Best-effort rollback — already throwing, but log if rollback itself fails
            do { try execSQL(db, "ROLLBACK") }
            catch { /* Rollback failure is non-actionable during migration failure */ }
            throw PersistenceError.migrationFailed(error.localizedDescription)
        }
    }

    /// Read PRAGMA user_version from the given connection.
    public static func readSchemaVersion(on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, "PRAGMA user_version", -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Migrate schema from v1 to v2: add metadata_json column.
    private static func migrateToV2(_ db: OpaquePointer) throws {
        let columns = columnNames(in: "file_records", on: db)
        if !columns.contains("metadata_json") {
            try execSQL(db, "ALTER TABLE file_records ADD COLUMN metadata_json TEXT")
        }
    }

    /// Migrate schema from v2 to v3: no schema change, just bump the version.
    ///
    /// Existing plaintext paths in the `path` and `parent_path` columns will be
    /// encrypted by ``migratePlaintextPathsIfNeeded()`` after the migration transaction
    /// commits and the AES-256 key is loaded from secrets file.
    private static func migrateToV3(_ db: OpaquePointer) throws {
        // No ALTER TABLE needed — same columns, just encrypted at application layer.
        // The version bump happens in migrateSchema via PRAGMA user_version.
    }

    /// Encrypt existing plaintext paths if this database was migrated from v2 (or earlier).
    ///
    /// Called from ``IndexPersistence.init(dbPath:)`` after the actor's initializer
    /// has opened the database and loaded the encryption key.
    ///
    /// - Parameter db: The open SQLite database connection.
    public static func migratePlaintextPathsIfNeeded(db: OpaquePointer) throws {
        // Check if paths are already encrypted (metadata flag)
        if readMetadataValue(db: db, key: "path_encryption") != nil {
            return
        }

        // If the database is empty, just set the flag
        let count = countRecords(db: db)
        if count == 0 {
            writeMetadataValue(db: db, key: "path_encryption", value: "1")
            return
        }

        logger.info("Encrypting \(count) existing plaintext paths (v2→v3 migration)")

        // Load all records without decrypting
        let allRecords = try loadRecordsRaw(db: db)

        // Initialize encryption key
        let encryption = try PathEncryption()

        var encryptedRecords: [FileRecord] = []
        encryptedRecords.reserveCapacity(allRecords.count)

        for record in allRecords {
            if PathEncryption.looksEncrypted(record.path) && PathEncryption.looksEncrypted(record.parentPath) {
                encryptedRecords.append(record)
                continue
            }
            let encryptedPath = try encryption.encrypt(record.path)
            let encryptedParent = try encryption.encrypt(record.parentPath)
            encryptedRecords.append(FileRecord(
                id: record.id,
                name: record.name,
                originalName: record.originalName,
                path: encryptedPath,
                parentPath: encryptedParent,
                isDirectory: record.isDirectory,
                size: record.size,
                createdAt: record.createdAt,
                modifiedAt: record.modifiedAt,
                extension: record.extension,
                metadata: record.metadata
            ))
        }

        // Write encrypted records back via raw UPDATE
        try writeEncryptedRecords(db: db, records: encryptedRecords)

        // Set flag LAST — if we crash before this, next open will retry
        writeMetadataValue(db: db, key: "path_encryption", value: "1")
        logger.info("Path encryption migration complete: \(encryptedRecords.count) records encrypted")
    }

    // MARK: - Static SQLite Helpers

    /// Read a metadata value from the given database connection.
    public static func readMetadataValue(db: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Write a metadata key-value pair to the given database connection.
    public static func writeMetadataValue(db: OpaquePointer, key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        sqlite3_bind_text(stmt, 2, value, -1, SQLTransient)
        sqlite3_step(stmt)
    }

    /// Count records in the given database.
    public static func countRecords(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, "SELECT COUNT(*) FROM file_records", -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Load all records from the given database WITHOUT decrypting paths.
    public static func loadRecordsRaw(db: OpaquePointer) throws -> [FileRecord] {
        let sql = """
            SELECT id, name, original_name, path, parent_path, is_directory,
                   size, created_at, modified_at, ext, metadata_json
            FROM file_records
            """
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, prepRC)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [FileRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                records.append(recordFromStatementRaw(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw PersistenceError.stepFailed(rc)
            }
        }
        return records
    }

    /// Parse a row WITHOUT decrypting path/parent_path. Used during migration.
    public static func recordFromStatementRaw(_ stmt: OpaquePointer) -> FileRecord {
        let columns = parseColumns(from: stmt)
        return FileRecord(
            id: columns.id,
            name: columns.name,
            originalName: columns.originalName,
            path: String(cString: sqlite3_column_text(stmt, 3)),
            parentPath: String(cString: sqlite3_column_text(stmt, 4)),
            isDirectory: columns.isDirectory,
            size: columns.size,
            createdAt: columns.createdAt,
            modifiedAt: columns.modifiedAt,
            extension: columns.ext,
            metadata: columns.metadata
        )
    }

    /// Parse common columns (everything except path/parent_path) from a statement row.
    /// Used by both ``IndexPersistence/recordFromStatement`` (with decryption) and
    /// ``recordFromStatementRaw`` (without).
    public static func parseColumns(from stmt: OpaquePointer) -> (
        id: UInt32, name: String, originalName: String,
        isDirectory: Bool, size: Int64, createdAt: Date, modifiedAt: Date,
        ext: String?, metadata: ExtractedMetadata?
    ) {
        let metadata: ExtractedMetadata? = {
            guard sqlite3_column_type(stmt, 10) != SQLITE_NULL,
                  let jsonPtr = sqlite3_column_text(stmt, 10) else { return nil }
            let jsonStr = String(cString: jsonPtr)
            guard let data = jsonStr.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedMetadata.self, from: data)
        }()

        return (
            id: UInt32(sqlite3_column_int64(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            originalName: String(cString: sqlite3_column_text(stmt, 2)),
            isDirectory: sqlite3_column_int(stmt, 5) != 0,
            size: Int64(sqlite3_column_int64(stmt, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            ext: columnTextOrNil(stmt, 9),
            metadata: metadata
        )
    }

    /// Execute a raw SQL statement on a given connection.
    public static func execSQL(_ db: OpaquePointer?, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw PersistenceError.execFailed("\(sql) — \(msg)", rc)
        }
    }

    /// Read a TEXT column, returning nil if NULL.
    public static func columnTextOrNil(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, index))
    }

    // MARK: - Private Helpers

    /// Write already-encrypted records to the given database via raw UPDATE statements.
    private static func writeEncryptedRecords(db: OpaquePointer, records: [FileRecord]) throws {
        guard !records.isEmpty else { return }

        try execSQL(db, "BEGIN IMMEDIATE")

        let sql = "UPDATE file_records SET path = ?, parent_path = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else {
            try execSQL(db, "ROLLBACK")
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, record.path, -1, SQLTransient)
            sqlite3_bind_text(stmt, 2, record.parentPath, -1, SQLTransient)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(record.id))
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                try execSQL(db, "ROLLBACK")
                throw PersistenceError.execFailed("UPDATE path encryption migration — \(msg)", rc)
            }
        }

        try execSQL(db, "COMMIT")
    }

    /// Read column names for a table. Used by migrations to check for existing columns.
    private static func columnNames(in table: String, on db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            names.insert(name)
        }
        return names
    }
}
