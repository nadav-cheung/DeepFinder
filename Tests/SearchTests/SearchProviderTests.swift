import Testing
import DeepFinderAI
import DeepFinderPersist
import DeepFinderIndex
@testable import DeepFinderSearch

@Suite("SearchProvider / FileIndexProvider")
struct SearchProviderTests {

    // MARK: - Helpers

    /// Build an InMemoryIndex pre-loaded with fixture data.
    private func makeIndex() async -> InMemoryIndex {
        let index = InMemoryIndex()
        await index.insert(name: "report.pdf", path: "/docs/report.pdf", parentPath: "/docs")
        await index.insert(name: "Report-2024.xlsx", path: "/docs/Report-2024.xlsx", parentPath: "/docs")
        await index.insert(name: "quarterly-report.txt", path: "/docs/quarterly-report.txt", parentPath: "/docs")
        await index.insert(name: "photo.jpg", path: "/pics/photo.jpg", parentPath: "/pics")
        await index.insert(name: "notes.md", path: "/notes.md", parentPath: "/")
        return index
    }

    /// Collect all results from a SearchResultSequence into an array.
    private func collect(_ sequence: SearchResultSequence) async -> [SearchResult] {
        var results: [SearchResult] = []
        for await element in sequence {
            results.append(element)
        }
        return results
    }

    // MARK: - Protocol conformance

    @Test("FileIndexProvider conforms to SearchProvider protocol")
    func testFileIndexProviderConformsToProtocol() async {
        let index = InMemoryIndex()
        let provider: any SearchProvider = FileIndexProvider(index: index)
        #expect(provider.providerID == "file-index")
    }

    // MARK: - Match types and scoring

    @Test("Exact match returns highest score")
    func testExactMatchReturnsHighestScore() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("report.pdf")
        let results = await collect(await provider.search(query: query))

        let exact = results.first { $0.record.name == "report.pdf" }
        #expect(exact != nil)
        #expect(exact!.matchType == .exact)
        #expect(exact!.score == 1.0)
    }

    @Test("Prefix match returns mid score")
    func testPrefixMatchReturnsMidScore() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("report")
        let results = await collect(await provider.search(query: query))

        // "report.pdf" has normalized name "report.pdf", which starts with "report"
        let reportPdf = results.first { $0.record.name == "report.pdf" }
        #expect(reportPdf != nil)
        #expect(reportPdf!.matchType == .prefix)
        #expect(reportPdf!.score == 0.8)
    }

    @Test("Substring match returns lowest score")
    func testSubstringMatchReturnsLowestScore() async {
        let provider = FileIndexProvider(index: await makeIndex())
        // "report" appears in the middle of "quarterly-report.txt"
        let query = SearchQuery("report")
        let results = await collect(await provider.search(query: query))

        let quarterly = results.first { $0.record.name == "quarterly-report.txt" }
        #expect(quarterly != nil)
        #expect(quarterly!.matchType == .substring)
        #expect(quarterly!.score == 0.5)
    }

    // MARK: - AsyncSequence behavior

    @Test("Search returns AsyncSequence")
    func testSearchReturnsAsyncSequence() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("report")
        // SearchResultSequence conforms to AsyncSequence
        let sequence: SearchResultSequence = await provider.search(query: query)
        var count = 0
        for await _ in sequence { count += 1 }
        #expect(count > 0)
    }

    // MARK: - Edge cases

    @Test("Cancel does not crash")
    func testCancelDoesNotCrash() async {
        let provider = FileIndexProvider(index: InMemoryIndex())
        await provider.cancel(queryID: "any-id")
    }

    @Test("Prepare does not crash")
    func testPrepareDoesNotCrash() async {
        let provider = FileIndexProvider(index: InMemoryIndex())
        await provider.prepare()
    }

    @Test("Empty query returns empty results")
    func testEmptyQueryReturnsEmpty() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("")
        let results = await collect(await provider.search(query: query))
        #expect(results.isEmpty)
    }

    // MARK: - Case insensitivity

    @Test("Search is case insensitive")
    func testSearchCaseInsensitive() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("REPORT")
        let results = await collect(await provider.search(query: query))

        let reportPdf = results.first { $0.record.name == "report.pdf" }
        #expect(reportPdf != nil)
    }

    // MARK: - Multiple results

    @Test("Search returns multiple results")
    func testSearchMultipleResults() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let query = SearchQuery("report")
        let results = await collect(await provider.search(query: query))

        // "report.pdf", "Report-2024.xlsx", "quarterly-report.txt" all contain "report"
        #expect(results.count >= 3)

        let names = results.map(\.record.name)
        #expect(names.contains("report.pdf"))
        #expect(names.contains("Report-2024.xlsx"))
        #expect(names.contains("quarterly-report.txt"))
    }

    // MARK: - Wildcard & regex queries (pattern scan)

    @Test("Wildcard *.ext matches by extension")
    func testWildcardExtension() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let results = await collect(await provider.search(query: SearchQuery("*.pdf")))
        let names = results.map(\.record.name)
        #expect(names.contains("report.pdf"))
        #expect(!names.contains("photo.jpg"))
        #expect(!names.contains("notes.md"))
    }

    @Test("Wildcard *term* matches names containing term")
    func testWildcardContains() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let results = await collect(await provider.search(query: SearchQuery("*report*")))
        let names = Set(results.map(\.record.name))
        // Case-insensitive: report.pdf, Report-2024.xlsx, quarterly-report.txt
        #expect(names.contains("report.pdf"))
        #expect(names.contains("Report-2024.xlsx"))
        #expect(names.contains("quarterly-report.txt"))
    }

    @Test("Wildcard prefix* matches names starting with prefix")
    func testWildcardPrefix() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let results = await collect(await provider.search(query: SearchQuery("report*")))
        let names = Set(results.map(\.record.name))
        #expect(names.contains("report.pdf"))           // starts with "report"
        #expect(names.contains("Report-2024.xlsx"))     // case-insensitive prefix
        #expect(!names.contains("quarterly-report.txt"))
    }

    @Test("regex: prefix matches via NSRegularExpression")
    func testRegexQuery() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let results = await collect(await provider.search(query: SearchQuery("regex:^report")))
        let names = Set(results.map(\.record.name))
        #expect(names.contains("report.pdf"))
        #expect(names.contains("Report-2024.xlsx"))     // case-insensitive
        #expect(!names.contains("quarterly-report.txt"))
        #expect(!names.contains("photo.jpg"))
    }

    @Test("Plain query (no wildcard/regex) still uses the index path")
    func testPlainQueryUnaffected() async {
        let provider = FileIndexProvider(index: await makeIndex())
        let results = await collect(await provider.search(query: SearchQuery("report")))
        // Index path classifies exact/prefix/substring; wildcard path is not taken.
        #expect(!results.isEmpty)
    }
}
