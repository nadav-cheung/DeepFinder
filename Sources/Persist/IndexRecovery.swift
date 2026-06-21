// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # IndexRecovery
///
/// Startup recovery logic for the binary `index.bin` snapshot (P3 refactor —
/// replaces the previous SQLite WAL recovery).
///
/// Runs before ``IndexPersistence`` is opened to detect and repair problems:
/// - Stale lock file detection (crashed daemon PID file) — FS-level, unchanged
/// - Binary header validation (DFIX magic + supported version)
/// - Auto-rebuild from scratch when `index.bin` exists but is corrupt or an
///   unsupported version (delete `index.bin` + `index.cursor`, let the daemon
///   rescan)
///
/// Corruption = a bad DFIX magic header, a truncated file, or a version newer
/// than this build can read. Recovery deletes the snapshot + cursor sidecar;
/// the daemon performs a full rescan to repopulate. (Legacy `.db` / `.db-wal`
/// / `.db-shm` files from a pre-migration install are ignored here — P4 /
/// migration handles them.)
///
/// All recovery actions are logged via OSLog for debugging.
import Foundation
import OSLog
import DeepFinderIndex

// MARK: - IndexRecoveryError

/// Failure modes detected or thrown during index recovery.
public enum IndexRecoveryError: Error, CustomStringConvertible {
    /// The index file is corrupted and cannot be repaired.
    case corruptionDetected(String)
    /// Recovery completed by deleting the snapshot and cursor sidecar.
    case rebuiltFromScratch(String)

    public var description: String {
        switch self {
        case .corruptionDetected(let detail):
            return "Index corruption detected: \(detail)"
        case .rebuiltFromScratch(let path):
            return "Index rebuilt from scratch: \(path)"
        }
    }
}

// MARK: - IndexRecovery

/// Static utility for detecting and recovering from binary index problems.
///
/// Called during daemon startup, before ``IndexPersistence`` is opened.
/// All methods are static — no instance state needed.
///
/// ## Usage in DaemonMain
/// ```swift
/// // Before opening IndexPersistence:
/// try IndexRecovery.runStartupRecovery(dbPath: dbPath, dbDirectory: dbDir, pidPath: pidPath)
/// ```
public enum IndexRecovery {

    // MARK: - Logging

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "recovery")

    // MARK: - Path Helpers

    /// Derive the `index.bin` path from a logical `.db` path. Mirrors
    /// ``IndexPersistence.binPath(for:)`` exactly so both layers agree.
    static func binPath(for dbPath: String) -> String {
        IndexPersistence.binPath(for: dbPath)
    }

    /// Derive the cursor sidecar path from the bin path, matching
    /// ``BinaryIndex``'s naming: strip the path extension and append `.cursor`.
    private static func cursorPath(for binPath: String) -> String {
        let url = URL(fileURLWithPath: binPath)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base).cursor").path
    }

    // MARK: - Integrity Check

    /// Verify the binary index at the given logical `.db` path is healthy.
    ///
    /// Returns `true` if `index.bin` is absent (first run or clean state) OR
    /// has a valid DFIX header + supported version. Returns `false` if the file
    /// exists but is truncated, has a bad magic, or is an unsupported version.
    ///
    /// - Parameter dbPath: Absolute logical database path (the `.db` path; the
    ///   `.bin` path is derived from it).
    /// - Returns: `true` if the index is usable (or absent), `false` if corrupt.
    public static func verifyIntegrity(dbPath: String) -> Bool {
        let bin = binPath(for: dbPath)
        if !FileManager.default.fileExists(atPath: bin) {
            logger.info("No index.bin at \(bin, privacy: .public) — first run or clean state")
            return true
        }
        logger.debug("Verifying binary header: \(bin, privacy: .public)")
        let ok = BinaryIndex.validateHeader(at: bin)
        if ok {
            logger.debug("Binary header valid")
        } else {
            logger.error("Binary header invalid / unsupported version: \(bin, privacy: .public)")
        }
        return ok
    }

    // MARK: - Recovery

    /// Recover from index corruption by deleting `index.bin` and the
    /// `index.cursor` sidecar, letting ``IndexPersistence`` create a fresh
    /// snapshot on the next save (the daemon then rescans).
    ///
    /// - Parameters:
    ///   - dbPath: Absolute logical database path (the `.db` path).
    ///   - dbDirectory: Directory containing the index (accepted for signature
    ///     compatibility; the sidecar paths are derived from `dbPath`).
    /// - Throws: ``IndexRecoveryError`` if the corrupt file cannot be removed.
    public static func recover(dbPath: String, dbDirectory: String) throws {
        let bin = binPath(for: dbPath)
        let cursor = cursorPath(for: bin)
        logger.warning("Starting binary index recovery for \(bin, privacy: .public)")

        let fm = FileManager.default

        if fm.fileExists(atPath: bin) {
            do {
                try fm.removeItem(atPath: bin)
                logger.info("Removed corrupt index.bin: \(bin, privacy: .public)")
            } catch {
                logger.error("Failed to remove corrupt index.bin: \(error.localizedDescription, privacy: .public)")
                throw IndexRecoveryError.corruptionDetected(
                    "Cannot remove index.bin: \(error.localizedDescription)"
                )
            }
        }

        if fm.fileExists(atPath: cursor) {
            do {
                try fm.removeItem(atPath: cursor)
                logger.info("Removed index.cursor sidecar: \(cursor, privacy: .public)")
            } catch {
                // Non-critical: a stale cursor just means we may rescan more
                // aggressively on the next start. Log and continue.
                logger.warning("Failed to remove index.cursor: \(error.localizedDescription, privacy: .public)")
            }
        }

        if fm.fileExists(atPath: bin) {
            throw IndexRecoveryError.corruptionDetected("index.bin still exists after deletion")
        }

        logger.info("Binary index recovery complete — index will rebuild from scratch")
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

    /// Run the full recovery sequence on the index directory.
    ///
    /// This is the main entry point for daemon startup. It:
    /// 1. Detects and cleans stale lock files.
    /// 2. Validates the binary index header (first run → absent → healthy).
    /// 3. Auto-recovers from corruption if the header is invalid AND a bin
    ///    file exists (corruption, not first run).
    ///
    /// - Parameters:
    ///   - dbPath: Absolute logical database path (the `.db` path).
    ///   - dbDirectory: Directory containing the index file.
    ///   - pidPath: Absolute path to the PID file.
    /// - Throws: ``IndexRecoveryError`` if recovery fails.
    public static func runStartupRecovery(dbPath: String, dbDirectory: String, pidPath: String) throws {
        logger.info("Running startup recovery sequence")

        // 1. Detect and clean stale lock files
        let staleLock = detectStaleLock(pidPath: pidPath)
        if staleLock {
            logger.info("Cleaned up stale daemon lock file")
        }

        // 2. Validate binary header. Absent file = first run (healthy).
        let bin = binPath(for: dbPath)
        let binExists = FileManager.default.fileExists(atPath: bin)
        if binExists && !verifyIntegrity(dbPath: dbPath) {
            // Header is invalid AND a file exists → corruption. Auto-rebuild.
            logger.warning("Binary index corrupt — initiating auto-rebuild")
            try recover(dbPath: dbPath, dbDirectory: dbDirectory)
        }

        logger.info("Startup recovery sequence complete")
    }
}
