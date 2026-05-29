import Foundation
import Testing
@testable import DeepFinder

@Suite("FilterPipeline")
struct FilterPipelineTests {

    // MARK: - Helpers

    /// Create a FileRecord for testing.
    private func makeRecord(
        id: UInt32,
        name: String,
        path: String = "/test",
        size: Int64 = 100,
        isDirectory: Bool = false,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        extension ext: String? = nil
    ) -> FileRecord {
        FileRecord(
            id: id,
            name: name,
            originalName: name,
            path: path + "/" + name,
            parentPath: path,
            isDirectory: isDirectory,
            size: size,
            createdAt: modifiedAt,
            modifiedAt: modifiedAt,
            extension: ext ?? name.split(separator: ".").last.map(String.init)
        )
    }

    /// Wrap a FileRecord in a SearchResult.
    private func makeResult(
        id: UInt32,
        name: String,
        path: String = "/test",
        size: Int64 = 100,
        isDirectory: Bool = false,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        extension ext: String? = nil
    ) -> SearchResult {
        let record = makeRecord(
            id: id, name: name, path: path, size: size,
            isDirectory: isDirectory,
            modifiedAt: modifiedAt, extension: ext
        )
        return SearchResult(record: record, providerID: "test", score: 1.0, matchType: .substring)
    }

    // MARK: - Tests

    @Test("Empty pipeline returns all results")
    func testEmptyPipelineReturnsAll() {
        let pipeline = FilterPipeline(filters: [])
        let results = [
            makeResult(id: 1, name: "a.txt"),
            makeResult(id: 2, name: "b.pdf"),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 2)
    }

    @Test("Single size filter applied")
    func testSingleSizeFilter() {
        let pipeline = FilterPipeline(filters: [.sizeMin(500)])
        let results = [
            makeResult(id: 1, name: "small.txt", size: 100),
            makeResult(id: 2, name: "medium.txt", size: 600),
            makeResult(id: 3, name: "large.txt", size: 2000),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 2)
        #expect(filtered[0].record.name == "medium.txt")
        #expect(filtered[1].record.name == "large.txt")
    }

    @Test("Multiple filters use AND logic")
    func testMultipleFiltersAndLogic() {
        let pipeline = FilterPipeline(filters: [
            .sizeMin(200),
            .isFile,
        ])
        let results = [
            makeResult(id: 1, name: "big.txt", size: 500, isDirectory: false),
            makeResult(id: 2, name: "small.txt", size: 50, isDirectory: false),
            makeResult(id: 3, name: "dir", size: 500, isDirectory: true),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 1)
        #expect(filtered[0].record.name == "big.txt")
    }

    @Test("Size + extension combined")
    func testSizeAndExtensionCombined() {
        let pipeline = FilterPipeline(filters: [
            .sizeMin(1024),
            .extensionFilter(["pdf"]),
        ])
        let results = [
            makeResult(id: 1, name: "report.pdf", size: 2048),
            makeResult(id: 2, name: "report.txt", size: 2048),
            makeResult(id: 3, name: "small.pdf", size: 512),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 1)
        #expect(filtered[0].record.name == "report.pdf")
    }

    @Test("File type group filter (file: and folder:)")
    func testFileTypeGroupFilter() {
        let filesOnly = FilterPipeline(filters: [.isFile])
        let foldersOnly = FilterPipeline(filters: [.isDirectory])

        let results = [
            makeResult(id: 1, name: "doc.txt", isDirectory: false),
            makeResult(id: 2, name: "folder", isDirectory: true),
            makeResult(id: 3, name: "code.swift", isDirectory: false),
        ]

        let files = filesOnly.apply(to: results)
        #expect(files.count == 2)
        #expect(files.allSatisfy { !$0.record.isDirectory })

        let folders = foldersOnly.apply(to: results)
        #expect(folders.count == 1)
        #expect(folders[0].record.isDirectory)
    }

    @Test("Date range filter")
    func testDateRangeFilter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_000 + 86400) // +1 day

        let pipeline = FilterPipeline(filters: [.dateModifiedRange(start..<end)])

        let midPoint = Date(timeIntervalSince1970: 1_700_000_000 + 43200)
        let results = [
            makeResult(id: 1, name: "at-start.txt", modifiedAt: start),
            makeResult(id: 2, name: "too-early.txt", modifiedAt: Date(timeIntervalSince1970: 1_699_990_000)),
            makeResult(id: 3, name: "mid-range.txt", modifiedAt: midPoint),
            makeResult(id: 4, name: "at-end.txt", modifiedAt: end),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 2)
        #expect(filtered[0].record.name == "at-start.txt")
        #expect(filtered[1].record.name == "mid-range.txt")
    }

    @Test("Max depth filter")
    func testMaxDepthFilter() {
        let pipeline = FilterPipeline(filters: [.maxDepth(2)])
        let results = [
            makeResult(id: 1, name: "a.txt", path: ""),             // final: "/a.txt" -> depth 1
            makeResult(id: 2, name: "b.txt", path: "/usr"),         // final: "/usr/b.txt" -> depth 2
            makeResult(id: 3, name: "c.txt", path: "/usr/local"),   // final: "/usr/local/c.txt" -> depth 3
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 2)
        #expect(filtered[0].record.name == "a.txt")
        #expect(filtered[1].record.name == "b.txt")
    }

    @Test("Parse from modifier pairs")
    func testParseFromModifierPairs() {
        let modifiers: [(key: String, value: String)] = [
            ("size", ">1mb"),
            ("ext", "pdf"),
        ]

        let pipeline = FilterPipeline.parse(from: modifiers)
        #expect(pipeline.filters.count == 2)

        // Verify the pipeline works end-to-end
        let results = [
            makeResult(id: 1, name: "report.pdf", size: 2_000_000),
            makeResult(id: 2, name: "report.txt", size: 2_000_000),
            makeResult(id: 3, name: "small.pdf", size: 500),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 1)
        #expect(filtered[0].record.name == "report.pdf")
    }

    @Test("Filter removes non-matching results")
    func testFilterRemovesNonMatching() {
        let pipeline = FilterPipeline(filters: [.extensionFilter(["pdf"])])
        let results = [
            makeResult(id: 1, name: "a.pdf"),
            makeResult(id: 2, name: "b.txt"),
            makeResult(id: 3, name: "c.doc"),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 1)
        #expect(filtered[0].record.name == "a.pdf")
    }

    @Test("Filter preserves order of matching results")
    func testFilterPreservesOrder() {
        let pipeline = FilterPipeline(filters: [.sizeMin(0)])
        let results = [
            makeResult(id: 3, name: "gamma.txt", size: 50),
            makeResult(id: 1, name: "alpha.txt", size: 100),
            makeResult(id: 2, name: "beta.txt", size: 200),
        ]

        let filtered = pipeline.apply(to: results)
        #expect(filtered.count == 3)
        // Order must be preserved: gamma, alpha, beta
        #expect(filtered[0].record.name == "gamma.txt")
        #expect(filtered[1].record.name == "alpha.txt")
        #expect(filtered[2].record.name == "beta.txt")
    }
}
