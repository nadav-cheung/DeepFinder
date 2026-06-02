/// # Persist Module
///
/// Durable storage layer for FileRecords and metadata using SQLite in WAL mode.
///
/// ## Components
/// - ``IndexPersistence`` -- actor-isolated SQLite wrapper for FileRecord CRUD
/// - ``IndexRecovery`` -- database corruption detection and recovery utilities
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

// MARK: - SQLite Transient Constant

/// SQLite destructor constant that tells SQLite to copy the data before returning.
/// Equivalent to `SQLITE_TRANSIENT` from the C API.
private let SQLTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - IndexPersistence Errors

/// Errors thrown by ``IndexPersistence`` during SQLite operations.
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
/// on the next open, or manually via ``IndexRecovery.recoverFromWALCorruption()``.
actor IndexPersistence {

    // MARK: - Schema

    /// Current schema version. Bumped when the schema changes.
    /// v1: initial schema (id, name, original_name, path, parent_path, is_directory, size, created_at, modified_at, ext)
    /// v2: added metadata_json column (media metadata)
    /// v3: path encryption — path and parent_path columns now store AES-256-GCM ciphertext
    private static let currentSchemaVersion: Int = 3

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
            ext         TEXT,
            metadata_json TEXT
        )
        """

    /// SQL to create the metadata key-value table (cursor, etc.).
    private static let createMetadataSQL = """
        CREATE TABLE IF NOT EXISTS metadata (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """

    // MARK: - Logging

    /// Structured logger for persistence operations.
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

    /// Static logger for use in static methods that have no instance access.
    private static let staticLogger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

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
    init(dbPath: String) throws {
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
        try Self.execSQL(db, "PRAGMA journal_mode=WAL")
        try Self.execSQL(db, "PRAGMA synchronous=NORMAL")
        try Self.execSQL(db, "PRAGMA cache_size=-20000")
        try Self.execSQL(db, "PRAGMA temp_store=MEMORY")
        try Self.execSQL(db, "PRAGMA foreign_keys=ON")
        logger.debug("SQLite configured: WAL mode, synchronous=NORMAL")

        // Create tables
        try Self.execSQL(db, Self.createFileRecordsSQL)
        try Self.execSQL(db, Self.createMetadataSQL)

        // Run schema migration
        try Self.migrateSchema(on: db)
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
            // Fresh v3 databases handle this automatically (paths are encrypted on write).
            // Inlined to avoid calling actor-isolated methods from nonisolated init.
            try Self.migratePlaintextPathsIfNeeded(db: db)
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
    nonisolated var dbPath: String? { _dbPath }

    /// Close the database connection. Used by recovery before deleting WAL files.
    ///
    /// After calling this method, all subsequent operations on this instance will
    /// crash (nil pointer dereference on `db`). The caller must create a new
    /// ``IndexPersistence`` instance to reopen the database.
    func close() {
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
    func saveRecords(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }

        logger.debug("Saving \(records.count) records to database")

        var transactionStarted = false
        do { try exec("BEGIN IMMEDIATE"); transactionStarted = true }
        catch { logger.warning("BEGIN IMMEDIATE failed in saveRecords: \(error.localizedDescription, privacy: .public)") }
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
    func loadAllRecords() throws -> [FileRecord] {
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
    func deleteRecordsByPathPrefix(_ pathPrefix: String) -> Int {
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

    // MARK: - Metadata Batch Operations

    /// Batch save metadata for multiple files.
    ///
    /// Updates only the `metadata_json` column for the given file IDs.
    /// Uses a prepared statement and explicit transaction for throughput.
    ///
    /// - Parameter entries: Array of (fileID, metadata) pairs to update.
    /// - Note: Silently returns on prepare failure. See ``saveRecords`` for rationale.
    func saveMetadataBatch(_ entries: [(fileID: UInt32, metadata: ExtractedMetadata)]) {
        guard !entries.isEmpty else { return }

        do { try exec("BEGIN IMMEDIATE") }
        catch { logger.warning("BEGIN IMMEDIATE failed in saveMetadataBatch: \(error.localizedDescription, privacy: .public)") }
        defer {
            do { try exec("COMMIT") }
            catch { logger.warning("COMMIT failed in saveMetadataBatch: \(error.localizedDescription, privacy: .public)") }
        }

        let sql = "UPDATE file_records SET metadata_json = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        for entry in entries {
            sqlite3_reset(stmt)
            if let jsonData = try? encoder.encode(entry.metadata),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                sqlite3_bind_text(stmt, 1, jsonStr, -1, SQLTransient)
            } else {
                logger.warning("Failed to encode metadata for fileID \(entry.fileID)")
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(entry.fileID))
            // sqlite3_step result intentionally ignored. See saveRecords for rationale.
            sqlite3_step(stmt)
        }
    }

    /// Load all metadata entries from the database.
    ///
    /// Returns an array of (fileID, metadata) pairs for all records that have metadata.
    func loadAllMetadata() throws -> [(fileID: UInt32, metadata: ExtractedMetadata)] {
        let sql = "SELECT id, metadata_json FROM file_records WHERE metadata_json IS NOT NULL"

        var stmt: OpaquePointer?
        guard prepare(sql, &stmt) == SQLITE_OK, let stmt else {
            throw PersistenceError.prepareFailed(sql, sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()
        var results: [(fileID: UInt32, metadata: ExtractedMetadata)] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let fileID = UInt32(sqlite3_column_int64(stmt, 0))
                guard let jsonPtr = sqlite3_column_text(stmt, 1) else { continue }
                let jsonStr = String(cString: jsonPtr)
                guard let data = jsonStr.data(using: .utf8) else { continue }
                guard let metadata = try? decoder.decode(ExtractedMetadata.self, from: data) else {
                    logger.warning("Failed to decode metadata_json for record \(fileID)")
                    continue
                }
                results.append((fileID, metadata))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw PersistenceError.stepFailed(rc)
            }
        }
        return results
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
        logger.debug("Flushing WAL checkpoint")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
        logger.debug("WAL checkpoint complete")
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
            // v1 → v2: Add metadata_json column for media metadata
            if currentVersion < 2 { try migrateToV2(db) }
            // v2 → v3: Path encryption. No schema change (same columns), but existing
            // plaintext paths will be encrypted by ``encryptExistingPathsIfNeeded()``
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
    private static func readSchemaVersion(on db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, "PRAGMA user_version", -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Migrate schema from v1 to v2: add metadata_json column.
    private static func migrateToV2(_ db: OpaquePointer) throws {
        // Check if column already exists (handles CREATE TABLE IF NOT EXISTS with new column)
        let columns = columnNames(in: "file_records", on: db)
        if !columns.contains("metadata_json") {
            try execSQL(db, "ALTER TABLE file_records ADD COLUMN metadata_json TEXT")
        }
    }

    /// Migrate schema from v2 to v3: no schema change, just bump the version.
    ///
    /// Existing plaintext paths in the `path` and `parent_path` columns will be
    /// encrypted by ``encryptExistingPathsIfNeeded()`` after the migration transaction
    /// commits and the AES-256 key is loaded from secrets file.
    private static func migrateToV3(_ db: OpaquePointer) throws {
        // No ALTER TABLE needed — same columns, just encrypted at application layer.
        // The version bump happens in migrateSchema via PRAGMA user_version.
    }

    /// Encrypt existing plaintext paths if this database was migrated from v2 (or earlier).
    ///
    /// Called from ``init(dbPath:)`` as a nonisolated static method so it can be
    /// invoked synchronously from the actor's initializer.
    ///
    /// - Parameter db: The open SQLite database connection.
    private nonisolated static func migratePlaintextPathsIfNeeded(db: OpaquePointer) throws {
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

        staticLogger.info("Encrypting \(count) existing plaintext paths (v2→v3 migration)")

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
        staticLogger.info("Path encryption migration complete: \(encryptedRecords.count) records encrypted")
    }

    /// Read a metadata value from the given database connection.
    private nonisolated static func readMetadataValue(db: OpaquePointer, key: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Write a metadata key-value pair to the given database connection.
    private nonisolated static func writeMetadataValue(db: OpaquePointer, key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLTransient)
        sqlite3_bind_text(stmt, 2, value, -1, SQLTransient)
        sqlite3_step(stmt)
    }

    /// Count records in the given database.
    private nonisolated static func countRecords(db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, "SELECT COUNT(*) FROM file_records", -1, 0, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Load all records from the given database WITHOUT decrypting paths.
    private nonisolated static func loadRecordsRaw(db: OpaquePointer) throws -> [FileRecord] {
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
    private nonisolated static func recordFromStatementRaw(_ stmt: OpaquePointer) -> FileRecord {
        let metadata: ExtractedMetadata? = {
            guard sqlite3_column_type(stmt, 10) != SQLITE_NULL,
                  let jsonPtr = sqlite3_column_text(stmt, 10) else { return nil }
            let jsonStr = String(cString: jsonPtr)
            guard let data = jsonStr.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ExtractedMetadata.self, from: data)
        }()

        return FileRecord(
            id: UInt32(sqlite3_column_int64(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            originalName: String(cString: sqlite3_column_text(stmt, 2)),
            path: String(cString: sqlite3_column_text(stmt, 3)),
            parentPath: String(cString: sqlite3_column_text(stmt, 4)),
            isDirectory: sqlite3_column_int(stmt, 5) != 0,
            size: Int64(sqlite3_column_int64(stmt, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            extension: columnTextOrNil(stmt, 9),
            metadata: metadata
        )
    }

    /// Write already-encrypted records to the given database via raw UPDATE statements.
    private nonisolated static func writeEncryptedRecords(db: OpaquePointer, records: [FileRecord]) throws {
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
    /// Decrypts path and parentPath if the database has path encryption enabled.
    /// Returns nil if decryption fails (e.g. corrupted ciphertext), allowing the
    /// caller to skip the record rather than ingesting garbage paths.
    private func recordFromStatement(_ stmt: OpaquePointer) -> FileRecord? {
        let metadata: ExtractedMetadata? = {
            guard sqlite3_column_type(stmt, 10) != SQLITE_NULL,
                  let jsonPtr = sqlite3_column_text(stmt, 10) else { return nil }
            let jsonStr = String(cString: jsonPtr)
            guard let data = jsonStr.data(using: .utf8) else { return nil }
            if let decoded = try? JSONDecoder().decode(ExtractedMetadata.self, from: data) {
                return decoded
            }
            logger.warning("Failed to decode metadata_json for record in recordFromStatement — dropping metadata")
            return nil
        }()

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
            id: UInt32(sqlite3_column_int64(stmt, 0)),
            name: String(cString: sqlite3_column_text(stmt, 1)),
            originalName: String(cString: sqlite3_column_text(stmt, 2)),
            path: path,
            parentPath: parentPath,
            isDirectory: sqlite3_column_int(stmt, 5) != 0,
            size: Int64(sqlite3_column_int64(stmt, 6)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            extension: Self.columnTextOrNil(stmt, 9),
            metadata: metadata
        )
    }

    /// Read a TEXT column, returning nil if NULL.
    private static func columnTextOrNil(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, index))
    }

    // MARK: - Metadata Key-Value

    /// Store a key-value pair in the metadata table.
    ///
    /// Silently returns on failure. Metadata values (event cursor, etc.) are non-critical;
    /// a missed write means the daemon will rescan more aggressively on next startup.
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
