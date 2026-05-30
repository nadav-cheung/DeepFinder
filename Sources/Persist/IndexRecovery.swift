import Foundation

// MARK: - Recovery Types

/// Action taken during recovery. Used by callers to decide next steps.
enum RecoveryAction: Sendable, Equatable {
    case none
    case rebuildFromDB
    case fullRescan
    case walCleanup
}

/// Result of a recovery operation, describing what was done and how many records were recovered.
struct RecoveryResult: Sendable, Equatable {
    let action: RecoveryAction
    let recordsRecovered: Int
    let message: String
}

// MARK: - IndexRecovery

/// Diagnoses and recovers from index corruption scenarios:
/// - WAL corruption (delete WAL+SHM, retry from main DB)
/// - Checkpoint failure (load from main DB only)
/// - Schema incompatibility (migration or full rebuild)
/// - Stale lock detection
actor IndexRecovery {

    private let persistence: IndexPersistence
    private let scanner: FileScanner
    private let index: InMemoryIndex

    /// Create a recovery manager with access to the persistence layer, scanner, and in-memory index.
    ///
    /// - Parameters:
    ///   - persistence: The SQLite persistence layer to diagnose and repair.
    ///   - scanner: Used for full filesystem rescans when the database cannot be recovered.
    ///   - index: The in-memory index to rebuild during full rescans.
    init(persistence: IndexPersistence, scanner: FileScanner, index: InMemoryIndex) {
        self.persistence = persistence
        self.scanner = scanner
        self.index = index
    }

    // MARK: - Diagnose

    /// Run a full diagnostic and attempt recovery if needed.
    ///
    /// Recovery strategy (in order):
    /// 1. Check database integrity via `PRAGMA integrity_check`.
    /// 2. If unhealthy, close the connection and delete WAL/SHM files.
    /// 3. Report that the database should be reopened and reloaded.
    ///
    /// - Important: After this method returns with any action other than `.none`,
    ///   the current ``IndexPersistence`` is closed and unusable. The caller must
    ///   create a new ``IndexPersistence`` instance and reload records.
    /// - Returns: A ``RecoveryResult`` describing what was done and the recommended next action.
    func diagnoseAndRecover() async throws -> RecoveryResult {
        // Step 1: Check integrity
        let isHealthy = try await persistence.verifyIntegrity()
        if isHealthy {
            return RecoveryResult(action: .none, recordsRecovered: 0, message: "Database is healthy")
        }

        // Step 2: Close the connection before deleting WAL files.
        // Deleting WAL/SHM under an active WAL-mode connection leaves it in undefined state.
        await persistence.close()

        // Step 3: Try WAL cleanup (safe now — connection is closed)
        _ = try recoverFromWALCorruption()

        // Step 4: Reopen the database and try loading from main DB after WAL cleanup.
        // If persistence.dbPath is nil (in-memory), there's nothing to recover.
        guard persistence.dbPath != nil else {
            return RecoveryResult(
                action: .fullRescan,
                recordsRecovered: 0,
                message: "In-memory database corrupted, full rescan required"
            )
        }

        // Reopen: the IndexPersistence init will create a fresh connection.
        // Note: this requires the caller to pass a new IndexPersistence after recovery.
        // For now, report that WAL cleanup was done and the DB should be reopened.
        return RecoveryResult(
            action: .rebuildFromDB,
            recordsRecovered: 0,
            message: "WAL files cleaned, database should be reopened and reloaded"
        )
    }

    // MARK: - WAL Corruption

    /// Delete WAL and SHM files, allowing SQLite to retry from the main DB file.
    func recoverFromWALCorruption() throws -> RecoveryResult {
        guard let dbPath = persistence.dbPath else {
            return RecoveryResult(action: .none, recordsRecovered: 0, message: "In-memory database, no WAL to clean")
        }

        let fm = FileManager.default
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"

        var cleaned = false

        if fm.fileExists(atPath: walPath) {
            try fm.removeItem(atPath: walPath)
            cleaned = true
        }
        if fm.fileExists(atPath: shmPath) {
            try fm.removeItem(atPath: shmPath)
            cleaned = true
        }

        if cleaned {
            return RecoveryResult(action: .walCleanup, recordsRecovered: 0, message: "Removed corrupted WAL and SHM files")
        }

        return RecoveryResult(action: .none, recordsRecovered: 0, message: "No WAL files found to clean")
    }

    // MARK: - Checkpoint Failure

    /// Recover by loading records from the main DB only (ignoring WAL).
    func recoverFromCheckpointFailure() throws -> RecoveryResult {
        guard let dbPath = persistence.dbPath else {
            return RecoveryResult(
                action: .none,
                recordsRecovered: 0,
                message: "In-memory database, checkpoint failure not applicable"
            )
        }

        // Verify the main DB file exists
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RecoveryResult(
                action: .fullRescan,
                recordsRecovered: 0,
                message: "Main database file missing, full rescan required"
            )
        }

        return RecoveryResult(
            action: .rebuildFromDB,
            recordsRecovered: 0,
            message: "Will rebuild from main database file, ignoring checkpoint"
        )
    }

    // MARK: - Schema Incompatibility

    /// Handle schema version mismatch between app and database.
    func recoverFromSchemaIncompatibility(appVersion: Int, dbVersion: Int) throws -> RecoveryResult {
        if appVersion <= dbVersion {
            return RecoveryResult(
                action: .none,
                recordsRecovered: 0,
                message: "Schema version compatible (app: \(appVersion), db: \(dbVersion))"
            )
        }

        // If the version gap is large (likely incompatible), do a full rebuild
        if appVersion - dbVersion > 1 {
            return RecoveryResult(
                action: .fullRescan,
                recordsRecovered: 0,
                message: "Schema incompatibility too large (app: \(appVersion), db: \(dbVersion)), full rescan required"
            )
        }

        // Minor version difference — attempt migration (rebuild from DB)
        return RecoveryResult(
            action: .rebuildFromDB,
            recordsRecovered: 0,
            message: "Schema migration needed (app: \(appVersion), db: \(dbVersion)), will rebuild from database"
        )
    }

    // MARK: - Full Rebuild

    /// Trigger a full filesystem rescan and reindex.
    func fullRebuild(rootPaths: [String]) async throws -> RecoveryResult {
        var totalRecords = 0
        var pendingRecords: [FileRecord] = []
        let batchSize = 100

        let config = ScanConfiguration()
        let eventStream = await scanner.scan(rootPaths: rootPaths, config: config)

        for await event in eventStream {
            switch event {
            case .fileFound(let record):
                await index.insert(record)
                pendingRecords.append(record)
                totalRecords += 1
                if pendingRecords.count >= batchSize {
                    await persistence.saveRecords(pendingRecords)
                    pendingRecords.removeAll(keepingCapacity: true)
                }
            case .directoryFound(let record):
                await index.insert(record)
                pendingRecords.append(record)
                totalRecords += 1
                if pendingRecords.count >= batchSize {
                    await persistence.saveRecords(pendingRecords)
                    pendingRecords.removeAll(keepingCapacity: true)
                }
            case .scanComplete, .progress, .scanError:
                break
            }
        }

        // Flush remaining records
        if !pendingRecords.isEmpty {
            await persistence.saveRecords(pendingRecords)
        }

        return RecoveryResult(
            action: .fullRescan,
            recordsRecovered: totalRecords,
            message: "Full rescan completed, indexed \(totalRecords) items"
        )
    }

    // MARK: - Stale Lock Detection

    /// Check for a stale file lock on the database.
    /// Returns `true` if a lock has been held longer than `timeout` seconds.
    ///
    /// Current implementation: checks if the DB file exists and is accessible.
    /// A full implementation would also check PID file liveness (dead daemon process).
    func detectStaleLock(timeout: TimeInterval = 5) throws -> Bool {
        guard let dbPath = persistence.dbPath else {
            // In-memory DB — no file lock possible
            return false
        }

        let fm = FileManager.default

        // Check if the DB file exists
        guard fm.fileExists(atPath: dbPath) else {
            return false
        }

        // Read modification time to verify file accessibility.
        // If another process holds an active flock, this may fail or return stale data.
        let attrs = try fm.attributesOfItem(atPath: dbPath)
        guard let modDate = attrs[.modificationDate] as? Date else {
            return false
        }

        // A full stale-lock check would verify:
        // 1. PID file exists with a PID
        // 2. That PID is not running (kill(pid, 0) fails with ESRCH)
        // 3. File mod time is older than `timeout`
        // For now, since we can access the file from this actor, return false.
        _ = modDate
        return false
    }
}
