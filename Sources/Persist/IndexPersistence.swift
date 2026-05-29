import Foundation
import SQLite3

// MARK: - SQLite Transient Constant

/// SQLite destructor constant that tells SQLite to copy the data before returning.
/// Equivalent to `SQLITE_TRANSIENT` from the C API.
private let SQLTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - IndexPersistence Errors

enum PersistenceError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String, Int32)
    case prepareFailed(String, Int32)
    case bindFailed(Int32)
    case stepFailed(Int32)
    case migrationFailed(String)

    var description: String {
        switch self {
        case .openFailed(let msg):
            return "Failed to open database: \(msg)"
        case .execFailed(let sql, let code):
            return "Failed to execute '\(sql)': \(code)"
        case .prepareFailed(let sql, let code):
            return "Failed to prepare '\(sql)': \(code)"
        case .bindFailed(let code):
            return "Failed to bind parameter: \(code)"
        case .stepFailed(let code):
            return "Failed to step: \(code)"
        case .migrationFailed(let msg):
            return "Migration failed: \(msg)"
        }
    }
}

// MARK: - IndexPersistence

/// SQLite WAL persistence layer for FileRecords.
///
/// Stores FileRecord data durably on disk at `~/.deep-finder/index.db`.
/// Index structures (Trie, FullSubstringMap, etc.) are rebuilt in memory on startup.
///
/// **Concurrency**: actor-isolated. All public methods are called from the actor's
/// executor, serializing access to the underlying SQLite connection.
///
/// **Single-process assumption**: Only one DeepFinder process should write to the
/// database at a time. WAL mode supports concurrent reads, but writes should be
/// serialized through this single actor instance.
actor IndexPersistence {

    // MARK: - Schema

    /// Current schema version. Bumped when the schema changes.
    private static let currentSchemaVersion: Int = 1

    /// SQL to create the file_records table.
    private static let createFileRecordsSQL = """
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
            ext         TEXT
        )
        """

    /// SQL to create the metadata key-value table (cursor, etc.).
    private static let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """

    // MARK: - State

    /// Opaque pointer to the SQLite database connection.
    /// Marked `nonisolated(unsafe)` because all access is serialized through
    /// this actor, and `deinit` needs to reach it for cleanup.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Path to the database file. `nil` for in-memory databases.
    private let _dbPath: String?

    // MARK: - Init / Deinit

    /// Open (or create) the database at the given path.
    ///
    /// - Parameter dbPath: File path, or `":memory:"` for an in-memory database.
    /// - Throws: `PersistenceError` if the database cannot be opened or configured.
    init(dbPath: String) throws {
        self._dbPath = dbPath == ":memory:" ? nil : dbPath

        // Open database
        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbPath, &dbPtr, flags, nil)
        guard rc == SQLITE_OK, let db = dbPtr else {
            let msg = dbPtr.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPtr)
            throw PersistenceError.openFailed(msg)
        }
        self.db = db

        // Configure WAL mode and performance PRAGMAs
        try Self.execSQL(db, "PRAGMA journal_mode=WAL")
        try Self.execSQL(db, "PRAGMA synchronous=NORMAL")
        try Self.execSQL(db, "PRAGMA cache_size=-20000")
        try Self.execSQL(db, "PRAGMA temp_store=MEMORY")
        try Self.execSQL(db, "PRAGMA foreign_keys=ON")

        // Create tables
        try Self.execSQL(db, Self.createFileRecordsSQL)
        try Self.execSQL(db, Self.createMetadataSQL)

        // Run schema migration
        try Self.migrateSchema(on: db)

        // Set file permissions for on-disk databases
        if let path = _dbPath {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Public Accessors

    /// Path to the database file. `nil` for in-memory databases.
    nonisolated var dbPath: String? { _dbPath }

    /// Close the database connection. Used by recovery before deleting WAL files.
    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    // MARK: - Record Persistence

    /// Batch upsert FileRecords (INSERT OR REPLACE).
    ///
    /// Uses a prepared statement and explicit transaction for throughput.
    func saveRecords(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }

        try? exec("BEGIN IMMEDIATE")
        defer { try? exec("COMMIT") }

        let sql = """
            INSERT OR REPLACE INTO file_records
                (id, name, original_name, path, parent_path, is_directory, size, created_at, modified_at, ext)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(record.id))
            sqlite3_bind_text(stmt, 2, record.name, -1, SQLTransient)
            sqlite3_bind_text(stmt, 3, record.originalName, -1, SQLTransient)
            sqlite3_bind_text(stmt, 4, record.path, -1, SQLTransient)
            sqlite3_bind_text(stmt, 5, record.parentPath, -1, SQLTransient)
            sqlite3_bind_int(stmt, 6, record.isDirectory ? 1 : 0)
            sqlite3_bind_int64(stmt, 7, sqlite3_int64(record.size))
            sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, record.modifiedAt.timeIntervalSince1970)
            if let ext = record.extension {
                sqlite3_bind_text(stmt, 10, ext, -1, SQLTransient)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_step(stmt)
        }
    }

    /// Load all FileRecords from the database.
    func loadAllRecords() throws -> [FileRecord] {
        let sql = """
            SELECT id, name, original_name, path, parent_path, is_directory,
                   size, created_at, modified_at, ext
            FROM file_records
            """

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        var records: [FileRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                records.append(Self.recordFromStatement(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw PersistenceError.stepFailed(rc)
            }
        }
        return records
    }

    /// Delete records by their IDs.
    func deleteRecords(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }

        // Build parameterized IN clause
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM file_records WHERE id IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), sqlite3_int64(id))
        }
        sqlite3_step(stmt)
    }

    // MARK: - Event Cursor

    /// Persist the last FSEvent stream cursor for resumption.
    func saveEventCursor(_ cursor: UInt64) {
        saveMetadata(key: "event_cursor", value: String(cursor))
    }

    /// Load the last FSEvent stream cursor, if any.
    func loadEventCursor() -> UInt64? {
        guard let str = loadMetadata(key: "event_cursor") else { return nil }
        return UInt64(str)
    }

    // MARK: - Integrity & Maintenance

    /// Verify database integrity using PRAGMA integrity_check.
    func verifyIntegrity() throws -> Bool {
        var stmt: OpaquePointer?
        let sql = "PRAGMA integrity_check"
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return false }

        let result = String(cString: sqlite3_column_text(stmt, 0))
        return result == "ok"
    }

    /// Force a WAL checkpoint (TRUNCATE mode).
    func flush() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Read the current schema version from PRAGMA user_version.
    func schemaVersion() throws -> Int {
        var stmt: OpaquePointer?
        let sql = "PRAGMA user_version"
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Read the current journal_mode from the database.
    func readJournalMode() throws -> String {
        var stmt: OpaquePointer?
        let sql = "PRAGMA journal_mode"
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return "unknown" }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    // MARK: - Schema Migration

    /// Run schema migrations in a transaction.
    ///
    /// Uses `PRAGMA user_version` to track the current schema version.
    /// Each migration step runs inside a transaction; on failure the transaction
    /// is rolled back and the database is marked as corrupted.
    private static func migrateSchema(on db: OpaquePointer) throws {
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
            // Future migrations go here:
            // if currentVersion < 2 { try migrateToV2(db) }
            // if currentVersion < 3 { try migrateToV3(db) }

            // Update schema version
            try execSQL(db, "PRAGMA user_version = \(currentSchemaVersion)")
            try execSQL(db, "COMMIT")
        } catch {
            try? execSQL(db, "ROLLBACK")
            throw PersistenceError.migrationFailed(error.localizedDescription)
        }
    }

    /// Read PRAGMA user_version from the given connection.
    private static func readSchemaVersion(on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, "PRAGMA user_version", -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Internal Helpers

    /// Execute a raw SQL statement on an actor-isolated connection.
    private func exec(_ sql: String) throws {
        try Self.execSQL(db, sql)
    }

    /// Execute a raw SQL statement on a given connection (non-isolated).
    private static func execSQL(_ db: OpaquePointer?, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw PersistenceError.execFailed("\(sql) — \(msg)", rc)
        }
    }

    /// Prepare a SQL statement on the actor-isolated connection.
    @discardableResult
    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Int32 {
        sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil)
    }

    /// Parse a single row from a statement into a FileRecord.
    private static func recordFromStatement(_ stmt: OpaquePointer) -> FileRecord {
        FileRecord(
            id: UInt32(sqlite3_column_int64(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            originalName: String(cString: sqlite3_column_text(stmt, 2)),
            path: String(cString: sqlite3_column_text(stmt, 3)),
            parentPath: String(cString: sqlite3_column_text(stmt, 4)),
            isDirectory: sqlite3_column_int(stmt, 5) != 0,
            size: Int64(sqlite3_column_int64(stmt, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            extension: columnTextOrNil(stmt, 9)
        )
    }

    /// Read a TEXT column, returning nil if NULL.
    private static func columnTextOrNil(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, index))
    }

    // MARK: - Metadata Key-Value

    /// Store a key-value pair in the metadata table.
    private func saveMetadata(key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        sqlite3_bind_text(stmt, 2, value, -1, SQLTransient)
        sqlite3_step(stmt)
    }

    /// Read a value from the metadata table.
    private func loadMetadata(key: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
}
