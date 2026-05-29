import Foundation
import Testing

@testable import DeepFinder

@Suite("PatternMatcher")
struct PatternMatcherTests {

    // MARK: - Wildcard: basic glob patterns

    @Test("Wildcard '*.pdf' matches 'report.pdf'")
    func testWildcardPdfMatches() {
        #expect(PatternMatcher.matchWildcard(pattern: "*.pdf", input: "report.pdf"))
    }

    @Test("Wildcard '*.pdf' does not match 'report.doc'")
    func testWildcardPdfNoMatch() {
        #expect(!PatternMatcher.matchWildcard(pattern: "*.pdf", input: "report.doc"))
    }

    @Test("Wildcard 'report_??.xlsx' matches 'report_01.xlsx'")
    func testWildcardQuestionMarkMatches() {
        #expect(PatternMatcher.matchWildcard(pattern: "report_??.xlsx", input: "report_01.xlsx"))
    }

    @Test("'??' matches 'ab' but not 'abc'")
    func testWildcardTwoQuestionMarks() {
        #expect(PatternMatcher.matchWildcard(pattern: "??", input: "ab"))
        #expect(!PatternMatcher.matchWildcard(pattern: "??", input: "abc"))
    }

    @Test("'*' matches everything including empty string")
    func testWildcardStarMatchesAll() {
        #expect(PatternMatcher.matchWildcard(pattern: "*", input: ""))
        #expect(PatternMatcher.matchWildcard(pattern: "*", input: "anything"))
        #expect(PatternMatcher.matchWildcard(pattern: "*", input: "report_v2_final.pdf"))
    }

    @Test("Wildcard case insensitive: '*.PDF' matches 'report.pdf'")
    func testWildcardCaseInsensitive() {
        #expect(PatternMatcher.matchWildcard(pattern: "*.PDF", input: "report.pdf"))
    }

    @Test("Wildcard in middle: 'report*final.pdf' matches 'report_v2_final.pdf'")
    func testWildcardMiddleMatches() {
        #expect(PatternMatcher.matchWildcard(pattern: "report*final.pdf", input: "report_v2_final.pdf"))
    }

    @Test("Multiple wildcards: '*_report_*' matches '2024_report_q4'")
    func testMultipleWildcards() {
        #expect(PatternMatcher.matchWildcard(pattern: "*_report_*", input: "2024_report_q4"))
    }

    // MARK: - Regex

    @Test("Regex '^report_\\d{4}' matches 'report_2024'")
    func testRegexDigitPattern() {
        #expect(PatternMatcher.matchRegex(pattern: "^report_\\d{4}", input: "report_2024"))
    }

    @Test("Regex '\\.(pdf|doc)$' matches both 'report.pdf' and 'report.doc'")
    func testRegexAlternation() {
        #expect(PatternMatcher.matchRegex(pattern: "\\.(pdf|doc)$", input: "report.pdf"))
        #expect(PatternMatcher.matchRegex(pattern: "\\.(pdf|doc)$", input: "report.doc"))
        #expect(!PatternMatcher.matchRegex(pattern: "\\.(pdf|doc)$", input: "report.xlsx"))
    }

    @Test("Regex is case insensitive by default")
    func testRegexCaseInsensitive() {
        #expect(PatternMatcher.matchRegex(pattern: "^REPORT", input: "report_2024"))
        #expect(PatternMatcher.matchRegex(pattern: "\\.PDF$", input: "document.pdf"))
    }

    @Test("Invalid regex returns false without crashing")
    func testInvalidRegexReturnsFalse() {
        #expect(!PatternMatcher.matchRegex(pattern: "([unclosed", input: "anything"))
        #expect(!PatternMatcher.matchRegex(pattern: "*", input: "anything"))
    }
}
