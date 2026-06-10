/// # IndexRecovery
///
/// Startup recovery logic for the SQLite index database.
///
/// Runs before ``IndexPersistence`` is opened to detect and repair problems:
/// - WAL/SHM file cleanup from unclean shutdown
/// - Database integrity verification via `PRAGMA integrity_check`
/// - Auto-rebuild from scratch when corruption is detected
/// - Schema incompatibility detection (downgrade protection)
/// - Stale lock file detection (crashed daemon PID file)
///
/// All recovery actions are logged via OSLog for debugging.
import Foundation
import OSLog
import SQLite3
import DeepFinderIndex

// MARK: - IndexRecoveryError

/// Failure modes detected or thrown during index recovery.
public enum IndexRecoveryError: Error, CustomStringConvertible {
    /// The database file is corrupted and cannot be repaired.
    case corruptionDetected(String)
    /// The database schema is from a newer version of the app.
    case schemaIncompatibility(current: Int, required: Int)
    /// WAL checkpoint failed during cleanup.
    case checkpointFailed(String)
    /// Recovery completed by deleting and recreating the database.
    case rebuiltFromScratch(String)

    public var description: String {
        switch self {
        case .corruptionDetected(let detail):
            return "Database corruption detected: \(detail)"
        case .schemaIncompatibility(let current, let required):
            return "Database schema v\(current) is newer than app v\(required). Please delete the index and rebuild."
        case .checkpointFailed(let detail):
            return "WAL checkpoint failed: \(detail)"
        case .rebuiltFromScratch(let path):
            return "Database rebuilt from scratch: \(path)"
        }
    }
}

// MARK: - IndexRecovery

/// Static utility for detecting and recovering from index database problems.
///
/// Called during daemon startup, before ``IndexPersistence`` opens the database.
/// All methods are static — no instance state needed.
///
/// ## Usage in DaemonMain
/// ```swift
/// // Before opening IndexPersistence:
/// try IndexRecovery.cleanupWALFiles(dbDirectory: dbDir)
/// if !IndexRecovery.verifyIntegrity(dbPath: dbPath) {
///     try IndexRecovery.recover(dbPath: dbPath, dbDirectory: dbDir)
/// }
/// ```
public enum IndexRecovery {

    // MARK: - Logging

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "recovery")

    // MARK: - Integrity Check

    /// Verify the SQLite database at the given path is readable and not corrupted.
    ///
    /// Opens the database, runs `PRAGMA integrity_check`, and closes it.
    /// Returns `false` if the file doesn't exist (not an error — first run),
    /// the database can't be opened, or the integrity check returns anything other than "ok".
    ///
    /// Uses `SQLITE_OPEN_READWRITE` (not read-only) because WAL-mode databases need
    /// to create/access the SHM file, which requires write access. This is safe because
    /// the daemon holds the PID file lock exclusively when recovery runs.
    ///
    /// - Parameter dbPath: Absolute path to the SQLite database file.
    /// - Returns: `true` if the database is healthy, `false` if missing or corrupted.
    public static func verifyIntegrity(dbPath: String) -> Bool {
        let fm = FileManager.default

        // Missing database is not corruption — first run or clean state
        guard fm.fileExists(atPath: dbPath) else {
            logger.info("No database file at \(dbPath, privacy: .public) — first run or clean state")
            return true
        }

        logger.debug("Verifying database integrity: \(dbPath, privacy: .public)")

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            logger.error("Cannot open database for integrity check: \(msg, privacy: .public)")
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        // Run PRAGMA integrity_check
        var stmt: OpaquePointer?
        let sql = "PRAGMA integrity_check"
        guard sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil) == SQLITE_OK, let stmt else {
            logger.error("Failed to prepare integrity_check statement")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else {
            logger.error("integrity_check returned no rows (code \(stepRC))")
            return false
        }

        let result = String(cString: sqlite3_column_text(stmt, 0))
        if result == "ok" {
            logger.debug("Database integrity check passed")
            return true
        } else {
            logger.error("Database integrity check FAILED: \(result, privacy: .public)")
            return false
        }
    }

    // MARK: - Schema Compatibility

    /// Check if the database schema version is compatible with this version of the app.
    ///
    /// Returns `true` if the schema is compatible (same version or older).
    /// Returns `false` if the schema is from a newer version (downgrade scenario)
    /// or if the database cannot be read.
    ///
    /// Uses `SQLITE_OPEN_READWRITE` because WAL-mode databases need write access
    /// to create/access the SHM file. Safe because the daemon holds the PID lock.
    ///
    /// - Parameter dbPath: Absolute path to the SQLite database file.
    /// - Returns: `true` if the schema is compatible.
    public static func verifySchemaCompatibility(dbPath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return true }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        let version = SchemaMigrator.readSchemaVersion(on: db)
        let currentVersion = SchemaMigrator.currentSchemaVersion

        if version > currentVersion {
            logger.error("Schema incompatibility: database v\(version) > app v\(currentVersion)")
            return false
        }

        logger.debug("Schema compatible: database v\(version), app v\(currentVersion)")
        return true
    }

    // MARK: - Recovery

    /// Recover from database corruption by deleting and recreating from scratch.
    ///
    /// This removes the main database file, WAL file, and SHM file, then lets
    /// ``IndexPersistence`` create a fresh database on the next open.
    ///
    /// - Parameters:
    ///   - dbPath: Absolute path to the SQLite database file.
    ///   - dbDirectory: Directory containing the database file (for WAL/SHM cleanup).
    /// - Throws: ``IndexRecoveryError`` if recovery fails.
    public static func recover(dbPath: String, dbDirectory: String) throws {
        logger.warning("Starting database recovery for \(dbPath, privacy: .public)")

        let fm = FileManager.default

        // Remove the main database file
        if fm.fileExists(atPath: dbPath) {
            do {
                try fm.removeItem(atPath: dbPath)
                logger.info("Removed corrupted database: \(dbPath, privacy: .public)")
            } catch {
                logger.error("Failed to remove corrupted database: \(error.localizedDescription, privacy: .public)")
                throw IndexRecoveryError.corruptionDetected("Cannot remove database file: \(error.localizedDescription)")
            }
        }

        // Remove WAL and SHM files
        cleanupWALFiles(dbDirectory: dbDirectory)

        // Verify the files are gone
        if fm.fileExists(atPath: dbPath) {
            throw IndexRecoveryError.corruptionDetected("Database file still exists after deletion")
        }

        logger.info("Database recovery complete — index will rebuild from scratch")
    }

    // MARK: - WAL Cleanup

    /// Remove WAL and SHM files left over from an unclean shutdown.
    ///
    /// SQLite normally replays the WAL on the next open, but if the WAL itself
    /// is corrupted, removing it allows a clean start (data in the WAL is lost,
    /// but the main database file is intact).
    ///
    /// Also attempts a WAL checkpoint before removing files, as a best-effort
    /// attempt to preserve data. If the checkpoint fails, falls back to deletion.
    ///
    /// - Parameter dbDirectory: Directory containing the database and its WAL/SHM files.
    public static func cleanupWALFiles(dbDirectory: String) {
        let fm = FileManager.default
        let dbName = "index.db"

        let walPath = (dbDirectory as NSString).appendingPathComponent(dbName + "-wal")
        let shmPath = (dbDirectory as NSString).appendingPathComponent(dbName + "-shm")
        let dbPath = (dbDirectory as NSString).appendingPathComponent(dbName)

        // Attempt checkpoint if the database and WAL exist
        if fm.fileExists(atPath: dbPath) && fm.fileExists(atPath: walPath) {
            if checkpointWAL(dbPath: dbPath) {
                logger.debug("WAL checkpoint succeeded — WAL data preserved")
            } else {
                logger.warning("WAL checkpoint failed — will delete WAL files (uncommitted data lost)")
            }
        }

        // Remove WAL file
        if fm.fileExists(atPath: walPath) {
            do {
                try fm.removeItem(atPath: walPath)
                logger.info("Removed WAL file: \(walPath, privacy: .public)")
            } catch {
                logger.warning("Failed to remove WAL file: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Remove SHM file
        if fm.fileExists(atPath: shmPath) {
            do {
                try fm.removeItem(atPath: shmPath)
                logger.info("Removed SHM file: \(shmPath, privacy: .public)")
            } catch {
                logger.warning("Failed to remove SHM file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Stale Lock Detection

    /// Detect whether a stale PID file exists (indicating a crashed daemon).
    ///
    /// Reads the PID file, checks if the process is alive via `kill(pid, 0)`.
    /// If the process is dead, the PID file is stale and should be cleaned up.
    ///
    /// - Parameter pidPath: Absolute path to the PID file.
    /// - Returns: `true` if a stale PID file was found and cleaned up.
    public static func detectStaleLock(pidPath: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pidPath) else { return false }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let pidString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else {
            // Corrupted PID file — remove it
            logger.info("Removing corrupted PID file: \(pidPath, privacy: .public)")
            try? fm.removeItem(atPath: pidPath)
            return true
        }

        // Check if process is alive
        let alive = kill(pid, 0) == 0
        if alive {
            logger.debug("PID file references live process \(pid) — not stale")
            return false
        }

        // Stale — process is dead
        logger.info("Stale PID file detected (PID \(pid) is dead): \(pidPath, privacy: .public)")
        do {
            try fm.removeItem(atPath: pidPath)
            logger.info("Removed stale PID file")
        } catch {
            logger.warning("Failed to remove stale PID file: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    // MARK: - Full Startup Recovery

    /// Run the full recovery sequence on the database directory.
    ///
    /// This is the main entry point for daemon startup. It:
    /// 1. Cleans up stale lock files
    /// 2. Cleans up WAL/SHM files
    /// 3. Checks database integrity
    /// 4. Checks schema compatibility
    /// 5. Auto-recovers from corruption if needed
    ///
    /// - Parameters:
    ///   - dbPath: Absolute path to the SQLite database file.
    ///   - dbDirectory: Directory containing the database file.
    ///   - pidPath: Absolute path to the PID file.
    /// - Throws: ``IndexRecoveryError`` if recovery fails or schema is incompatible.
    public static func runStartupRecovery(dbPath: String, dbDirectory: String, pidPath: String) throws {
        logger.info("Running startup recovery sequence")

        // 1. Detect and clean stale lock files
        let staleLock = detectStaleLock(pidPath: pidPath)
        if staleLock {
            logger.info("Cleaned up stale daemon lock file")
        }

        // 2. Clean up WAL and SHM files
        cleanupWALFiles(dbDirectory: dbDirectory)

        // 3. Check schema compatibility before integrity check
        //    (newer schema is unrecoverable — must not auto-delete)
        if !verifySchemaCompatibility(dbPath: dbPath) {
            var version = 0
            var compatDB: OpaquePointer?
            if sqlite3_open_v2(dbPath, &compatDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
               let compatDB {
                version = SchemaMigrator.readSchemaVersion(on: compatDB)
                sqlite3_close(compatDB)
            }
            throw IndexRecoveryError.schemaIncompatibility(
                current: version,
                required: SchemaMigrator.currentSchemaVersion
            )
        }

        // 4. Check database integrity
        if !verifyIntegrity(dbPath: dbPath) {
            logger.warning("Database integrity check failed — initiating auto-rebuild")
            try recover(dbPath: dbPath, dbDirectory: dbDirectory)
        }

        logger.info("Startup recovery sequence complete")
    }

    // MARK: - Private Helpers

    /// Attempt a WAL checkpoint (TRUNCATE mode) on the given database.
    ///
    /// Returns `true` on success, `false` on any failure. Failures are logged
    /// but not thrown — the caller falls back to deleting WAL files.
    ///
    /// - Parameter dbPath: Absolute path to the SQLite database file.
    /// - Returns: `true` if the checkpoint succeeded.
    private static func checkpointWAL(dbPath: String) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            logger.warning("Cannot open database for WAL checkpoint")
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        let checkpointRC = sqlite3_wal_checkpoint_v2(
            db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil
        )
        if checkpointRC != SQLITE_OK {
            logger.warning("WAL checkpoint failed: code \(checkpointRC)")
            return false
        }

        return true
    }
}
