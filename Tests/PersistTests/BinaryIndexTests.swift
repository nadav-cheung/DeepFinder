// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import Testing
import Foundation
@testable import DeepFinderPersist
import DeepFinderIndex

@Suite("BinaryIndex", .serialized)
struct BinaryIndexTests {

    // MARK: - Helpers

    /// Create a fresh temp dir + BinaryIndex (plaintext mode).
    private func makePlain() throws -> (BinaryIndex, URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("index.bin").path
        let idx = try BinaryIndex(path: path, pathEncryption: nil)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: dir) }
        return (idx, dir, cleanup)
    }

    /// Create a PathEncryption backed by a temp-dir SecretsStore.
    private func makeEncryption() throws -> (PathEncryption, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-binenc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let secretsPath = dir.appendingPathComponent("secrets.json").path
        let store = SecretsStore(filePath: secretsPath)
        let enc = try PathEncryption(secretsStore: store)
        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: dir) }
        return (enc, cleanup)
    }

    private func makeRecord(
        id: UInt32, name: String = "test.txt", path: String? = nil,
        parent: String? = nil, isDir: Bool = false, ext: String? = "txt",
        metadata: ExtractedMetadata? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path ?? "/Users/test/\(name)",
            parentPath: parent ?? "/Users/test",
            isDirectory: isDir,
            size: Int64(id) * 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100 + Double(id)),
            extension: ext,
            metadata: metadata
        )
    }

    // MARK: - 1. Round-trip

    @Test("Round-trip preserves every field incl Unicode/CJK/emoji/nil ext/metadata")
    func roundTrip() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let path = dir.appendingPathComponent("index.bin").path

        var meta = ExtractedMetadata(fileExtension: "jpg")
        meta.fields["width"] = .integer(1920)
        meta.fields["artist"] = .string("宇多田ヒカル")

        let records: [FileRecord] = [
            makeRecord(id: 1, name: "hello.txt", path: "/Users/a/hello.txt", parent: "/Users/a"),
            makeRecord(id: 2, name: "文档.pdf", path: "/Users/文档/项目报告.pdf", parent: "/Users/文档"),
            makeRecord(id: 3, name: "🎉 party 🎊", path: "/Users/🎉/fun.txt", parent: "/Users/🎉"),
            makeRecord(id: 4, name: "Documents", path: "/Users/a/Documents", parent: "/Users/a", isDir: true, ext: nil),
            makeRecord(id: 5, name: "photo.jpg", path: "/Users/a/photo.jpg", parent: "/Users/a", ext: "jpg", metadata: meta),
            makeRecord(id: 6, name: "noext", path: "/Users/a/noext", parent: "/Users/a", ext: nil),
        ]
        try idx.save(records, cursor: 42)

        // Re-open fresh to ensure we re-read from disk.
        let idx2 = try BinaryIndex(path: path, pathEncryption: nil)
        let loaded = try idx2.load()

        #expect(loaded.count == records.count)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for original in records {
            let got = try #require(byID[original.id])
            #expect(got.id == original.id)
            #expect(got.name == original.name)
            #expect(got.originalName == original.originalName)
            #expect(got.path == original.path)
            #expect(got.parentPath == original.parentPath)
            #expect(got.isDirectory == original.isDirectory)
            #expect(got.size == original.size)
            #expect(got.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
            #expect(got.modifiedAt.timeIntervalSince1970 == original.modifiedAt.timeIntervalSince1970)
            #expect(got.extension == original.extension)
            #expect(got.metadata == original.metadata)
        }

        // Cursor also round-tripped.
        #expect(try idx2.loadCursor() == 42)
    }

    // MARK: - 2. Atomic write

    @Test("Atomic write leaves no .tmp and sets 600 perms")
    func atomicWrite() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }

        try idx.save([makeRecord(id: 1)])
        let bin = dir.appendingPathComponent("index.bin")
        #expect(FileManager.default.fileExists(atPath: bin.path))
        #expect(!FileManager.default.fileExists(atPath: bin.path + ".tmp"))
        let attrs = try FileManager.default.attributesOfItem(atPath: bin.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    // MARK: - 3. Version incompatibility

    @Test("Unsupported version throws and fails validateHeader")
    func unsupportedVersion() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let bin = dir.appendingPathComponent("index.bin")
        try idx.save([makeRecord(id: 1)])

        // Flip version bytes (offset 4, UInt16 LE) to 999.
        var data = try Data(contentsOf: bin)
        data[4] = 0xE7  // 999 & 0xFF
        data[5] = 0x03  // 999 >> 8
        try data.write(to: bin)

        #expect(throws: BinaryIndexError.self) {
            _ = try BinaryIndex(path: bin.path, pathEncryption: nil).load()
        }
        #expect(BinaryIndex.validateHeader(at: bin.path) == false)
    }

    // MARK: - 4. Corruption

    @Test("Truncated/garbage file throws .corrupt and fails validateHeader")
    func corruption() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let bin = dir.appendingPathComponent("index.bin")
        try idx.save([makeRecord(id: 1)])

        // Truncate to half. Header is still valid (magic+version intact), so
        // validateHeader returns true — but body parsing must fail.
        var data = try Data(contentsOf: bin)
        data = data.prefix(data.count / 2)
        try data.write(to: bin)
        // validateHeader inspects only the header, which is still well-formed.
        #expect(BinaryIndex.validateHeader(at: bin.path) == true)
        #expect(throws: BinaryIndexError.self) {
            _ = try BinaryIndex(path: bin.path, pathEncryption: nil).load()
        }

        // Overwrite magic with garbage.
        var bad = Data(repeating: 0x00, count: 32)
        bad[0] = 0x00; bad[1] = 0x01; bad[2] = 0x02; bad[3] = 0x03
        try bad.write(to: bin)
        #expect(BinaryIndex.validateHeader(at: bin.path) == false)
    }

    // MARK: - 5. Missing file

    @Test("Missing file returns empty / nil, validateHeader true (first-run)")
    func missingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-bin-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.bin").path

        let idx = try BinaryIndex(path: path, pathEncryption: nil)
        #expect(try idx.load().isEmpty)
        #expect(BinaryIndex.validateHeader(at: path) == true)
        #expect(try idx.loadCursor() == nil)
        #expect(BinaryIndex.exists(at: path) == false)
    }

    // MARK: - 6. Encryption on

    @Test("Encrypted file does not contain plaintext path; round-trips back")
    func encryptionOn() throws {
        let (enc, encCleanup) = try makeEncryption()
        defer { encCleanup() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepfinder-test-bin-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("index.bin")

        let plainPath = "/Users/secret/PATH-LEAK-CANARY.docx"
        // name is distinct from the path's leaf — name is stored plaintext, so we
        // assert only the path/parent portion is encrypted by searching for a
        // substring unique to the path that does NOT also appear in the name.
        let records = [makeRecord(id: 1, name: "displayed.docx", path: plainPath, parent: "/Users/secret")]

        let idx = try BinaryIndex(path: bin.path, pathEncryption: enc)
        try idx.save(records)

        // The raw file bytes must NOT contain the plaintext path. Search the
        // raw bytes directly (the binary format is not valid UTF-8 as a whole).
        let raw = try Data(contentsOf: bin)
        let needle1 = Data("PATH-LEAK-CANARY".utf8)
        let needle2 = Data("/Users/secret".utf8)
        #expect(raw.range(of: needle1) == nil)
        #expect(raw.range(of: needle2) == nil)

        // Reload via a fresh instance using the same encryption.
        let idx2 = try BinaryIndex(path: bin.path, pathEncryption: enc)
        let loaded = try idx2.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].path == plainPath)
        #expect(loaded[0].parentPath == "/Users/secret")
    }

    // MARK: - 7. Encryption off

    @Test("Plaintext path IS present in raw file bytes when encryption off")
    func encryptionOff() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let bin = dir.appendingPathComponent("index.bin")

        let plainPath = "/Users/open/visible-name.txt"
        try idx.save([makeRecord(id: 1, name: "visible-name.txt", path: plainPath, parent: "/Users/open")])

        let raw = try Data(contentsOf: bin)
        #expect(raw.range(of: Data("visible-name.txt".utf8)) != nil)
        #expect(raw.range(of: Data("/Users/open".utf8)) != nil)
    }

    // MARK: - 8. Cursor sidecar

    @Test("Cursor sidecar round-trips without touching index.bin mtime")
    func cursorSidecar() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let bin = dir.appendingPathComponent("index.bin")

        try idx.save([makeRecord(id: 1)])
        let binMtimeBefore = try FileManager.default.attributesOfItem(atPath: bin.path)[.modificationDate] as? Date

        // Sleep tiny bit so mtime resolution differs if touched.
        Thread.sleep(forTimeInterval: 0.05)

        try idx.saveCursor(123)
        #expect(try idx.loadCursor() == 123)

        let binMtimeAfter = try FileManager.default.attributesOfItem(atPath: bin.path)[.modificationDate] as? Date
        #expect(binMtimeAfter == binMtimeBefore)

        // Overwrite.
        try idx.saveCursor(999)
        #expect(try idx.loadCursor() == 999)

        // Cursor sidecar perms 600.
        let cursor = dir.appendingPathComponent("index.cursor")
        let attrs = try FileManager.default.attributesOfItem(atPath: cursor.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    // MARK: - 9. deleteRecords

    @Test("deleteRecords removes only the given IDs")
    func deleteRecords() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let path = dir.appendingPathComponent("index.bin").path

        try idx.save([makeRecord(id: 1), makeRecord(id: 2), makeRecord(id: 3), makeRecord(id: 4), makeRecord(id: 5)])

        let removed = try idx.deleteRecords([2, 4])
        #expect(removed == 2)

        let idx2 = try BinaryIndex(path: path, pathEncryption: nil)
        let loaded = try idx2.load()
        let ids = Set(loaded.map(\.id))
        #expect(ids == [1, 3, 5])
    }

    // MARK: - 10. deleteByPathPrefix

    @Test("deleteByPathPrefix filters by prefix (plaintext)")
    func deleteByPathPrefix() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let path = dir.appendingPathComponent("index.bin").path

        let records: [FileRecord] = [
            makeRecord(id: 1, name: "a", path: "/vol/a", parent: "/vol"),
            makeRecord(id: 2, name: "b", path: "/vol/b", parent: "/vol"),
            makeRecord(id: 3, name: "sub", path: "/vol/sub/c", parent: "/vol/sub"),
            makeRecord(id: 4, name: "other", path: "/other", parent: "/"),
        ]
        try idx.save(records)

        let removed = try idx.deleteByPathPrefix("/vol")
        #expect(removed == 3)

        let idx2 = try BinaryIndex(path: path, pathEncryption: nil)
        let loaded = try idx2.load()
        let paths = Set(loaded.map(\.path))
        #expect(paths == ["/other"])
    }

    // MARK: - 11. Large set

    @Test("5000 records round-trip")
    func largeSet() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let path = dir.appendingPathComponent("index.bin").path

        let records = (UInt32(1)...5000).map { i in
            makeRecord(id: i, name: "file\(i).dat", path: "/data/file\(i).dat", parent: "/data")
        }
        try idx.save(records)

        let idx2 = try BinaryIndex(path: path, pathEncryption: nil)
        let loaded = try idx2.load()
        #expect(loaded.count == 5000)
    }

    // MARK: - exists

    @Test("exists reflects presence of a header-valid non-empty file")
    func existsCheck() throws {
        let (idx, dir, cleanup) = try makePlain()
        defer { cleanup() }
        let bin = dir.appendingPathComponent("index.bin")

        #expect(BinaryIndex.exists(at: bin.path) == false)
        try idx.save([makeRecord(id: 1)])
        #expect(BinaryIndex.exists(at: bin.path) == true)
    }
}
