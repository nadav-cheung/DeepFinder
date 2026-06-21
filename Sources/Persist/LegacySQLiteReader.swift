// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Foundation
import OSLog
import SQLite3
import DeepFinderIndex

/// Read-only SQLite→`[FileRecord]` reader used by the one-time P4 migration.
///
/// Before the P3 refactor, ``IndexPersistence`` stored FileRecords in a SQLite
/// `file_records` table (`index.db`), with `path` and `parent_path` holding
/// AES-256-GCM ciphertext. P3 replaced that backend with the binary `index.bin`
/// snapshot (``BinaryIndex``). So existing users do not lose their index on
/// upgrade, ``IndexPersistence/init(dbPath:)`` calls
/// ``LegacySQLiteReader/readRecords(at:pathEncryption:)`` exactly once — when
/// `index.bin` is absent but a legacy `index.db` is present — and seeds
/// `index.bin` from the legacy rows.
///
/// This reader reproduces the pre-P3 read path verbatim:
/// 1. `sqlite3_open_v2` the legacy db (read-write, in case a v1/v2 db needs
///    `ALTER TABLE` to reach v3 — same as the old init).
/// 2. Run ``SchemaMigrator/migrateSchema(on:)`` + create the `file_records` and
///    `metadata` tables (idempotent via `CREATE TABLE IF NOT EXISTS`) so an old
///    db is brought to the readable shape the SELECT below expects.
/// 3. `SELECT id, name, original_name, path, parent_path, is_directory, size,
///    created_at, modified_at, ext, metadata_json FROM file_records`.
/// 4. Parse each row via ``SchemaMigrator/parseColumns(from:)`` and decrypt
///    `path`/`parent_path` with the supplied ``PathEncryption``. `nil`
///    `pathEncryption` means plaintext (the in-memory-style case). Rows whose
///    ciphertext fails to decrypt are skipped — the same fail-closed policy the
///    old layer used (`recordFromStatement` returned `nil`).
///
/// The connection is closed before return on every path. Any open / step /
/// migration error is thrown so the caller can fall back to a full rescan;
/// a structurally valid but empty `file_records` table returns `[]`.
public enum LegacySQLiteReader {

    // MARK: - Logging

    private static let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")

    // MARK: - Public API

    /// Read all FileRecords from a legacy `index.db`.
    ///
    /// - Parameters:
    ///   - dbPath: Filesystem path to the legacy SQLite database.
    ///   - pathEncryption: AES-256-GCM encryption used to decrypt `path` and
    ///     `parent_path`. Pass `nil` for a plaintext (e.g. legacy in-memory-style)
    ///     database.
    /// - Returns: All readable rows as FileRecords. Rows that fail to decrypt
    ///   are skipped (logged). Returns `[]` if the `file_records` table is empty.
    /// - Throws: ``PersistenceError`` on open, migration, prepare, or step
    ///   failure. The caller treats any throw as "migration failed → rescan".
    public static func readRecords(
        at dbPath: String,
        pathEncryption: PathEncryption?
    ) throws -> [FileRecord] {
        logger.info("Reading legacy SQLite index: \(dbPath, privacy: .public)")

        // Open the legacy db read-write so a v1/v2 schema can be ALTERed up to
        // v3 by migrateSchema (matches the old IndexPersistence.init behavior).
        var dbPtr: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let openRC = sqlite3_open_v2(dbPath, &dbPtr, flags, nil)
        guard openRC == SQLITE_OK, let db = dbPtr else {
            let msg = dbPtr.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(openRC)"
            sqlite3_close(dbPtr)
            logger.error("Legacy db open failed: \(msg, privacy: .public)")
            throw PersistenceError.openFailed(msg)
        }

        // Ensure the connection is closed on every exit path.
        defer { sqlite3_close(db) }

        // Same PRAGMAs the old init applied; harmless on an already-configured db.
        try SchemaMigrator.execSQL(db, "PRAGMA journal_mode=WAL")
        try SchemaMigrator.execSQL(db, "PRAGMA synchronous=NORMAL")

        // Create tables idempotently, then run any pending migration so the
        // SELECT below sees the v3 column set (incl. metadata_json from v2).
        try SchemaMigrator.execSQL(db, SchemaMigrator.createFileRecordsSQL)
        try SchemaMigrator.execSQL(db, SchemaMigrator.createMetadataSQL)
        try SchemaMigrator.migrateSchema(on: db)

        // SELECT the same column set, in the same order, as the old layer.
        let sql = """
            SELECT id, name, original_name, path, parent_path, is_directory,
                   size, created_at, modified_at, ext, metadata_json
            FROM file_records
            """
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v3(db, sql, -1, 0, &stmt, nil)
        guard prepRC == SQLITE_OK, let stmt else {
            logger.error("Legacy db prepare failed: code \(prepRC)")
            throw PersistenceError.prepareFailed(sql, prepRC)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [FileRecord] = []
        var skipped = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if let record = recordFromStatement(stmt, pathEncryption: pathEncryption) {
                    records.append(record)
                } else {
                    skipped += 1
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                logger.error("Legacy db step failed: code \(rc)")
                throw PersistenceError.stepFailed(rc)
            }
        }

        logger.info("Legacy read complete: \(records.count) records, \(skipped) skipped")
        return records
    }

    // MARK: - Row Parsing

    /// Parse one row into a FileRecord, decrypting path/parentPath when
    /// `pathEncryption` is non-nil. Returns `nil` (fail-closed) if a ciphertext
    /// fails to decrypt — mirrors the old `IndexPersistence.recordFromStatement`.
    private static func recordFromStatement(
        _ stmt: OpaquePointer,
        pathEncryption: PathEncryption?
    ) -> FileRecord? {
        let columns = SchemaMigrator.parseColumns(from: stmt)

        // Columns 3 and 4 hold (possibly encrypted) path / parent_path.
        let rawPath = String(cString: sqlite3_column_text(stmt, 3))
        let rawParentPath = String(cString: sqlite3_column_text(stmt, 4))

        let path: String
        let parentPath: String
        if let encryption = pathEncryption {
            guard let decPath = try? encryption.decrypt(rawPath) else {
                logger.warning("Legacy row \(columns.id): path decrypt failed; skipping")
                return nil
            }
            guard let decParent = try? encryption.decrypt(rawParentPath) else {
                logger.warning("Legacy row \(columns.id): parent path decrypt failed; skipping")
                return nil
            }
            path = decPath
            parentPath = decParent
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
}
