// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # Persist Module
///
/// Durable storage layer for FileRecords and metadata, backed by the binary
/// `index.bin` snapshot format (P3 refactor — replaces the previous SQLite WAL
/// layer). The on-disk layout and atomicity guarantees are owned by
/// ``BinaryIndex``; this actor is the daemon-facing facade that preserves the
/// original public API (call sites in `DaemonMain` / `FSEventWatcher` are
/// unchanged).
///
/// ## Components
/// - ``IndexPersistence`` -- actor-isolated facade over ``BinaryIndex``
/// - ``BinaryIndex`` -- standalone binary snapshot engine (`index.bin`)
/// - ``SchemaMigrator`` -- retained for the P4 SQLite→binary migration; no
///   longer used by the live write path
///
/// ## Files
/// - `~/.deep-finder/cache/index.bin` -- full FileRecord snapshot (atomic
///   tmp-write + fsync + rename rewrite on every ``saveRecords``)
/// - `~/.deep-finder/cache/index.cursor` -- FSEvents resume cursor sidecar,
///   updated independently via ``saveEventCursor``
///
/// ## Startup
/// On daemon startup, all FileRecords are parsed from `index.bin` and the
/// in-memory C index is rebuilt. This typically takes < 1 second on M4
/// hardware. A missing file (first run) parses as `[]`.
///
/// ## Single-Process Assumption
/// Only the daemon writes to `index.bin`. There is no concurrent-reader model
/// like SQLite WAL provided; the daemon is the sole writer and reader.
import Foundation
import OSLog
import SQLite3
import DeepFinderIndex

// MARK: - SQLite Transient Constant

/// SQLite destructor constant that tells SQLite to copy the data before returning.
/// Equivalent to `SQLITE_TRANSIENT` from the C API.
/// Retained for the P4 SQLite→binary migration: ``SchemaMigrator`` (still
/// referenced by the migration path) depends on it. Once P4 removes
/// SchemaMigrator this can be deleted along with the `import SQLite3`.
public let SQLTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - IndexPersistence Errors

/// Errors thrown by ``IndexPersistence`` during open / IO operations.
///
/// Most public methods are best-effort and swallow IO errors (the in-memory
/// index is authoritative; a failed write self-heals on the next rescan).
/// This type is surfaced only at construction time and from the few `throws`
/// accessors that callers depend on.
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

/// Binary snapshot persistence facade for FileRecords.
///
/// Stores FileRecord data durably on disk at `~/.deep-finder/cache/index.bin`
/// via the ``BinaryIndex`` engine. Index structures (Trie, FullSubstringMap,
/// etc.) are rebuilt in memory on startup.
///
/// **Concurrency**: actor-isolated. All public methods are called from the
/// actor's executor, serializing access to the underlying engine.
///
/// **Single-process assumption**: only the daemon writes to the index. There
/// is no second-writer / concurrent-reader protocol; a single
/// ``IndexPersistence`` instance per daemon process is the contract.
///
/// **Write semantics**: every ``saveRecords(_:)`` is an atomic full-snapshot
/// rewrite (serialize → tmp file → chmod 600 → fsync → rename). A crash leaves
/// either the complete previous file or the complete new file, never a torn
/// write. The FSEvents cursor lives in a separate `index.cursor` sidecar so it
/// can be updated without rewriting the snapshot.
public actor IndexPersistence {

    // MARK: - Logging

    /// Structured logger for persistence operations.
    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

    // MARK: - State

    /// Underlying binary engine. `nil` only after ``close()``.
    private var engine: BinaryIndex?

    /// Logical database path supplied by the caller (the `.db` path). Returned
    /// by ``dbPath`` for compatibility; the actual on-disk artifact is
    /// ``binPath``. `nil` for in-memory databases.
    private let _dbPath: String?

    /// Derived `index.bin` path (or a unique temp file for `:memory:` mode).
    private let binPath: String

    /// Unique temp file path used when running in `:memory:` mode, so it can be
    /// cleaned up in ``close()`` / `deinit`. `nil` for on-disk databases.
    private let memoryTempPath: String?

    /// AES-256-GCM encryption for file paths. `nil` for in-memory databases
    /// (which never touch disk and therefore store paths in plaintext).
    private let pathEncryption: PathEncryption?

    // MARK: - Init / Deinit

    /// Open (or prepare to create) the binary index at the given path.
    ///
    /// - Parameter dbPath: File path ending in `.db` (the `.bin` snapshot path
    ///   is derived from it), or `":memory:"` for an ephemeral plaintext index
    ///   backed by a unique temp file under `NSTemporaryDirectory()`.
    /// - Throws: `PersistenceError.openFailed` if path encryption cannot be
    ///   initialized for an on-disk database (fail-closed).
    public init(dbPath: String) throws {
        logger.info("Opening binary index: \(dbPath, privacy: .public)")

        if dbPath == ":memory:" {
            self._dbPath = nil
            let tmp = NSTemporaryDirectory() + "df-mem-\(UUID().uuidString).bin"
            self.binPath = tmp
            self.memoryTempPath = tmp
            self.pathEncryption = nil
        } else {
            self._dbPath = dbPath
            self.binPath = IndexPersistence.binPath(for: dbPath)
            self.memoryTempPath = nil
            do {
                self.pathEncryption = try PathEncryption()
                logger.debug("Path encryption initialized")
            } catch {
                logger.error("Failed to initialize path encryption: \(error.localizedDescription, privacy: .public)")
                throw PersistenceError.openFailed("Path encryption init failed: \(error.localizedDescription)")
            }
        }

        self.engine = try BinaryIndex(path: binPath, pathEncryption: pathEncryption)
        logger.info("Binary index ready at \(self.binPath, privacy: .public)")
    }

    deinit {
        // The engine has no open handles between calls (each save/load reopens
        // the file), so there is nothing to release — but a leftover :memory:
        // temp file should not survive the instance.
        if let memoryTempPath {
            try? FileManager.default.removeItem(atPath: memoryTempPath)
        }
    }

    // MARK: - Public Accessors

    /// Path to the logical database file (the `.db` path). `nil` for in-memory
    /// databases. Kept for compatibility with callers that read this property.
    public nonisolated var dbPath: String? { _dbPath }

    /// Release the engine and clean up the temp file for `:memory:` mode.
    public func close() {
        logger.info("Closing binary index")
        engine = nil
        if let memoryTempPath {
            try? FileManager.default.removeItem(atPath: memoryTempPath)
        }
        logger.info("Binary index closed")
    }

    // MARK: - Record Persistence

    /// Atomic full-snapshot rewrite of the index.
    ///
    /// The current FSEvents cursor (if any) is preserved across the save so a
    /// post-scan snapshot does not reset the resume point.
    ///
    /// - Parameter records: The full set of file records to persist.
    /// - Note: IO errors are swallowed with a warning. The in-memory index is
    ///   authoritative; a failed write self-heals on the next daemon rescan.
    public func saveRecords(_ records: [FileRecord]) {
        guard !records.isEmpty else { return }
        guard let engine else {
            logger.warning("saveRecords called after close; ignoring")
            return
        }
        logger.debug("Saving \(records.count) records to binary index")
        let cursor = (try? engine.loadCursor()) ?? nil
        do {
            try engine.save(records, cursor: cursor)
        } catch {
            logger.warning("saveRecords failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load all FileRecords from the binary index.
    ///
    /// Returns `[]` if the file is absent (first run). Throws on a structurally
    /// corrupt or truncated file — the daemon's recovery path is expected to
    /// have removed such a file before this is reached.
    public func loadAllRecords() throws -> [FileRecord] {
        guard let engine else {
            logger.warning("loadAllRecords called after close; returning []")
            return []
        }
        let records = try engine.load()
        logger.info("Loaded \(records.count) records from binary index")
        return records
    }

    /// Delete records by their IDs (load → filter → atomic re-save).
    ///
    /// - Parameter ids: The record IDs to delete.
    /// - Note: Best-effort — errors are swallowed with a warning.
    public func deleteRecords(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        guard let engine else {
            logger.warning("deleteRecords called after close; ignoring")
            return
        }
        do {
            _ = try engine.deleteRecords(Set(ids))
        } catch {
            logger.warning("deleteRecords failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Delete all records whose path starts with the given prefix (volume
    /// unmount path). Returns the count removed.
    ///
    /// - Parameter pathPrefix: The mount point path of the volume.
    /// - Returns: The number of deleted records (0 on error or no match).
    @discardableResult
    public func deleteRecordsByPathPrefix(_ pathPrefix: String) -> Int {
        guard let engine else {
            logger.warning("deleteRecordsByPathPrefix called after close; returning 0")
            return 0
        }
        do {
            return try engine.deleteByPathPrefix(pathPrefix)
        } catch {
            logger.warning("deleteRecordsByPathPrefix failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Event Cursor

    /// Persist the last FSEvent stream cursor for resumption (sidecar write,
    /// does not touch `index.bin`).
    public func saveEventCursor(_ cursor: UInt64) {
        guard let engine else {
            logger.warning("saveEventCursor called after close; ignoring")
            return
        }
        do {
            try engine.saveCursor(cursor)
        } catch {
            logger.warning("saveEventCursor failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load the last FSEvent stream cursor, if any. Returns `nil` on absence
    /// or any read/parse error.
    public func loadEventCursor() -> UInt64? {
        guard let engine else { return nil }
        return (try? engine.loadCursor()) ?? nil
    }

    // MARK: - Integrity & Maintenance

    /// Verify the binary index header (magic + supported version). Returns
    /// `true` if the file is absent or has a valid header; `false` if it exists
    /// but is structurally corrupt or an unsupported version.
    public func verifyIntegrity() throws -> Bool {
        return BinaryIndex.validateHeader(at: binPath)
    }

    /// No-op for the binary format (every save is already atomic + fsync'd).
    /// Logs a debug line; does not throw unless something is genuinely wrong.
    public func flush() throws {
        logger.debug("flush() — binary writes are already atomic+fsync'd; no-op")
    }

    /// Binary format version. Always `1` for this build.
    public func schemaVersion() throws -> Int {
        return 1
    }

    /// Journal mode identifier. Always `"binary"` for this backend.
    public func readJournalMode() throws -> String {
        return "binary"
    }

    // MARK: - Path Helpers

    /// Derive the `index.bin` path from a logical `.db` path. Replaces a `.db`
    /// suffix with `.bin`; otherwise appends `.bin`. Shared with
    /// ``IndexRecovery`` so both layers agree on the derived path.
    static func binPath(for dbPath: String) -> String {
        if dbPath.hasSuffix(".db") {
            let end = dbPath.index(dbPath.endIndex, offsetBy: -3)
            return dbPath[..<end] + ".bin"
        }
        return dbPath + ".bin"
    }
}
