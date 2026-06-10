/// # Persist Module
///
/// Durable storage layer for FileRecords and metadata using SQLite in WAL mode.
///
/// ## Components
/// - ``IndexPersistence`` -- actor-isolated SQLite wrapper for FileRecord CRUD
/// - ``SchemaMigrator`` -- schema versioning, migration, and static SQLite utilities
///
/// ## Design
/// - Database location: `~/.deep-finder/cache/index.db` (permissions 600)
/// - Journal mode: WAL (Write-Ahead Logging) for concurrent reads + serialized writes
/// - Batch writes: explicit transactions for throughput (INSERT OR REPLACE)
/// - Schema migration: versioned via `PRAGMA user_version` with transactional upgrades
/// - Metadata: media metadata stored as JSON in a `metadata_json` column (v2 schema)
/// - Event cursor: FSEventStream resume cursor persisted in a key-value metadata table
///
/// ## Startup
/// On daemon startup, all FileRecords are loaded from SQLite and the in-memory
/// index structures (Trie, FullSubstringMap, TrigramIndex, PinyinIndex) are rebuilt.
/// This typically takes < 1 second on M4 hardware.
///
/// ## Single-Process Assumption
/// Only one DeepFinder process should write to the database at a time.
/// WAL mode supports concurrent reads, but writes are serialized through
/// the single ``IndexPersistence`` actor instance.
import Foundation
import OSLog
import SQLite3
import DeepFinderIndex

// MARK: - SQLite Transient Constant

/// SQLite destructor constant that tells SQLite to copy the data before returning.
/// Equivalent to `SQLITE_TRANSIENT` from the C API.
/// Internal visibility: shared with ``SchemaMigrator`` in the same module.
public let SQLTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - IndexPersistence Errors

/// Errors thrown by ``IndexPersistence`` during SQLite operations.
public enum PersistenceError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String, Int32)
    case prepareFailed(String, Int32)
    case bindFailed(Int32)
    case stepFailed(Int32)
    case migrationFailed(String)

    public var description: String {
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
/// Stores FileRecord data durably on disk at `~/.deep-finder/cache/index.db`.
/// Index structures (Trie, FullSubstringMap, etc.) are rebuilt in memory on startup.
///
/// **Concurrency**: actor-isolated. All public methods are called from the actor's
/// executor, serializing access to the underlying SQLite connection.
///
/// **Single-process assumption**: Only one DeepFinder process should write to the
/// database at a time. WAL mode supports concurrent reads, but writes should be
/// serialized through this single actor instance.
///
/// **SQLite configuration**: WAL journal mode with `synchronous=NORMAL` for a balance
/// of durability and performance. The `-wal` and `-shm` files are co-located with the
/// main database file. On unclean shutdown, the WAL is replayed automatically by SQLite
/// on the next open.
public actor IndexPersistence {

    // MARK: - Logging

    /// Structured logger for persistence operations.
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

    // MARK: - State

    /// Opaque pointer to the SQLite database connection.
    /// Marked `nonisolated(unsafe)` because all access is serialized through
    /// this actor, and `deinit` (which is nonisolated) needs to reach it for cleanup.
    /// This is safe because: (1) actor deinit runs after all isolated methods complete,
    /// and (2) no other reference to `db` exists outside this actor.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Path to the database file. `nil` for in-memory databases.
    private let _dbPath: String?

    /// AES-256-GCM encryption for file paths. Initialized lazily via ``ensureEncryption()``
    /// so that in-memory databases (":memory:") skip secrets file access entirely.
    private var pathEncryption: PathEncryption?

    // MARK: - Init / Deinit

    /// Open (or create) the database at the given path.
    ///
    /// - Parameter dbPath: File path, or `":memory:"` for an in-memory database.
    /// - Throws: `PersistenceError` if the database cannot be opened or configured.
    public init(dbPath: String) throws {
        self._dbPath = dbPath == ":memory:" ? nil : dbPath

        logger.info("Opening database: \(dbPath, privacy: .public)")

        // Open database
        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbPath, &dbPtr, flags, nil)
        guard rc == SQLITE_OK, let db = dbPtr else {
            let msg = dbPtr.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            logger.error("Failed to open database: \(msg, privacy: .public)")
            sqlite3_close(dbPtr)
            throw PersistenceError.openFailed(msg)
        }
        self.db = db

        // Configure WAL mode and performance PRAGMAs
        try SchemaMigrator.execSQL(db, "PRAGMA journal_mode=WAL")
        try SchemaMigrator.execSQL(db, "PRAGMA synchronous=NORMAL")
        try SchemaMigrator.execSQL(db, "PRAGMA cache_size=-20000")
        try SchemaMigrator.execSQL(db, "PRAGMA temp_store=MEMORY")
        try SchemaMigrator.execSQL(db, "PRAGMA foreign_keys=ON")
        logger.debug("SQLite configured: WAL mode, synchronous=NORMAL")

        // Create tables
        try SchemaMigrator.execSQL(db, SchemaMigrator.createFileRecordsSQL)
        try SchemaMigrator.execSQL(db, SchemaMigrator.createMetadataSQL)

        // Run schema migration
        try SchemaMigrator.migrateSchema(on: db)
        logger.debug("Schema migration complete")

        // Initialize path encryption for on-disk databases.
        // In-memory databases (":memory:") skip secrets file access — paths are stored unencrypted.
        if _dbPath != nil {
            do {
                self.pathEncryption = try PathEncryption()
                logger.debug("Path encryption initialized")
            } catch {
                logger.error("Failed to initialize path encryption: \(error.localizedDescription, privacy: .public)")
                throw PersistenceError.openFailed("Path encryption init failed: \(error.localizedDescription)")
            }

            // Encrypt existing plaintext paths if migrating from v2 or earlier.
            // Static method called directly to avoid actor-isolated instance methods during init.
            try SchemaMigrator.migratePlaintextPathsIfNeeded(db: db)
        }

        // Set file permissions for on-disk databases
        if let path = _dbPath {
            try FileManager.default.setAttributes(
                [.posixPermissions: Product.privateFilePermissions],
                ofItemAtPath: path
            )
        }
        logger.info("Database opened successfully")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Public Accessors

    /// Path to the database file. `nil` for in-memory databases.
    public nonisolated var dbPath: String? { _dbPath }

    /// Close the database connection. Used by recovery before deleting WAL files.
    ///
    /// After calling this method, all subsequent operations on this instance will
    /// crash (nil pointer dereference on `db`). The caller must create a new
    /// ``IndexPersistence`` instance to reopen the database.
    public func close() {
        guard let db else { return }
        logger.info("Closing database")
        sqlite3_close(db)
        self.db = nil
        logger.info("Database closed")
    }

    // MARK: - Record Persistence

    /// Batch upsert FileRecords (INSERT OR REPLACE).
    ///
    /// Uses a prepared statement and explicit transaction for throughput.
    ///
    /// - Parameter records: The file records to insert or replace.
    /// - Note: Errors during the write are silently swallowed. This is intentional:
    ///   the in-memory index is the source of truth during normal operation, and
    ///   persistence is a durability best-effort layer. A failed batch write will
    ///   be naturally repaired on the next daemon restart (full rescan).
    public func saveRecords(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }

        logger.debug("Saving \(records.count) records to database")

        var transactionStarted = false
        do { try exec("BEGIN IMMEDIATE"); transactionStarted = true }
        catch {
            logger.warning("BEGIN IMMEDIATE failed in saveRecords: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer {
            if transactionStarted {
                do { try exec("COMMIT") }
                catch { logger.warning("COMMIT failed in saveRecords: \(error.localizedDescription, privacy: .public)") }
            }
        }

        let sql = """
            INSERT OR REPLACE INTO file_records
                (id, name, original_name, path, parent_path, is_directory, size, created_at, modified_at, ext, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            logger.error("Failed to prepare INSERT statement for saveRecords")
            return
        }
        defer { sqlite3_finalize(stmt) }

        for record in records {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, sqlite3_int64(record.id))
            sqlite3_bind_text(stmt, 2, record.name, -1, SQLTransient)
            sqlite3_bind_text(stmt, 3, record.originalName, -1, SQLTransient)
            // Encrypt path and parentPath for on-disk databases.
            // In-memory databases (nil pathEncryption) store paths unencrypted.
            if let encryption = pathEncryption {
                sqlite3_bind_text(stmt, 4, (try? encryption.encrypt(record.path)) ?? record.path, -1, SQLTransient)
                sqlite3_bind_text(stmt, 5, (try? encryption.encrypt(record.parentPath)) ?? record.parentPath, -1, SQLTransient)
            } else {
                sqlite3_bind_text(stmt, 4, record.path, -1, SQLTransient)
                sqlite3_bind_text(stmt, 5, record.parentPath, -1, SQLTransient)
            }
            sqlite3_bind_int(stmt, 6, record.isDirectory ? 1 : 0)
            sqlite3_bind_int64(stmt, 7, sqlite3_int64(record.size))
            sqlite3_bind_double(stmt, 8, record.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 9, record.modifiedAt.timeIntervalSince1970)
            if let ext = record.extension {
                sqlite3_bind_text(stmt, 10, ext, -1, SQLTransient)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            // Bind metadata_json
            if let metadata = record.metadata {
                if let jsonData = try? JSONEncoder().encode(metadata),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    sqlite3_bind_text(stmt, 11, jsonStr, -1, SQLTransient)
                } else {
                    logger.warning("Failed to encode metadata for record \(record.id) at \(record.path, privacy: .public)")
                    sqlite3_bind_null(stmt, 11)
                }
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            // sqlite3_step result intentionally ignored: INSERT OR REPLACE can only fail
            // on serious issues (disk full, corruption). The in-memory index remains
            // authoritative, and the next daemon restart will repair via full rescan.
            sqlite3_step(stmt)
        }
    }

    /// Load all FileRecords from the database.
    public func loadAllRecords() throws -> [FileRecord] {
        let sql = """
            SELECT id, name, original_name, path, parent_path, is_directory,
                   size, created_at, modified_at, ext, metadata_json
            FROM file_records
            """

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            let errCode = sqlite3_errcode(db)
            logger.error("Failed to prepare loadAllRecords statement: code \(errCode)")
            throw PersistenceError.prepareFailed(sql, errCode)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [FileRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let record = recordFromStatement(stmt) {
                    records.append(record)
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                logger.error("Failed to step during loadAllRecords: code \(rc)")
                throw PersistenceError.stepFailed(rc)
            }
        }
        logger.info("Loaded \(records.count) records from database")
        return records
    }

    /// Delete records by their IDs.
    ///
    /// - Parameter ids: The record IDs to delete.
    /// - Note: Silently returns on prepare failure. See ``saveRecords`` for rationale.
    public func deleteRecords(_ ids: [UInt32]) {
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
        // sqlite3_step result intentionally ignored. See saveRecords for rationale.
        sqlite3_step(stmt)
    }

    /// Delete all records whose path starts with the given prefix.
    ///
    /// Used when a volume is unmounted to remove all indexed files on that volume.
    /// Handles both the exact volume path and paths under it (with trailing slash).
    ///
    /// With path encryption active, this loads all records, decrypts paths,
    /// filters in-memory, and deletes by ID (AES-GCM nonces make SQL LIKE
    /// queries on ciphertext impossible).
    ///
    /// - Parameter pathPrefix: The mount point path of the volume (e.g. "/Volumes/USB Drive").
    /// - Returns: The number of deleted records.
    @discardableResult
    public func deleteRecordsByPathPrefix(_ pathPrefix: String) -> Int {
        // Without encryption, use the fast SQL path
        guard pathEncryption != nil else {
            let sql = "DELETE FROM file_records WHERE path = ? OR path LIKE ?"
            var stmt: OpaquePointer?
            guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pathPrefix, -1, SQLTransient)
            let likePrefix = pathPrefix.hasSuffix("/") ? pathPrefix + "%" : pathPrefix + "/%"
            sqlite3_bind_text(stmt, 2, likePrefix, -1, SQLTransient)
            sqlite3_step(stmt)
            return Int(sqlite3_changes(db))
        }

        // With encryption: load all records, decrypt, filter, delete by ID
        guard let allRecords = try? loadAllRecords() else {
            logger.warning("Failed to load records for path prefix deletion")
            return 0
        }

        let toDelete = allRecords.filter { record in
            record.path == pathPrefix || record.path.hasPrefix(pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/")
        }

        guard !toDelete.isEmpty else { return 0 }
        let ids = toDelete.map(\.id)
        deleteRecords(ids)
        logger.info("Deleted \(ids.count) records by path prefix (via in-memory decryption)")
        return ids.count
    }

    // MARK: - Event Cursor

    /// Persist the last FSEvent stream cursor for resumption.
    public func saveEventCursor(_ cursor: UInt64) {
        saveMetadata(key: "event_cursor", value: String(cursor))
    }

    /// Load the last FSEvent stream cursor, if any.
    public func loadEventCursor() -> UInt64? {
        guard let str = loadMetadata(key: "event_cursor") else { return nil }
        return UInt64(str)
    }

    // MARK: - Integrity & Maintenance

    /// Verify database integrity using PRAGMA integrity_check.
    public func verifyIntegrity() throws -> Bool {
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
    public func flush() throws {
        logger.debug("Flushing WAL checkpoint")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        logger.debug("WAL checkpoint complete")
    }

    /// Read the current schema version from PRAGMA user_version.
    public func schemaVersion() throws -> Int {
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
    public func readJournalMode() throws -> String {
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

    // MARK: - Internal Helpers

    /// Execute a raw SQL statement on an actor-isolated connection.
    private func exec(_ sql: String) throws {
        try SchemaMigrator.execSQL(db, sql)
    }

    /// Prepare a SQL statement on the actor-isolated connection.
    @discardableResult
    private func prepare(_ sql: String, _ stmt: inout OpaquePointer?) -> Int32 {
        sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil)
    }

    /// Parse a single row from a statement into a FileRecord.
    /// Decrypts path and parentPath if the database has path encryption enabled.
    /// Returns nil if decryption fails (e.g. corrupted ciphertext), allowing the
    /// caller to skip the record rather than ingesting garbage paths.
    private func recordFromStatement(_ stmt: OpaquePointer) -> FileRecord? {
        let columns = SchemaMigrator.parseColumns(from: stmt)

        let rawPath = String(cString: sqlite3_column_text(stmt, 3))
        let rawParentPath = String(cString: sqlite3_column_text(stmt, 4))

        // Decrypt paths if encryption is active (on-disk databases).
        // In-memory databases (nil pathEncryption) use paths as-is.
        let (path, parentPath): (String, String)
        if let encryption = pathEncryption {
            if let decrypted = try? encryption.decrypt(rawPath) {
                path = decrypted
            } else {
                logger.warning("Failed to decrypt path, skipping record: \(rawPath.prefix(20), privacy: .public)...")
                return nil
            }
            if let decrypted = try? encryption.decrypt(rawParentPath) {
                parentPath = decrypted
            } else {
                logger.warning("Failed to decrypt parent path, skipping record: \(rawParentPath.prefix(20), privacy: .public)...")
                return nil
            }
        } else {
            path = rawPath
            parentPath = rawParentPath
        }

        return FileRecord(
            id: columns.id,
            name: columns.name,
            originalName: columns.originalName,
            path: path,
            parentPath: parentPath,
            isDirectory: columns.isDirectory,
            size: columns.size,
            createdAt: columns.createdAt,
            modifiedAt: columns.modifiedAt,
            extension: columns.ext,
            metadata: columns.metadata
        )
    }

    // MARK: - Metadata Key-Value

    /// Store a key-value pair in the metadata table.
    ///
    /// Silently returns on failure. Metadata values (event cursor, etc.) are non-critical;
    /// a missed write means the daemon will rescan more aggressively on next startup.
    private func saveMetadata(key: String, value: String) {
        guard let db else { return }
        SchemaMigrator.writeMetadataValue(db: db, key: key, value: value)
    }

    /// Read a value from the metadata table.
    private func loadMetadata(key: String) -> String? {
        guard let db else { return nil }
        return SchemaMigrator.readMetadataValue(db: db, key: key)
    }
}
