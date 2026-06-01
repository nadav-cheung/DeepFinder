import Foundation
import Testing
@testable import DeepFinder

/// Performance benchmarks for the Search layer.
///
/// Uses Swift Testing with manual timing via ContinuousClock.
/// These always pass -- they measure and report, not assert on timing.
/// Large-scale (1M) benchmarks are separate manual targets; these use 10K-100K.
///
/// Run: `swift test --filter SearchBenchmarks`
struct SearchBenchmarks {

    // MARK: - Helpers

    private let nameFragments = [
        "test", "report", "doc", "data", "config",
        "log", "cache", "temp", "backup", "notes",
        "photo", "video", "audio", "script", "readme",
    ]

    private let extensions = [
        "txt", "pdf", "doc", "xlsx", "png",
        "jpg", "mp4", "swift", "json", "xml",
    ]

    /// Generate synthetic FileRecords for benchmarking.
    private func generateRecords(count: Int) -> [FileRecord] {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            let frag = nameFragments[i % nameFragments.count]
            let ext = extensions[i % extensions.count]
            let name = "file_\(i)_\(frag).\(ext)"
            let dirNum = i % 100
            return FileRecord(
                id: UInt32(i),
                name: name.precomposedStringWithCanonicalMapping,
                originalName: name,
                path: "/Users/test/dir\(dirNum)/\(name)",
                parentPath: "/Users/test/dir\(dirNum)",
                isDirectory: false,
                size: Int64.random(in: 100...1_000_000),
                createdAt: baseDate.addingTimeInterval(Double(i)),
                modifiedAt: baseDate.addingTimeInterval(Double(i) + 100),
                extension: ext
            )
        }
    }

    // MARK: - 1. Index Construction 10K

    /// Measure time to build InMemoryIndex with 10K records.
    /// 100K+ benchmarks should be run in a dedicated performance harness.
    @Test func indexConstruction10K() async {
        let records = generateRecords(count: 10_000)

        let start = ContinuousClock.now
        let index = await InMemoryIndex()
        for record in records {
            await index.insert(record)
        }
        let duration = ContinuousClock.now - start

        let count = await index.count
        #expect(count == 10_000, "Index should contain all records")

        let seconds = duration / .seconds(1)
        print("[Benchmark] Index construction 10K: \(String(format: "%.3f", seconds))s")
    }

    // MARK: - 2. Search Latency 10K

    /// End-to-end search latency with 10K records.
    @Test func searchLatency10K() async throws {
        let records = generateRecords(count: 10_000)
        let index = await InMemoryIndex()
        for record in records {
            await index.insert(record)
        }
        let provider = FileIndexProvider(index: index)
        let coordinator = SearchCoordinator(providers: [provider])

        // Warm up
        _ = await coordinator.search(query: "data")

        // Measure
        let start = ContinuousClock.now
        _ = await coordinator.search(query: "data")
        let duration = ContinuousClock.now - start

        let milliseconds = duration / .milliseconds(1)
        print("[Benchmark] Search latency 10K: \(String(format: "%.3f", milliseconds))ms")
    }

    // MARK: - 3. Sort Performance

    /// Sorting 10K results by relevance.
    @Test func sortPerformance() {
        let results = generateSearchResults(count: 10_000)

        // Warm up
        _ = SearchSorter.sort(results, by: .relevance)

        // Measure
        let start = ContinuousClock.now
        _ = SearchSorter.sort(results, by: .relevance)
        let duration = ContinuousClock.now - start

        let milliseconds = duration / .milliseconds(1)
        print("[Benchmark] Sort 10K: \(String(format: "%.3f", milliseconds))ms")
    }

    // MARK: - Helpers

    private func generateSearchResults(count: Int) -> [SearchResult] {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let matchTypes: [MatchType] = [.exact, .prefix, .substring, .pinyin]
        let scores: [Double] = [1.0, 0.8, 0.5, 0.3]

        return (0..<count).map { i in
            let frag = nameFragments[i % nameFragments.count]
            let ext = extensions[i % extensions.count]
            let name = "result_\(i)_\(frag).\(ext)"
            let dirNum = i % 100
            let record = FileRecord(
                id: UInt32(i),
                name: name,
                originalName: name,
                path: "/Users/test/dir\(dirNum)/\(name)",
                parentPath: "/Users/test/dir\(dirNum)",
                isDirectory: false,
                size: Int64.random(in: 100...1_000_000),
                createdAt: baseDate.addingTimeInterval(Double(i)),
                modifiedAt: baseDate.addingTimeInterval(Double(i) + 100),
                extension: ext
            )
            let matchIndex = i % matchTypes.count
            return SearchResult(
                record: record,
                providerID: "bench",
                score: scores[matchIndex],
                matchType: matchTypes[matchIndex]
            )
        }
    }
}
