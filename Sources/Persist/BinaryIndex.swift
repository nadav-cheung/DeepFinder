// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// # BinaryIndex
///
/// Standalone binary persistence engine for `[FileRecord]`. Replaces the SQLite
/// layer used by ``IndexPersistence`` (P3). Stateless between calls: each
/// ``save(_:)`` is an atomic full-snapshot rewrite of `index.bin`. The FSEvents
/// cursor lives in a separate sidecar `index.cursor` so it can be updated
/// independently without rewriting the (potentially large) index.
///
/// ## File format (version 1, little-endian)
///
/// `index.bin`:
/// ```
/// Header (16 bytes):
///   magic       [0x44,0x46,0x49,0x58]  "DFIX"         4
///   version     UInt16 LE  (=1)                       2
///   flags       UInt8      bit0 = path_encrypted      1
///   reserved    UInt8      0                          1
///   num_records UInt32 LE                             4
///   reserved2   UInt32 LE   0                         4
/// Records (num_records entries):
///   rec_len     UInt32 LE   (payload byte length — forward-compat skip)
///   id          UInt32 LE
///   name_len    UInt16 LE; name bytes (UTF-8, NFC)
///   orig_len    UInt16 LE; originalName bytes
///   path_len    UInt16 LE; path bytes (ciphertext if flags.bit0)
///   parent_len  UInt16 LE; parent bytes (same)
///   ext_len     UInt16 LE; ext bytes (0xFFFF = nil extension)
///   is_dir      UInt8
///   size        Int64 LE
///   created     Float64 LE (timeIntervalSince1970)
///   modified    Float64 LE
///   meta_len    UInt32 LE; metadata JSON bytes (0 = nil metadata)
/// ```
///
/// `index.cursor` (8 bytes): magic "DFCR" [4] + UInt64 LE cursor [4].
///
/// ## Atomic writes
///
/// For both files: serialize → write `<path>.tmp` → chmod 600 → `fsync` →
/// `rename` over the target. A crash leaves either the complete old file or the
/// complete new file, never a half-written one.
///
/// ## Encryption
///
/// Only `path` and `parentPath` are encrypted (AES-256-GCM via ``PathEncryption``),
/// matching the SQLite layer's fail-closed behavior. On save, if encryption throws
/// for a record, that record is skipped (plaintext is never persisted). On load,
/// records that fail decryption are skipped and logged. `nil` pathEncryption =
/// plaintext mode (tests / in-memory).
import Foundation
import OSLog
import DeepFinderIndex

// MARK: - BinaryIndexError

/// Errors thrown by ``BinaryIndex`` during I/O or parsing.
public enum BinaryIndexError: Error, CustomStringConvertible {
    /// File exists but is structurally invalid (bad magic, truncated, short read).
    case corrupt(String)
    /// File version is newer than this build can read.
    case unsupportedVersion(found: UInt16, supported: UInt16)
    /// A filesystem operation (open/write/sync/rename) failed.
    case ioFailed(String)

    public var description: String {
        switch self {
        case .corrupt(let msg):
            return "BinaryIndex corrupt: \(msg)"
        case .unsupportedVersion(let found, let supported):
            return "BinaryIndex unsupported version: found \(found), supported \(supported)"
        case .ioFailed(let msg):
            return "BinaryIndex I/O failed: \(msg)"
        }
    }
}

// MARK: - BinaryIndex

/// Standalone binary persistence engine for `[FileRecord]`.
///
/// See the file-level doc for the on-disk format and atomicity guarantees.
public final class BinaryIndex {

    // MARK: - Constants

    /// Magic bytes "DFIX" identifying an index.bin file.
    private static let indexMagic: [UInt8] = [0x44, 0x46, 0x49, 0x58]
    /// Magic bytes "DFCR" identifying an index.cursor sidecar.
    private static let cursorMagic: [UInt8] = [0x44, 0x46, 0x43, 0x52]
    /// Header byte length of index.bin.
    private static let headerLength = 16
    /// Byte length of index.cursor (magic + UInt64).
    private static let cursorLength = 12
    /// Format version written and read by this build.
    private static let supportedVersion: UInt16 = 1
    /// Sentinel for `extension == nil` in the ext_len field.
    private static let nilExtSentinel: UInt16 = 0xFFFF
    /// flags bit0: path/parent fields are AES-256-GCM ciphertext.
    private static let flagPathEncrypted: UInt8 = 0b0000_0001

    // MARK: - State

    private let logger = Logger(subsystem: Product.daemonSubsystem, category: "persist")
    private let binPath: String
    private let cursorPath: String
    private let pathEncryption: PathEncryption?

    // MARK: - Init

    /// - Parameters:
    ///   - path: Full path to `index.bin`. The cursor sidecar is derived as the
    ///     same file name with the `.cursor` extension in the same directory.
    ///   - pathEncryption: Optional AES-256-GCM encryption for path/parentPath.
    ///     `nil` stores plaintext (tests / in-memory).
    public init(path: String, pathEncryption: PathEncryption?) throws {
        self.binPath = path
        self.cursorPath = BinaryIndex.cursorPath(for: path)
        self.pathEncryption = pathEncryption

        // Ensure parent dir exists with 700 perms for the index directory.
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Public API

    /// Atomic full-snapshot write of `records`. Optionally also writes the cursor.
    public func save(_ records: [FileRecord], cursor: UInt64? = nil) throws {
        let useEncryption = pathEncryption != nil
        let data = serialize(records: records, encrypt: useEncryption)
        try atomicWrite(data: data, to: binPath)
        if let cursor {
            try saveCursor(cursor)
        }
    }

    /// Parse index.bin. Throws on a bad/truncated file; returns `[]` if the file
    /// is simply absent. Decrypts path/parentPath when encryption is on; skips
    /// records that fail decryption (logged).
    public func load() throws -> [FileRecord] {
        guard FileManager.default.fileExists(atPath: binPath) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: binPath))
        } catch {
            throw BinaryIndexError.ioFailed("read \(binPath): \(error.localizedDescription)")
        }
        return try parse(data: data)
    }

    /// Load, drop records whose id is in `ids`, atomic re-save. Returns count removed.
    @discardableResult
    public func deleteRecords(_ ids: Set<UInt32>) throws -> Int {
        let loaded = try load()
        var removed = 0
        var kept: [FileRecord] = []
        kept.reserveCapacity(loaded.count)
        for record in loaded {
            if ids.contains(record.id) {
                removed += 1
            } else {
                kept.append(record)
            }
        }
        // Preserve any existing cursor across the re-save.
        let cursor = try loadCursor()
        try save(kept, cursor: cursor)
        return removed
    }

    /// Load, decrypt-filter by path prefix, atomic re-save. Returns count removed.
    /// When encryption is on, this is the load-all/decrypt/filter path the SQLite
    /// layer used.
    @discardableResult
    public func deleteByPathPrefix(_ prefix: String) throws -> Int {
        let loaded = try load()
        let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        var removed = 0
        var kept: [FileRecord] = []
        kept.reserveCapacity(loaded.count)
        for record in loaded {
            if record.path == prefix || record.path.hasPrefix(normalizedPrefix) {
                removed += 1
            } else {
                kept.append(record)
            }
        }
        let cursor = try loadCursor()
        try save(kept, cursor: cursor)
        return removed
    }

    /// Atomically write the cursor sidecar (does NOT touch index.bin).
    public func saveCursor(_ cursor: UInt64) throws {
        var data = Data(capacity: Self.cursorLength)
        data.append(contentsOf: Self.cursorMagic)
        // UInt64 LE.
        var le = cursor.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        try atomicWrite(data: data, to: cursorPath)
    }

    /// Load the cursor sidecar. Returns `nil` if absent or corrupt.
    public func loadCursor() throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: cursorPath) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: cursorPath))
        } catch {
            throw BinaryIndexError.ioFailed("read \(cursorPath): \(error.localizedDescription)")
        }
        guard data.count >= Self.cursorLength else { return nil }
        // Verify magic.
        let magic = Array(data.prefix(4))
        guard magic == Self.cursorMagic else { return nil }
        let value = data.subdata(in: 4..<12).withUnsafeBytes { rawBuffer -> UInt64 in
            rawBuffer.load(as: UInt64.self).littleEndian
        }
        return value
    }

    /// Quick header check for the recovery path: true if file is absent OR has a
    /// valid DFIX magic + supported version. False on corruption / unsupported version.
    public static func validateHeader(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= headerLength else { return false }
        if Array(data.prefix(4)) != indexMagic { return false }
        let version = UInt16(data[4]) | (UInt16(data[5]) << 8)
        return version == supportedVersion
    }

    /// Returns true if a (header-valid) index.bin exists at `path`.
    public static func exists(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count >= headerLength else { return false }
        return Array(data.prefix(4)) == indexMagic
    }

    // MARK: - Serialization

    /// Build the full index.bin `Data` (header + records) for the given records.
    private func serialize(records: [FileRecord], encrypt: Bool) -> Data {
        // First pass: produce each record's payload so we can prefix rec_len.
        var payloads: [Data] = []
        payloads.reserveCapacity(records.count)

        for record in records {
            // Fail-closed encryption: if encryption is on and fails for any
            // record, skip it entirely rather than persist plaintext.
            let pathValue: String
            let parentValue: String
            if encrypt, let encryption = pathEncryption {
                guard let encPath = try? encryption.encrypt(record.path),
                      let encParent = try? encryption.encrypt(record.parentPath) else {
                    logger.error("Path encryption failed for record \(record.id); skipping persist to avoid plaintext on disk")
                    continue
                }
                pathValue = encPath
                parentValue = encParent
            } else {
                pathValue = record.path
                parentValue = record.parentPath
            }

            // NFC-normalize name and originalName on write (matches ingestion).
            let nameStr = record.name.precomposedStringWithCanonicalMapping
            let origStr = record.originalName.precomposedStringWithCanonicalMapping

            guard let nameData = nameStr.data(using: .utf8),
                  let origData = origStr.data(using: .utf8),
                  let pathData = pathValue.data(using: .utf8),
                  let parentData = parentValue.data(using: .utf8) else {
                logger.error("UTF-8 encoding failed for record \(record.id); skipping")
                continue
            }

            // ext: nil → 0xFFFF sentinel, else bytes.
            let extNil = record.extension == nil
            let extBytes: Data
            if let ext = record.extension, let d = ext.data(using: .utf8) {
                extBytes = d
            } else if !extNil, let d = "".data(using: .utf8) {
                extBytes = d
            } else {
                extBytes = Data()
            }

            // metadata JSON (nil → 0 bytes).
            var metaBytes = Data()
            if let metadata = record.metadata {
                if let encoded = try? JSONEncoder().encode(metadata) {
                    metaBytes = encoded
                } else {
                    logger.warning("Failed to encode metadata for record \(record.id); storing nil")
                    metaBytes = Data()
                }
            }

            // Length bounds: UTF-8 byte lengths fit UInt16 (max 65535) for name/
            // orig/path/parent/ext. Real filesystem paths can exceed this on some
            // systems, in which case we skip the record defensively. SQLite had no
            // such bound; this is a small format trade-off for compactness.
            guard nameData.count <= UInt16.max,
                  origData.count <= UInt16.max,
                  pathData.count <= UInt16.max,
                  parentData.count <= UInt16.max,
                  extBytes.count < UInt16.max,  // 0xFFFF reserved for nil
                  metaBytes.count <= UInt32.max else {
                logger.error("Field length exceeds format bound for record \(record.id); skipping")
                continue
            }

            var payload = Data()
            // id
            payload.append(uint32LE: record.id)
            // name
            payload.append(uint16LE: UInt16(nameData.count))
            payload.append(nameData)
            // originalName
            payload.append(uint16LE: UInt16(origData.count))
            payload.append(origData)
            // path
            payload.append(uint16LE: UInt16(pathData.count))
            payload.append(pathData)
            // parent
            payload.append(uint16LE: UInt16(parentData.count))
            payload.append(parentData)
            // ext
            if extNil {
                payload.append(uint16LE: Self.nilExtSentinel)
            } else {
                payload.append(uint16LE: UInt16(extBytes.count))
                payload.append(extBytes)
            }
            // is_dir
            payload.append(record.isDirectory ? UInt8(1) : UInt8(0))
            // size
            payload.append(int64LE: record.size)
            // created / modified
            payload.append(doubleLE: record.createdAt.timeIntervalSince1970)
            payload.append(doubleLE: record.modifiedAt.timeIntervalSince1970)
            // metadata
            payload.append(uint32LE: UInt32(metaBytes.count))
            payload.append(metaBytes)

            payloads.append(payload)
        }

        // Assemble header + records.
        var out = Data()
        out.append(contentsOf: Self.indexMagic)
        out.append(uint16LE: Self.supportedVersion)
        let flags: UInt8 = encrypt ? Self.flagPathEncrypted : 0
        out.append(flags)
        out.append(UInt8(0))  // reserved
        out.append(uint32LE: UInt32(payloads.count))
        out.append(uint32LE: 0)  // reserved2

        for payload in payloads {
            out.append(uint32LE: UInt32(payload.count))
            out.append(payload)
        }
        return out
    }

    /// Parse index.bin bytes into `[FileRecord]`.
    private func parse(data: Data) throws -> [FileRecord] {
        guard data.count >= Self.headerLength else {
            throw BinaryIndexError.corrupt("file shorter than header (\(data.count) bytes)")
        }
        // Magic.
        let magic = Array(data.prefix(4))
        guard magic == Self.indexMagic else {
            throw BinaryIndexError.corrupt("bad magic \(magic)")
        }
        // Version.
        let version = UInt16(data[4]) | (UInt16(data[5]) << 8)
        guard version == Self.supportedVersion else {
            throw BinaryIndexError.unsupportedVersion(
                found: version, supported: Self.supportedVersion
            )
        }
        let flags = data[6]
        let encrypted = (flags & Self.flagPathEncrypted) != 0
        let numRecords = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

        var cursor = Self.headerLength
        var records: [FileRecord] = []
        records.reserveCapacity(Int(numRecords))

        for i in 0..<UInt32(numRecords) {
            // rec_len prefix.
            guard cursor + 4 <= data.count else {
                throw BinaryIndexError.corrupt("truncated rec_len at record \(i)")
            }
            let recLen = data.subdata(in: cursor..<(cursor + 4))
                .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            cursor += 4
            guard cursor + Int(recLen) <= data.count else {
                throw BinaryIndexError.corrupt("truncated record \(i) payload (recLen=\(recLen))")
            }
            let payload = data.subdata(in: cursor..<(cursor + Int(recLen)))
            cursor += Int(recLen)

            if let record = parseRecord(payload: payload, encrypted: encrypted) {
                records.append(record)
            }
        }
        return records
    }

    /// Parse a single record payload. Returns nil if decryption fails (logged).
    private func parseRecord(payload: Data, encrypted: Bool) -> FileRecord? {
        var pos = 0
        func readUInt32() throws -> UInt32 {
            guard pos + 4 <= payload.count else { throw ParseError.short }
            let v = payload.subdata(in: pos..<(pos + 4))
                .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            pos += 4
            return v
        }
        func readUInt16() throws -> UInt16 {
            guard pos + 2 <= payload.count else { throw ParseError.short }
            let v = UInt16(payload[pos]) | (UInt16(payload[pos + 1]) << 8)
            pos += 2
            return v
        }
        func readBytes(_ n: Int) throws -> Data {
            guard pos + n <= payload.count else { throw ParseError.short }
            let d = payload.subdata(in: pos..<(pos + n))
            pos += n
            return d
        }

        let id: UInt32
        let nameLen: UInt16
        let origLen: UInt16
        let pathLen: UInt16
        let parentLen: UInt16
        let extLen: UInt16
        do {
            id = try readUInt32()
            nameLen = try readUInt16()
            let nameData = try readBytes(Int(nameLen))
            origLen = try readUInt16()
            let origData = try readBytes(Int(origLen))
            pathLen = try readUInt16()
            let pathData = try readBytes(Int(pathLen))
            parentLen = try readUInt16()
            let parentData = try readBytes(Int(parentLen))
            extLen = try readUInt16()
            let extData: Data?
            if extLen == Self.nilExtSentinel {
                extData = nil
            } else {
                extData = try readBytes(Int(extLen))
            }
            // is_dir, size, created, modified.
            guard pos + 1 + 8 + 8 + 8 <= payload.count else { return nil }
            let isDir = payload[pos] != 0
            pos += 1
            let size = payload.subdata(in: pos..<(pos + 8))
                .withUnsafeBytes { Int64(bitPattern: $0.load(as: UInt64.self).littleEndian) }
            pos += 8
            let created = payload.subdata(in: pos..<(pos + 8))
                .withUnsafeBytes { Double(bitPattern: $0.load(as: UInt64.self).littleEndian) }
            pos += 8
            let modified = payload.subdata(in: pos..<(pos + 8))
                .withUnsafeBytes { Double(bitPattern: $0.load(as: UInt64.self).littleEndian) }
            pos += 8
            // metadata
            guard pos + 4 <= payload.count else { return nil }
            let metaLen = payload.subdata(in: pos..<(pos + 4))
                .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            pos += 4
            guard pos + Int(metaLen) <= payload.count else { return nil }
            let metaData = try? readBytes(Int(metaLen))

            guard let name = String(data: nameData, encoding: .utf8),
                  let origName = String(data: origData, encoding: .utf8) else {
                logger.warning("UTF-8 decode failed for record \(id); skipping")
                return nil
            }

            let rawPath = String(data: pathData, encoding: .utf8) ?? ""
            let rawParent = String(data: parentData, encoding: .utf8) ?? ""

            // Decrypt if the file was written encrypted.
            let path: String
            let parentPath: String
            if encrypted, let encryption = pathEncryption {
                guard let decPath = try? encryption.decrypt(rawPath) else {
                    logger.warning("Failed to decrypt path, skipping record \(id)")
                    return nil
                }
                guard let decParent = try? encryption.decrypt(rawParent) else {
                    logger.warning("Failed to decrypt parent path, skipping record \(id)")
                    return nil
                }
                path = decPath
                parentPath = decParent
            } else {
                path = rawPath
                parentPath = rawParent
            }

            let ext: String?
            if let extData {
                ext = String(data: extData, encoding: .utf8)
            } else {
                ext = nil
            }

            var metadata: ExtractedMetadata?
            if let metaData, !metaData.isEmpty {
                metadata = try? JSONDecoder().decode(ExtractedMetadata.self, from: metaData)
            }

            return FileRecord(
                id: id,
                name: name,
                originalName: origName,
                path: path,
                parentPath: parentPath,
                isDirectory: isDir,
                size: size,
                createdAt: Date(timeIntervalSince1970: created),
                modifiedAt: Date(timeIntervalSince1970: modified),
                extension: ext,
                metadata: metadata
            )
        } catch {
            logger.warning("Truncated payload for record; skipping")
            return nil
        }
    }

    // MARK: - Atomic write

    /// Write `data` to `path` atomically: tmp file → chmod 600 → fsync → rename.
    private func atomicWrite(data: Data, to path: String) throws {
        let tmpPath = path + ".tmp"

        // Remove any stale tmp from a previous crashed attempt.
        if FileManager.default.fileExists(atPath: tmpPath) {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }

        do {
            FileManager.default.createFile(atPath: tmpPath, contents: data, attributes: nil)
            // chmod 600.
            try FileManager.default.setAttributes(
                [.posixPermissions: Product.privateFilePermissions],
                ofItemAtPath: tmpPath
            )
            // fsync the tmp file to durable storage.
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath)) {
                try? handle.synchronize()
                try? handle.close()
            }
            // Atomic rename over the target.
            if FileManager.default.fileExists(atPath: path) {
                // Replace in-place to keep the atomicity guarantee on the same FS.
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path),
                    withItemAt: URL(fileURLWithPath: tmpPath),
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
            }
        } catch {
            throw BinaryIndexError.ioFailed("atomic write to \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Path helpers

    private static func cursorPath(for indexPath: String) -> String {
        let url = URL(fileURLWithPath: indexPath)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base).cursor").path
    }
}

// MARK: - ParseError (internal)

private enum ParseError: Error {
    case short
}

// MARK: - Data LE helpers

private extension Data {
    mutating func append(uint32LE v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func append(uint16LE v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func append(int64LE v: Int64) {
        let u = UInt64(bitPattern: v).littleEndian
        var le = u
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func append(doubleLE v: Double) {
        let u = v.bitPattern.littleEndian
        var le = u
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
