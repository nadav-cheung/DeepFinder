import Testing
@testable import DeepFinderGUILib

@Suite("FilterType")
struct FilterTypeTests {

    // MARK: - Filter Syntax

    @Test("Documents filter syntax contains expected extensions")
    func testDocumentsFilterSyntax() {
        let syntax = FilterType.documents.filterSyntax()
        #expect(syntax.contains("pdf"))
        #expect(syntax.contains("doc"))
        #expect(syntax.contains("txt"))
        #expect(syntax.hasPrefix("ext:"))
    }

    @Test("Directories filter uses type:dir syntax")
    func testDirectoriesFilterSyntax() {
        let syntax = FilterType.directories.filterSyntax()
        #expect(syntax == "type:dir")
    }

    @Test("All filter types produce non-empty syntax")
    func testAllFilterSyntaxNonEmpty() {
        for filterType in FilterType.allCases {
            #expect(!filterType.filterSyntax().isEmpty, "\(filterType.rawValue) has empty filter syntax")
        }
    }

    // MARK: - Display Properties

    @Test("All filter types have Chinese labels")
    func testChineseLabels() {
        #expect(FilterType.documents.label == "文档")
        #expect(FilterType.images.label == "图片")
        #expect(FilterType.code.label == "代码")
        #expect(FilterType.video.label == "视频")
        #expect(FilterType.audio.label == "音频")
        #expect(FilterType.directories.label == "目录")
    }

    @Test("All filter types have non-empty system images")
    func testSystemImages() {
        for filterType in FilterType.allCases {
            #expect(!filterType.systemImage.isEmpty, "\(filterType.rawValue) has empty system image")
        }
    }

    @Test("FilterType has exactly 6 cases")
    func testCaseCount() {
        #expect(FilterType.allCases.count == 6)
    }
}

@Suite("KeyboardHintBar")
struct KeyboardHintBarTests {

    @Test("Expected hint count is 6")
    func testExpectedHintCount() {
        #expect(KeyboardHintBar.expectedHintCount == 6)
    }
}
