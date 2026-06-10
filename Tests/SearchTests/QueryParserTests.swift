import Testing
import Foundation

@testable import DeepFinderSearch

// MARK: - QueryParser Tests

@Suite("QueryParser")
struct QueryParserTests {

    // MARK: - Plain Text

    @Test("Plain text query produces single .text term")
    func testPlainTextQuery() {
        let result = QueryParser.parse("hello")
        #expect(result.terms == [.text("hello")])
    }

    @Test("Empty query produces empty terms")
    func testEmptyQuery() {
        let result = QueryParser.parse("")
        #expect(result.terms.isEmpty)
    }

    @Test("Single word produces single .text term")
    func testSingleWord() {
        let result = QueryParser.parse("report")
        #expect(result.terms == [.text("report")])
    }

    // MARK: - AND (space-separated)

    @Test("Multiple space-separated words produce .and")
    func testMultipleWordsAnd() {
        let result = QueryParser.parse("annual report")
        #expect(result.terms == [.and([.text("annual"), .text("report")])])
    }

    // MARK: - OR (|)

    @Test("OR operator produces .or")
    func testOrOperator() {
        let result = QueryParser.parse("report | summary")
        #expect(result.terms == [.or([.text("report"), .text("summary")])])
    }

    // MARK: - NOT (!)

    @Test("NOT operator produces .not")
    func testNotOperator() {
        let result = QueryParser.parse("!secret")
        #expect(result.terms == [.not(.text("secret"))])
    }

    // MARK: - Combined: OR + NOT

    @Test("Combined: report | summary !draft produces or + not")
    func testCombinedOrNot() {
        let result = QueryParser.parse("report | summary !draft")
        #expect(result.terms == [.and([
            .or([.text("report"), .text("summary")]),
            .not(.text("draft"))
        ])])
    }

    // MARK: - Wildcards

    @Test("Wildcard *.pdf produces .wildcard")
    func testWildcardStar() {
        let result = QueryParser.parse("*.pdf")
        #expect(result.terms == [.wildcard("*.pdf")])
    }

    @Test("Wildcard report_??.xlsx produces .wildcard")
    func testWildcardQuestion() {
        let result = QueryParser.parse("report_??.xlsx")
        #expect(result.terms == [.wildcard("report_??.xlsx")])
    }

    // MARK: - Regex

    @Test("regex: prefix produces .regex term")
    func testRegexPrefix() {
        let result = QueryParser.parse("regex:^report_\\d{4}")
        #expect(result.terms == [.regex("^report_\\d{4}")])
    }

    // MARK: - Modifiers

    @Test("Modifier ext:pdf produces .modifier")
    func testModifier() {
        let result = QueryParser.parse("ext:pdf")
        #expect(result.terms == [.modifier(key: "ext", value: "pdf")])
    }

    @Test("Modifier case:yes with text produces modifier + text")
    func testModifierWithText() {
        let result = QueryParser.parse("case:yes report")
        #expect(result.terms == [.and([
            .modifier(key: "case", value: "yes"),
            .text("report")
        ])])
    }

    // MARK: - Path Qualifier

    @Test("Path qualifier backslash-separated produces .pathQualifier + text")
    func testPathQualifier() {
        let result = QueryParser.parse("Documents\\ report")
        #expect(result.terms == [.and([
            .pathQualifier("Documents"),
            .text("report")
        ])])
    }

    // MARK: - Parentheses for grouping

    @Test("Parentheses group sub-expressions")
    func testParenthesesGrouping() {
        let result = QueryParser.parse("(a | b) c")
        #expect(result.terms == [.and([
            .or([.text("a"), .text("b")]),
            .text("c")
        ])])
    }

    // MARK: - Escaped pipe

    @Test("Escaped pipe produces literal text")
    func testEscapedPipe() {
        let result = QueryParser.parse("a\\|b")
        #expect(result.terms == [.text("a|b")])
    }
}
