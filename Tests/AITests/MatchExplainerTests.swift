import Testing
import Foundation
@testable import DeepFinder

@Suite("MatchExplainer")
struct MatchExplainerTests {

    private func makeRecord(name: String, originalName: String) -> FileRecord {
        FileRecord(
            id: 1,
            name: name,
            originalName: originalName,
            path: "/test/\(name)",
            parentPath: "/test",
            isDirectory: false,
            size: 1024,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: name.split(separator: ".").last.map(String.init)
        )
    }

    private func makeResult(
        name: String,
        matchType: MatchType
    ) -> SearchResult {
        SearchResult(
            record: makeRecord(name: name, originalName: name),
            providerID: "test",
            score: 1.0,
            matchType: matchType
        )
    }

    // MARK: - Exact match

    @Test("explain with exact match returns exact match reason")
    func explainExactMatch() {
        let result = makeResult(name: "report.pdf", matchType: .exact)
        let explanation = MatchExplainer.explain(result: result, query: "report.pdf", filters: [])

        #expect(explanation.matchType == "exact")
        #expect(explanation.reason.contains("Exact match"))
    }

    // MARK: - Prefix match

    @Test("explain with prefix match returns prefix reason")
    func explainPrefixMatch() {
        let result = makeResult(name: "report_q1.pdf", matchType: .prefix)
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: [])

        #expect(explanation.matchType == "prefix")
        #expect(explanation.reason.contains("Prefix match"))
    }

    // MARK: - Substring match

    @Test("explain with substring match returns substring reason")
    func explainSubstringMatch() {
        let result = makeResult(name: "quarterly_report_final.pdf", matchType: .substring)
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: [])

        #expect(explanation.matchType == "substring")
        #expect(explanation.reason.contains("Substring match"))
    }

    // MARK: - Pinyin match

    @Test("explain with pinyin match returns pinyin reason")
    func explainPinyinMatch() {
        let result = makeResult(name: "设计稿_v3.fig", matchType: .pinyin)
        let explanation = MatchExplainer.explain(result: result, query: "sheji", filters: [])

        #expect(explanation.matchType == "pinyin")
        #expect(explanation.reason.contains("Pinyin match"))
    }

    // MARK: - Metadata filter noted in reason

    @Test("explain with metadata filter includes filter in reason")
    func explainWithMetadataFilter() {
        let result = makeResult(name: "report.pdf", matchType: .substring)
        let filters: [SearchFilter] = [
            .sizeMin(1_048_576),
            .extensionFilter(["pdf"])
        ]
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: filters)

        #expect(explanation.matchType == "substring")
        #expect(explanation.reason.contains("filter"))
    }

    // MARK: - Match position included

    @Test("explain includes match position for substring")
    func explainIncludesMatchPosition() {
        let result = makeResult(name: "quarterly_report_final.pdf", matchType: .substring)
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: [])

        #expect(explanation.position != nil)
        // "report" starts at index 10 in "quarterly_report_final.pdf"
        #expect(explanation.position == "10")
    }

    @Test("explain includes match position for prefix")
    func explainPrefixMatchPosition() {
        let result = makeResult(name: "report_q1.pdf", matchType: .prefix)
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: [])

        #expect(explanation.position != nil)
        // "report" starts at index 0 in "report_q1.pdf"
        #expect(explanation.position == "0")
    }

    @Test("explain includes match position for exact")
    func explainExactMatchPosition() {
        let result = makeResult(name: "report.pdf", matchType: .exact)
        let explanation = MatchExplainer.explain(result: result, query: "report.pdf", filters: [])

        #expect(explanation.position != nil)
        #expect(explanation.position == "0")
    }

    // MARK: - No filters

    @Test("explain without filters does not mention filters")
    func explainNoFilters() {
        let result = makeResult(name: "report.pdf", matchType: .substring)
        let explanation = MatchExplainer.explain(result: result, query: "report", filters: [])

        #expect(explanation.matchType == "substring")
        #expect(!explanation.reason.contains("filter"))
    }
}
