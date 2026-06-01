import Foundation
import Testing
@testable import DeepFinder

// MARK: - Tags

extension Tag {
    @Tag static var performance: Tag
}

/// Performance benchmarks for the Index layer.
///
/// Uses `ContinuousClock` for deterministic performance tracking.
/// Each benchmark verifies correctness (not just timing) — search
/// operations must return expected results.
///
/// Run: `swift test --filter IndexBenchmarks`
@Suite("Index Benchmarks", .tags(.performance))
struct IndexBenchmarks {

    // MARK: - Common Helpers

    private static let nameFragments = [
        "report", "document", "data", "config", "analysis",
        "presentation", "notes", "draft", "final", "review",
        "budget", "proposal", "summary", "archive", "template",
        "invoice", "contract", "specification", "manual", "guide",
    ]

    private static let extensions = [
        "txt", "pdf", "docx", "xlsx", "pptx",
        "png", "jpg", "mp4", "swift", "json",
    ]

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static let chineseWords = [
        "报告", "文件", "数据", "搜索", "测试",
        "下载", "图片", "视频", "音乐", "文档",
    ]

    /// Generate a filename for the given index. Produces varied names across
    /// fragments and extensions to create a realistic, branching index.
    private static func makeFileName(_ i: Int) -> String {
        let frag = nameFragments[i % nameFragments.count]
        let ext = extensions[i % extensions.count]
        return "file_\(i)_\(frag).\(ext)"
    }

    /// Generate a long filename (> 64 chars) for TrigramIndex benchmarks.
    private static func makeLongFileName(_ i: Int) -> String {
        let frag = nameFragments[i % nameFragments.count]
        let ext = extensions[i % extensions.count]
        // Pad with repeated segment to exceed 64 characters
        let padding = String(repeating: "x", count: 50)
        return "long_file_\(i)_\(frag)_\(padding).\(ext)"
    }

    /// Generate a FileRecord with pre-assigned ID.
    private static func makeRecord(_ i: Int) -> FileRecord {
        let name = makeFileName(i)
        let ext = extensions[i % extensions.count]
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

    /// Format a Duration to seconds with 3 decimal places for consistent log output.
    private static func formatSeconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.3f", seconds) + "s"
    }

    // MARK: - 1. Trie Benchmarks

    /// Measure bulk insertion of 10K words into a Trie.
    /// Each word is converted to a `[UnicodeScalar]` key matching how
    /// `InMemoryIndex` uses the Trie for filename prefix indexing.
    @Test("Trie insert 10K words")
    func trieInsert10K() {
        let count = 10_000
        let scalars: [[UnicodeScalar]] = (0..<count).map { i in
            Array(Self.makeFileName(i).unicodeScalars)
        }

        var trie = Trie<UnicodeScalar, UInt32>()
        let clock = ContinuousClock()
        let duration = clock.measure {
            for i in 0..<count {
                trie.insert(scalars[i], value: UInt32(i))
            }
        }

        // Verify correctness: all entries accounted for
        #expect(trie.count == count, "Trie should contain all \(count) inserted entries")

        print("[Benchmark] Trie insert 10K: \(Self.formatSeconds(duration))")
    }

    /// Measure prefix search when the prefix matches many entries (warm path —
    /// deeper subtree traversal, more results collected).
    @Test("Trie prefix search (warm) — common prefix matching many entries")
    func triePrefixSearchWarm() {
        let count = 10_000
        var trie = Trie<UnicodeScalar, UInt32>()
        for i in 0..<count {
            trie.insert(Array(Self.makeFileName(i).unicodeScalars), value: UInt32(i))
        }

        let prefix = Array("file_".unicodeScalars)

        // Warm-up (excluded from measurement)
        _ = trie.search(prefix: prefix)

        let clock = ContinuousClock()
        let duration = clock.measure {
            _ = trie.search(prefix: prefix)
        }

        let results = trie.search(prefix: prefix)
        // "file_" is a prefix of every generated name, so all 10K should match
        #expect(results.count == count,
                "Prefix 'file_' should match all \(count) entries, got \(results.count)")

        print("[Benchmark] Trie prefix search (warm, \(results.count) results): \(Self.formatSeconds(duration))")
    }

    /// Measure prefix search when the prefix matches very few entries (cold path —
    /// shallow traversal, few results).
    @Test("Trie prefix search (cold) — rare prefix matching few entries")
    func triePrefixSearchCold() {
        let count = 10_000
        var trie = Trie<UnicodeScalar, UInt32>()
        for i in 0..<count {
            trie.insert(Array(Self.makeFileName(i).unicodeScalars), value: UInt32(i))
        }

        // A prefix that is unlikely to match any generated filename
        let prefix = Array("zzz_nonexistent".unicodeScalars)

        // Warm-up
        _ = trie.search(prefix: prefix)

        let clock = ContinuousClock()
        let duration = clock.measure {
            _ = trie.search(prefix: prefix)
        }

        let results = trie.search(prefix: prefix)
        #expect(results.isEmpty,
                "Prefix 'zzz_nonexistent' should match zero entries, got \(results.count)")

        print("[Benchmark] Trie prefix search (cold, \(results.count) results): \(Self.formatSeconds(duration))")
    }

    // MARK: - 2. FullSubstringMap Benchmarks

    /// Measure bulk insertion of 10K filenames (each <= 64 chars) into a
    /// FullSubstringMap, which precomputes all O(n^2) substrings per name.
    @Test("FullSubstringMap insert 10K names")
    func fullSubstringMapInsert10K() {
        let count = 10_000
        let names: [(name: String, id: UInt32)] = (0..<count).map { i in
            (Self.makeFileName(i), UInt32(i))
        }

        var map = FullSubstringMap()
        let clock = ContinuousClock()
        let duration = clock.measure {
            for (name, id) in names {
                map.insert(name: name, id: id)
            }
        }

        #expect(map.count == count,
                "FullSubstringMap should contain all \(count) entries, got \(map.count)")

        print("[Benchmark] FullSubstringMap insert 10K: \(Self.formatSeconds(duration))")
    }

    /// Measure substring lookup on a populated FullSubstringMap.
    /// Verifies that searching for a common fragment returns expected results.
    @Test("FullSubstringMap substring lookup")
    func fullSubstringMapSubstringLookup() {
        let count = 10_000
        var map = FullSubstringMap()
        for i in 0..<count {
            map.insert(name: Self.makeFileName(i), id: UInt32(i))
        }

        // "report" appears in every file where i % 20 == 0 (name fragment rotation)
        let query = "report"

        // Warm-up
        _ = map.search(substring: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = clock.measure {
            let ids = map.search(substring: query)
            resultCount = ids.count
        }

        // "report" is the first fragment; it appears when i % 20 == 0 → 500 of 10K
        #expect(resultCount > 0,
                "Substring 'report' should match at least one entry, got 0")

        // Non-existent substring should return empty
        let noMatch = map.search(substring: "zzz_nonexistent_xyz")
        #expect(noMatch.isEmpty,
                "Non-existent substring should return empty, got \(noMatch.count)")

        print("[Benchmark] FullSubstringMap lookup '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    // MARK: - 3. TrigramIndex Benchmarks

    /// Measure bulk insertion of 10K long filenames (> 64 chars) into a
    /// TrigramIndex. Each name generates (n-2) trigrams for posting lists.
    @Test("TrigramIndex insert 10K long names")
    func trigramIndexInsert10K() {
        let count = 10_000
        let names: [(name: String, id: UInt32)] = (0..<count).map { i in
            (Self.makeLongFileName(i), UInt32(i))
        }

        // Verify names actually exceed 64 chars
        #expect(names[0].name.count > 64,
                "Long filename should be > 64 chars, got \(names[0].name.count)")

        var index = TrigramIndex()
        let clock = ContinuousClock()
        let duration = clock.measure {
            for (name, id) in names {
                index.insert(name: name, id: id)
            }
        }

        #expect(index.count == count,
                "TrigramIndex should contain all \(count) entries, got \(index.count)")

        print("[Benchmark] TrigramIndex insert 10K: \(Self.formatSeconds(duration))")
    }

    /// Measure trigram search with a query of 3+ Unicode scalars (the fast path
    /// using posting-list intersection + exact verification).
    @Test("TrigramIndex search (>=3 scalars) — posting-list intersection")
    func trigramIndexSearchLongQuery() {
        let count = 10_000
        var index = TrigramIndex()
        for i in 0..<count {
            index.insert(name: Self.makeLongFileName(i), id: UInt32(i))
        }

        // "long" is a substring present in every generated long filename
        let query = "long"

        // Warm-up
        _ = index.search(substring: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = clock.measure {
            let ids = index.search(substring: query)
            resultCount = ids.count
        }

        #expect(resultCount > 0,
                "Trigram search for 'long' should match at least one entry, got 0")

        print("[Benchmark] TrigramIndex search >=3 scalars '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    /// Measure trigram search with a short query (< 3 scalars), which falls back
    /// to a linear scan of all stored names.
    @Test("TrigramIndex search (<3 scalars) — linear scan fallback")
    func trigramIndexSearchShortQuery() {
        let count = 10_000
        var index = TrigramIndex()
        for i in 0..<count {
            index.insert(name: Self.makeLongFileName(i), id: UInt32(i))
        }

        // A 2-character query triggers the linear-scan fallback
        let query = "lo"

        // Warm-up
        _ = index.search(substring: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = clock.measure {
            let ids = index.search(substring: query)
            resultCount = ids.count
        }

        #expect(resultCount > 0,
                "Short query 'lo' should match at least one entry, got 0")

        print("[Benchmark] TrigramIndex search <3 scalars '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    // MARK: - 4. InMemoryIndex Benchmarks

    /// Measure insertion of 10K FileRecords into the composite InMemoryIndex,
    /// which fans out to Trie, FullSubstringMap, TrigramIndex, and PinyinIndex.
    @Test("InMemoryIndex insert 10K FileRecords")
    func inMemoryIndexInsert10K() async {
        let count = 10_000
        let records = (0..<count).map { Self.makeRecord($0) }

        let index = await InMemoryIndex()
        let clock = ContinuousClock()
        let duration = await clock.measure {
            for record in records {
                await index.insert(record)
            }
        }

        let indexedCount = await index.count
        #expect(indexedCount == count,
                "InMemoryIndex should contain all \(count) records, got \(indexedCount)")

        print("[Benchmark] InMemoryIndex insert 10K: \(Self.formatSeconds(duration))")
    }

    /// Measure prefix search through the full InMemoryIndex pipeline.
    /// The query is a prefix of every generated filename, so all sub-indices
    /// (Trie, FullSubstringMap, TrigramIndex) contribute results.
    @Test("InMemoryIndex prefix search")
    func inMemoryIndexPrefixSearch() async {
        let count = 10_000
        let index = await InMemoryIndex()
        for i in 0..<count {
            await index.insert(Self.makeRecord(i))
        }

        // Warm-up
        _ = await index.search(query: "file")

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = await clock.measure {
            let results = await index.search(query: "file")
            resultCount = results.count
        }

        #expect(resultCount == count,
                "Prefix 'file' should match all \(count) records, got \(resultCount)")

        print("[Benchmark] InMemoryIndex prefix search 'file' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    /// Measure substring search where the query matches a fragment that appears
    /// in a subset of filenames.
    @Test("InMemoryIndex substring search")
    func inMemoryIndexSubstringSearch() async {
        let count = 10_000
        let index = await InMemoryIndex()
        for i in 0..<count {
            await index.insert(Self.makeRecord(i))
        }

        let query = "report"

        // Warm-up
        _ = await index.search(query: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = await clock.measure {
            let results = await index.search(query: query)
            resultCount = results.count
        }

        // "report" fragment appears in ~500 files (every 20th file)
        #expect(resultCount > 0,
                "Substring 'report' should match at least one entry, got 0")

        print("[Benchmark] InMemoryIndex substring '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    /// Measure mixed search patterns: prefix, substring, and extension-like
    /// queries. Verifies that all patterns return correct results and that
    /// the index handles diverse query types efficiently.
    @Test("InMemoryIndex mixed search patterns")
    func inMemoryIndexMixedSearch() async {
        let count = 10_000
        let index = await InMemoryIndex()
        for i in 0..<count {
            await index.insert(Self.makeRecord(i))
        }

        let queries = [
            ("file_5", "specific prefix"),       // prefix match
            ("doc", "common substring"),          // substring match
            (".pdf", "extension-like substring"), // extension substring
            ("presentation", "medium substring"), // another fragment
            ("zzz_nonexistent", "no-match"),      // should be empty
        ]

        var totalResults = 0
        let clock = ContinuousClock()
        let duration = await clock.measure {
            for (query, _) in queries {
                let results = await index.search(query: query)
                totalResults += results.count
            }
        }

        // At least some queries should produce results
        #expect(totalResults > 0,
                "At least some mixed queries should produce results, got 0 total")

        // Verify no-match query returns empty
        let noMatchResults = await index.search(query: "zzz_nonexistent")
        #expect(noMatchResults.isEmpty,
                "No-match query should return empty, got \(noMatchResults.count)")

        print("[Benchmark] InMemoryIndex mixed search \(queries.count) patterns (\(totalResults) total results): \(Self.formatSeconds(duration))")
    }

    // MARK: - 5. PinyinIndex Benchmarks

    /// Measure insertion of 1K Chinese filenames into the PinyinIndex.
    /// Each filename contains two Chinese tokens, producing both full-pinyin
    /// and first-letter abbreviation entries.
    @Test("PinyinIndex insert 1K Chinese filenames")
    func pinyinIndexInsert1K() {
        var index = PinyinIndex()

        // Generate 10 * 10 * 10 = 1000 unique Chinese filenames
        let prefixes = Self.chineseWords
        let suffixes = Self.chineseWords
        let chineseExts = ["pdf", "docx", "xlsx", "txt", "jpg", "png", "mp4", "swift", "json", "xml"]

        var entries: [(name: String, id: UInt32)] = []
        var id: UInt32 = 1
        for prefix in prefixes {
            for suffix in suffixes {
                for ext in chineseExts {
                    entries.append(("\(prefix)\(suffix).\(ext)", id))
                    id += 1
                }
            }
        }

        let clock = ContinuousClock()
        let duration = clock.measure {
            for (name, fid) in entries {
                index.insert(name: name, id: fid)
            }
        }

        // All filenames contain Chinese characters, so all should be indexed
        #expect(index.count == entries.count,
                "PinyinIndex should contain all \(entries.count) entries, got \(index.count)")

        print("[Benchmark] PinyinIndex insert 1K: \(Self.formatSeconds(duration))")
    }

    /// Measure full-pinyin search. The full pinyin of a Chinese token
    /// (e.g., "报告" → "baogao") is prefix-matched against the full-pinyin Trie.
    @Test("PinyinIndex full pinyin search")
    func pinyinIndexFullPinyinSearch() {
        var index = PinyinIndex()
        let prefixes = Self.chineseWords
        let suffixes = Self.chineseWords
        let chineseExts = ["pdf", "docx", "xlsx", "txt", "jpg", "png", "mp4", "swift", "json", "xml"]

        var id: UInt32 = 1
        for prefix in prefixes {
            for suffix in suffixes {
                for ext in chineseExts {
                    index.insert(name: "\(prefix)\(suffix).\(ext)", id: id)
                    id += 1
                }
            }
        }

        // Search for a known full pinyin prefix.   报告 → "baogao"
        let query = "baogao"

        // Warm-up
        _ = index.search(pinyin: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = clock.measure {
            let ids = index.search(pinyin: query)
            resultCount = ids.count
        }

        // 报告 appears as prefix in 100 filenames
        #expect(resultCount > 0,
                "Full pinyin '\(query)' should match at least one entry, got 0")

        print("[Benchmark] PinyinIndex full pinyin '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }

    /// Measure first-letter abbreviation search. First letters are concatenated
    /// across all tokens in a filename (e.g., 报告文件.pdf → "bgwj").
    @Test("PinyinIndex first-letter abbreviation search")
    func pinyinIndexFirstLetterSearch() {
        var index = PinyinIndex()
        let prefixes = Self.chineseWords
        let suffixes = Self.chineseWords
        let chineseExts = ["pdf", "docx", "xlsx", "txt", "jpg", "png", "mp4", "swift", "json", "xml"]

        var id: UInt32 = 1
        for prefix in prefixes {
            for suffix in suffixes {
                for ext in chineseExts {
                    index.insert(name: "\(prefix)\(suffix).\(ext)", id: id)
                    id += 1
                }
            }
        }

        // Search using first letters of a known token. 报告 → "b", "g" → "bg"
        let query = "bg"

        // Warm-up
        _ = index.search(pinyin: query)

        let clock = ContinuousClock()
        var resultCount = 0
        let duration = clock.measure {
            let ids = index.search(pinyin: query)
            resultCount = ids.count
        }

        #expect(resultCount > 0,
                "First-letter '\(query)' should match at least one entry, got 0")

        print("[Benchmark] PinyinIndex abbreviation '\(query)' (\(resultCount) results): \(Self.formatSeconds(duration))")
    }
}
