import Foundation
import Testing
import DeepFinderAI
import DeepFinderPersist
import DeepFinderIndex
@testable import DeepFinderSearch

@Suite("DuplicateFinder")
struct DuplicateFinderTests {

    // MARK: - Helpers

    private func makeRecord(
        id: UInt32,
        name: String,
        path: String,
        parentPath: String,
        isDirectory: Bool = false,
        size: Int64 = 0
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: path,
            parentPath: parentPath,
            isDirectory: isDirectory,
            size: size,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: isDirectory ? nil : (name.components(separatedBy: ".").last)
        )
    }

    private func makePopulatedIndex(
        _ populate: (InMemoryIndex) async -> Void
    ) async -> InMemoryIndex {
        let index = InMemoryIndex()
        await populate(index)
        return index
    }

    // MARK: - findByName

    @Test("findByName groups files with same name")
    func findByNameGroupsSameName() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "photo.jpg",
                path: "/Users/test/Photos/photo.jpg",
                parentPath: "/Users/test/Photos", size: 2048
            ))
            await idx.insert(makeRecord(
                id: 2, name: "photo.jpg",
                path: "/Users/test/Backup/photo.jpg",
                parentPath: "/Users/test/Backup", size: 3072
            ))
            await idx.insert(makeRecord(
                id: 3, name: "document.pdf",
                path: "/Users/test/document.pdf",
                parentPath: "/Users/test", size: 4096
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findByName()

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.key == "photo.jpg")
        #expect(group.records.count == 2)
        let ids = Set(group.records.map(\.id))
        #expect(ids == [1, 2])
    }

    @Test("findByName does not group files with different names")
    func findByNameDifferentNamesNotGrouped() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "photo.jpg",
                path: "/Users/test/photo.jpg",
                parentPath: "/Users/test", size: 100
            ))
            await idx.insert(makeRecord(
                id: 2, name: "document.pdf",
                path: "/Users/test/document.pdf",
                parentPath: "/Users/test", size: 200
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findByName()

        #expect(groups.isEmpty)
    }

    // MARK: - findBySize

    @Test("findBySize groups files with same size")
    func findBySizeGroupsSameSize() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "a.bin",
                path: "/Users/test/a.bin",
                parentPath: "/Users/test", size: 4096
            ))
            await idx.insert(makeRecord(
                id: 2, name: "b.bin",
                path: "/Users/test/b.bin",
                parentPath: "/Users/test", size: 4096
            ))
            await idx.insert(makeRecord(
                id: 3, name: "c.bin",
                path: "/Users/test/c.bin",
                parentPath: "/Users/test", size: 8192
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findBySize()

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.key == "4096")
        #expect(group.records.count == 2)
        let ids = Set(group.records.map(\.id))
        #expect(ids == [1, 2])
    }

    @Test("findBySize does not group files with different sizes")
    func findBySizeDifferentSizesNotGrouped() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "a.bin",
                path: "/Users/test/a.bin",
                parentPath: "/Users/test", size: 100
            ))
            await idx.insert(makeRecord(
                id: 2, name: "b.bin",
                path: "/Users/test/b.bin",
                parentPath: "/Users/test", size: 200
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findBySize()

        #expect(groups.isEmpty)
    }

    // MARK: - findEmpty

    @Test("findEmpty finds zero-byte files")
    func findEmptyFindsZeroByteFiles() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "empty.txt",
                path: "/Users/test/empty.txt",
                parentPath: "/Users/test", size: 0
            ))
            await idx.insert(makeRecord(
                id: 2, name: "nonempty.txt",
                path: "/Users/test/nonempty.txt",
                parentPath: "/Users/test", size: 10
            ))
        }

        let finder = DuplicateFinder(index: index)
        let empties = await finder.findEmpty()

        #expect(empties.count == 1)
        #expect(empties[0].id == 1)
    }

    @Test("findEmpty finds empty directories")
    func findEmptyFindsEmptyDirectories() async {
        let index = await makePopulatedIndex { idx in
            // Empty directory: no other record has parentPath matching its path
            await idx.insert(makeRecord(
                id: 1, name: "emptydir",
                path: "/Users/test/emptydir",
                parentPath: "/Users/test",
                isDirectory: true, size: 0
            ))
            // Non-empty directory: record 3 is a child of record 2
            await idx.insert(makeRecord(
                id: 2, name: "fulldir",
                path: "/Users/test/fulldir",
                parentPath: "/Users/test",
                isDirectory: true, size: 0
            ))
            await idx.insert(makeRecord(
                id: 3, name: "file.txt",
                path: "/Users/test/fulldir/file.txt",
                parentPath: "/Users/test/fulldir", size: 50
            ))
        }

        let finder = DuplicateFinder(index: index)
        let empties = await finder.findEmpty()

        let ids = Set(empties.map(\.id))
        #expect(ids.contains(1))
        #expect(!ids.contains(2))
    }

    // MARK: - findByHash

    @Test("findByHash groups files with identical content")
    func findByHashGroupsIdenticalContent() async throws {
        let content = Data("Hello DeepFinder".utf8)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        let fileC = dir.appendingPathComponent("c.txt")
        try content.write(to: fileA)
        try content.write(to: fileB)
        try Data("different".utf8).write(to: fileC)

        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "a.txt",
                path: fileA.path,
                parentPath: dir.path,
                size: Int64(content.count)
            ))
            await idx.insert(makeRecord(
                id: 2, name: "b.txt",
                path: fileB.path,
                parentPath: dir.path,
                size: Int64(content.count)
            ))
            await idx.insert(makeRecord(
                id: 3, name: "c.txt",
                path: fileC.path,
                parentPath: dir.path,
                size: Int64(10)
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findByHash(
            paths: [fileA.path, fileB.path, fileC.path]
        )

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.records.count == 2)
        let ids = Set(group.records.map(\.id))
        #expect(ids == [1, 2])
    }

    @Test("findByHash does not group files with different content")
    func findByHashDifferentContentNotGrouped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.txt")
        let fileB = dir.appendingPathComponent("b.txt")
        try Data("content A".utf8).write(to: fileA)
        try Data("content B".utf8).write(to: fileB)

        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "a.txt",
                path: fileA.path,
                parentPath: dir.path, size: 9
            ))
            await idx.insert(makeRecord(
                id: 2, name: "b.txt",
                path: fileB.path,
                parentPath: dir.path, size: 9
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findByHash(
            paths: [fileA.path, fileB.path]
        )

        #expect(groups.isEmpty)
    }

    // MARK: - findByChildCount

    @Test("findByChildCount groups directories by child count")
    func findByChildCountGroups() async {
        let index = await makePopulatedIndex { idx in
            // dirA has 2 children
            await idx.insert(makeRecord(
                id: 1, name: "dirA",
                path: "/Users/test/dirA",
                parentPath: "/Users/test",
                isDirectory: true
            ))
            await idx.insert(makeRecord(
                id: 2, name: "f1.txt",
                path: "/Users/test/dirA/f1.txt",
                parentPath: "/Users/test/dirA", size: 10
            ))
            await idx.insert(makeRecord(
                id: 3, name: "f2.txt",
                path: "/Users/test/dirA/f2.txt",
                parentPath: "/Users/test/dirA", size: 20
            ))
            // dirB also has 2 children
            await idx.insert(makeRecord(
                id: 4, name: "dirB",
                path: "/Users/test/dirB",
                parentPath: "/Users/test",
                isDirectory: true
            ))
            await idx.insert(makeRecord(
                id: 5, name: "g1.txt",
                path: "/Users/test/dirB/g1.txt",
                parentPath: "/Users/test/dirB", size: 30
            ))
            await idx.insert(makeRecord(
                id: 6, name: "g2.txt",
                path: "/Users/test/dirB/g2.txt",
                parentPath: "/Users/test/dirB", size: 40
            ))
        }

        let finder = DuplicateFinder(index: index)
        let groups = await finder.findByChildCount(minCount: 2)

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.key == "2")
        let dirIDs = Set(group.records.map(\.id))
        #expect(dirIDs == [1, 4])
    }

    // MARK: - No duplicates

    @Test("No duplicates returns empty results")
    func noDuplicatesReturnsEmpty() async {
        let index = await makePopulatedIndex { idx in
            await idx.insert(makeRecord(
                id: 1, name: "unique.txt",
                path: "/Users/test/unique.txt",
                parentPath: "/Users/test", size: 100
            ))
        }

        let finder = DuplicateFinder(index: index)
        let byName = await finder.findByName()
        let bySize = await finder.findBySize()
        let empties = await finder.findEmpty()

        #expect(byName.isEmpty)
        #expect(bySize.isEmpty)
        #expect(empties.isEmpty)
    }

    // MARK: - FileHasher

    @Test("SHA-256 hash of known content matches expected value")
    func sha256OfKnownContent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: dir) }

        // SHA-256 of empty string: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let file = dir.appendingPathComponent("empty.dat")
        try Data().write(to: file)

        let hash = FileHasher.sha256(ofFileAtPath: file.path)
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 of non-existent file returns nil")
    func sha256OfNonExistentFile() async {
        let hash = FileHasher.sha256(ofFileAtPath: "/nonexistent/path/file.dat")
        #expect(hash == nil)
    }

    @Test("SHA-256 hash of empty file is valid SHA-256")
    func sha256OfEmptyFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("empty.dat")
        try Data().write(to: file)

        let hash = FileHasher.sha256(ofFileAtPath: file.path)
        #expect(hash != nil)
        // SHA-256 hex digest is always 64 characters
        #expect(hash!.count == 64)
        // Known SHA-256 of empty data
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("SHA-256 hash is consistent across multiple calls")
    func sha256Consistency() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("consistent.dat")
        try Data("consistency test data".utf8).write(to: file)

        let hash1 = FileHasher.sha256(ofFileAtPath: file.path)
        let hash2 = FileHasher.sha256(ofFileAtPath: file.path)
        #expect(hash1 != nil)
        #expect(hash1 == hash2)
    }

    @Test("SHA-256 of file with known content matches expected value")
    func sha256OfKnownContentHello() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)

        // SHA-256 of "hello": 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let hash = FileHasher.sha256(ofFileAtPath: file.path)
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
