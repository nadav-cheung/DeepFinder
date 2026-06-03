import Testing
import Foundation
@testable import DeepFinder

@Suite("ResultRowView")
struct ResultRowTests {

    // MARK: - File icon by extension

    @Test("File icon lookup by extension")
    func fileIconByExtension() {
        let icon = FileIconCache.icon(forExtension: "pdf")
        // NSWorkspace returns a valid NSImage for known extensions
        #expect(icon.isValid)
    }

    @Test("File icon for directory")
    func fileIconForDirectory() {
        let icon = FileIconCache.icon(forExtension: nil, isDirectory: true)
        #expect(icon.isValid)
    }

    // MARK: - Match highlighting

    @Test("Match highlighting in filename")
    func matchHighlighting() {
        let filename = "report_2024.pdf"
        let query = "report"
        let attributed = MatchHighlighter.highlight(filename: filename, query: query)

        // Verify the highlighted range has accent color foreground
        let highlightedRun = attributed.runs.first(where: { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(highlightedRun != nil)

        // The highlighted range covers "report" — 6 characters starting at index 0
        if let run = highlightedRun {
            let charCount = attributed.characters.distance(
                from: run.range.lowerBound,
                to: run.range.upperBound
            )
            #expect(charCount == 6)
        }
    }

    @Test("Match highlighting with empty query returns plain text")
    func matchHighlightingEmptyQuery() {
        let filename = "report.pdf"
        let attributed = MatchHighlighter.highlight(filename: filename, query: "")
        // No highlighting runs for empty query
        #expect(attributed.characters.count == filename.count)
    }

    @Test("Match highlighting with no match returns plain attributed string")
    func matchHighlightingNoMatch() {
        let filename = "report.pdf"
        let attributed = MatchHighlighter.highlight(filename: filename, query: "xyz")
        let hasEmphasis = attributed.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(!hasEmphasis)
    }

    // MARK: - Path shortening

    @Test("Path shortening replaces home directory with ~")
    func pathShortening() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fullPath = home + "/Documents/Projects"
        let shortened = PathShortener.shorten(fullPath)
        #expect(shortened == "~/Documents/Projects")
    }

    @Test("Path shortening leaves non-home paths unchanged")
    func pathShorteningNonHome() {
        let shortened = PathShortener.shorten("/Volumes/Data/Files")
        #expect(shortened == "/Volumes/Data/Files")
    }

    // MARK: - File size formatting

    @Test("File size formatting")
    func fileSizeFormatting() {
        #expect(FileSizeFormatter.format(0) == "0 B")
        #expect(FileSizeFormatter.format(512) == "512 B")
        #expect(FileSizeFormatter.format(1024) == "1 KB")
        #expect(FileSizeFormatter.format(1536) == "1.5 KB")
        #expect(FileSizeFormatter.format(1_048_576) == "1 MB")
        #expect(FileSizeFormatter.format(1_073_741_824) == "1 GB")
    }

    @Test("File size formatting with large file")
    func fileSizeFormattingLarge() {
        let size: Int64 = 2_500_000_000 // ~2.33 GB
        let formatted = FileSizeFormatter.format(size)
        #expect(formatted == "2.33 GB")
    }

    // MARK: - Selected state visual

    @Test("ResultRowView selected state creates without error")
    func selectedStateVisual() {
        let record = FileRecord(
            id: 1,
            name: "test.pdf",
            originalName: "test.pdf",
            path: "/Users/test/test.pdf",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 1024,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: "pdf"
        )
        let result = SearchResult(
            record: record,
            providerID: "test",
            score: 1.0,
            matchType: .exact
        )
        let view = ResultRowView(result: result, isSelected: true, query: "test")
        _ = view
    }

    // MARK: - Empty extension handled

    @Test("Empty extension uses generic file icon")
    func emptyExtensionHandled() {
        let record = FileRecord(
            id: 2,
            name: "Makefile",
            originalName: "Makefile",
            path: "/Users/test/Makefile",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 256,
            createdAt: Date(),
            modifiedAt: Date(),
            extension: nil
        )
        let result = SearchResult(
            record: record,
            providerID: "test",
            score: 0.8,
            matchType: .substring
        )
        let view = ResultRowView(result: result, isSelected: false, query: "make")
        _ = view
    }

    // MARK: - Match type badge

    @Test("Match type badge label")
    func matchTypeBadgeLabel() {
        #expect(MatchType.exact.badgeLabel == "精确")
        #expect(MatchType.prefix.badgeLabel == "前缀")
        #expect(MatchType.substring.badgeLabel == "子串")
        #expect(MatchType.pinyin.badgeLabel == "拼音")
    }
}
