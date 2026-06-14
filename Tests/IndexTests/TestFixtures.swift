import Testing
import Foundation
@testable import DeepFinderIndex

// MARK: - FileRecordGenerator

/// Configurable random FileRecord generator for testing.
///
/// Produces deterministic records when given a seed, enabling reproducible
/// test runs. Names are drawn from a built-in pool of realistic filenames
/// spanning multiple languages and character sets.
public enum FileRecordGenerator {

    /// Built-in pool of realistic filenames for generation.
    public static let namePool: [String] = [
        "report.pdf", "photo.jpg", "data.csv", "README.md",
        "main.swift", "index.html", "config.json", "styles.css",
        "季度报告.pdf", "照片.png", "数据.xlsx", "说明.txt",
        "🚀launch.swift", "naïve_response.json", "résumé.docx",
        "very_long_filename_with_many_words_and_underscores_v2_final_final.swift",
        "archive.tar.gz", "backup_2026-06-12.zip", "presentation.key",
        "budget.ods", "track01.mp3", "video_720p.mp4", "subtitles.srt",
        "IMG_20260612_143522.heic", "screenshot.png", "notes.md",
        "Package.swift", "Makefile", "Dockerfile", ".gitignore",
        "project.xcodeproj", "Podfile", "Gemfile", "Cargo.toml",
    ]

    /// Parent directory pool for path generation.
    private static let parentPool: [String] = [
        "/Users/test/Documents",
        "/Users/test/Downloads",
        "/Users/test/Desktop",
        "/Users/test/Pictures",
        "/Users/test/Music",
        "/Users/test/Projects",
        "/Users/test/开发",
        "/Users/test/文档",
        "/Volumes/External",
        "/tmp/test",
    ]

    /// Generate a single random FileRecord.
    ///
    /// - Parameters:
    ///   - id: Record ID (auto-assigned if nil).
    ///   - seed: Random seed for deterministic generation.
    ///   - index: Position index for name/path variation.
    /// - Returns: A FileRecord with realistic test data.
    public static func makeRecord(
        id: UInt32? = nil,
        seed: UInt64 = 42,
        index: Int = 0
    ) -> FileRecord {
        let nameIndex = Int(seed) &+ index % namePool.count
        let parentIndex = Int(seed) &+ index % parentPool.count
        let name = namePool[nameIndex % namePool.count]
        let parent = parentPool[parentIndex % parentPool.count]
        let ext = name.contains(".") ? name.split(separator: ".").last.map(String.init) : nil
        let isDir = index % 5 == 0  // ~20% directories

        return FileRecord(
            id: id ?? UInt32(index &+ 1),
            name: name.precomposedStringWithCanonicalMapping,
            originalName: name,
            path: "\(parent)/\(name)",
            parentPath: parent,
            isDirectory: isDir,
            size: Int64(abs(Int(seed) * (index + 1) * 1024) % 1_073_741_824),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 3600)),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 3600 + 1800)),
            extension: ext
        )
    }

    /// Generate an array of random FileRecords.
    ///
    /// - Parameters:
    ///   - count: Number of records to generate.
    ///   - seed: Random seed for deterministic generation.
    /// - Returns: Array of unique FileRecords with sequential IDs.
    public static func makeRecords(count: Int, seed: UInt64 = 42) -> [FileRecord] {
        (0..<count).map { makeRecord(seed: seed, index: $0) }
    }

    /// Populate an InMemoryIndex with generated records.
    ///
    /// - Parameters:
    ///   - index: The index actor to populate.
    ///   - count: Number of records to insert.
    ///   - seed: Random seed for deterministic generation.
    public static func populate(
        index: InMemoryIndex,
        count: Int,
        seed: UInt64 = 42
    ) async {
        let records = makeRecords(count: count, seed: seed)
        await index.insertBatch(records)
    }
}

// MARK: - EdgeCaseFixtures

/// Edge-case FileRecords for boundary testing.
///
/// Covers: empty-ish names, very long names, emoji, NFD/NFC mixing,
/// special characters, Unicode edge cases, and extreme sizes.
public enum EdgeCaseFixtures {

    /// FileRecord with a single-character name.
    public static let singleChar = FileRecord(
        id: 9001, name: "a", originalName: "a",
        path: "/tmp/a", parentPath: "/tmp",
        isDirectory: false, size: 0,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: nil
    )

    /// FileRecord with a name that is just an extension (no basename).
    public static let dotfile = FileRecord(
        id: 9002, name: ".gitignore", originalName: ".gitignore",
        path: "/project/.gitignore", parentPath: "/project",
        isDirectory: false, size: 128,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "gitignore"
    )

    /// FileRecord with a long filename (100+ characters).
    public static let longName = FileRecord(
        id: 9003,
        name: String(repeating: "a", count: 120),
        originalName: String(repeating: "a", count: 120),
        path: "/tmp/\(String(repeating: "a", count: 120))",
        parentPath: "/tmp",
        isDirectory: false, size: 1024,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: nil
    )

    /// FileRecord with emoji in the name.
    public static let emoji = FileRecord(
        id: 9004, name: "🎉party🎊.txt", originalName: "🎉party🎊.txt",
        path: "/tmp/🎉party🎊.txt", parentPath: "/tmp",
        isDirectory: false, size: 42,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "txt"
    )

    /// FileRecord with a NFD-normalized name (decomposed).
    /// "café" in NFD form: "cafe\u{0301}"
    public static let nfdName = FileRecord(
        id: 9005,
        name: "cafe\u{0301}.txt".precomposedStringWithCanonicalMapping,
        originalName: "cafe\u{0301}.txt",
        path: "/tmp/cafe\u{0301}.txt",
        parentPath: "/tmp",
        isDirectory: false, size: 256,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "txt"
    )

    /// FileRecord with a NFC-normalized name (precomposed).
    /// "café" in NFC form: "caf\u{00E9}"
    public static let nfcName = FileRecord(
        id: 9006,
        name: "caf\u{00E9}.txt".precomposedStringWithCanonicalMapping,
        originalName: "caf\u{00E9}.txt",
        path: "/tmp/caf\u{00E9}.txt",
        parentPath: "/tmp",
        isDirectory: false, size: 256,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "txt"
    )

    /// FileRecord with special characters in the name.
    public static let specialChars = FileRecord(
        id: 9007, name: "file (copy) [2] & co's @home #1 $.txt",
        originalName: "file (copy) [2] & co's @home #1 $.txt",
        path: "/tmp/file (copy) [2] & co's @home #1 $.txt",
        parentPath: "/tmp",
        isDirectory: false, size: 512,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "txt"
    )

    /// FileRecord with mixed CJK and ASCII name.
    public static let mixedCJK = FileRecord(
        id: 9008, name: "Q3报告_final.xlsx", originalName: "Q3报告_final.xlsx",
        path: "/tmp/Q3报告_final.xlsx", parentPath: "/tmp",
        isDirectory: false, size: 2048,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "xlsx"
    )

    /// FileRecord with zero-byte size (empty file).
    public static let emptyFile = FileRecord(
        id: 9009, name: "empty.log", originalName: "empty.log",
        path: "/tmp/empty.log", parentPath: "/tmp",
        isDirectory: false, size: 0,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: "log"
    )

    /// FileRecord that is a directory.
    public static let directory = FileRecord(
        id: 9010, name: "Documents", originalName: "Documents",
        path: "/Users/test/Documents", parentPath: "/Users/test",
        isDirectory: true, size: 0,
        createdAt: .distantPast, modifiedAt: .distantPast, extension: nil
    )

    /// All edge-case fixtures as an array.
    public static let all: [FileRecord] = [
        singleChar, dotfile, longName, emoji, nfdName,
        nfcName, specialChars, mixedCJK, emptyFile, directory,
    ]
}

// MARK: - PerformanceFixtures

/// Scale-specific test data for benchmarking.
///
/// Provides pre-configured InMemoryIndex instances at 10K, 100K scales.
/// 1M scale is available but may take several seconds to build.
public enum PerformanceFixtures {

    /// Build an InMemoryIndex populated with the given number of records.
    ///
    /// - Parameters:
    ///   - count: Number of records to generate and insert.
    ///   - seed: Random seed for deterministic generation.
    /// - Returns: A populated InMemoryIndex actor.
    public static func buildIndex(count: Int, seed: UInt64 = 42) async -> InMemoryIndex {
        let index = InMemoryIndex()
        await FileRecordGenerator.populate(index: index, count: count, seed: seed)
        return index
    }

    /// Convenience: 10K record index.
    public static func index10K() async -> InMemoryIndex {
        await buildIndex(count: 10_000)
    }

    /// Convenience: 100K record index.
    public static func index100K() async -> InMemoryIndex {
        await buildIndex(count: 100_000)
    }

    /// Convenience: 1M record index (stress scale; slow to build — use sparingly).
    public static func index1M() async -> InMemoryIndex {
        await buildIndex(count: 1_000_000)
    }
}

// MARK: - Fixture Tests

struct TestFixtureTests {

    @Test func fileRecordGeneratorMakesUniqueRecords() {
        let records = FileRecordGenerator.makeRecords(count: 50)
        let paths = Set(records.map(\.path))
        #expect(paths.count == records.count)
    }

    @Test func edgeCaseFixturesAllValid() {
        for record in EdgeCaseFixtures.all {
            #expect(!record.name.isEmpty || record.name == ".gitignore")
            #expect(!record.path.isEmpty)
            #expect(record.id > 0)
        }
    }

    @Test func nfdNfcNormalizationConsistency() {
        // Both NFD and NFC names should normalize to the same form
        let nfd = EdgeCaseFixtures.nfdName.name
        let nfc = EdgeCaseFixtures.nfcName.name
        #expect(nfd == nfc)  // Both go through precomposedStringWithCanonicalMapping
    }

    @Test func generatorPopulatesIndex() async {
        let index = InMemoryIndex()
        await FileRecordGenerator.populate(index: index, count: 100)
        #expect(await index.count == 100)
    }

    @Test func performanceFixturesBuild10K() async {
        let index = await PerformanceFixtures.index10K()
        #expect(await index.count == 10_000)

        // Should be searchable
        let results = await index.search(query: "pdf")
        #expect(!results.isEmpty)
    }
}
