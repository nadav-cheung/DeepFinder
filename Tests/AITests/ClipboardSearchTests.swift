// Tests/AITests/ClipboardSearchTests.swift
import Testing
import AppKit
@testable import DeepFinder

@Suite("ClipboardSearch")
struct ClipboardSearchTests {

    // MARK: - ClipboardContent

    @Test("ClipboardContent holds text and preview")
    func clipboardContentProperties() {
        let content = ClipboardContent(text: "hello world", preview: "hello world")
        #expect(content.text == "hello world")
        #expect(content.preview == "hello world")
    }

    @Test("ClipboardContent is Equatable")
    func clipboardContentEquatable() {
        let a = ClipboardContent(text: "abc", preview: "abc")
        let b = ClipboardContent(text: "abc", preview: "abc")
        let c = ClipboardContent(text: "xyz", preview: "xyz")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - truncateToPreview

    @Test("truncateToPreview keeps short text unchanged")
    func truncateKeepsShortText() {
        let short = "hello"
        #expect(ClipboardSearch.truncateToPreview(short) == "hello")
    }

    @Test("truncateToPreview truncates at 100 chars with ellipsis")
    func truncateLongText() {
        let long = String(repeating: "a", count: 150)
        let result = ClipboardSearch.truncateToPreview(long)
        #expect(result.count == 103) // 100 chars + "..."
        #expect(result.hasSuffix("..."))
        #expect(result.dropLast(3) == String(repeating: "a", count: 100))
    }

    @Test("truncateToPreview keeps text at exactly maxLength unchanged")
    func truncateExactLength() {
        let exact = String(repeating: "b", count: 100)
        #expect(ClipboardSearch.truncateToPreview(exact) == exact)
    }

    @Test("truncateToPreview with custom maxLength")
    func truncateCustomMaxLength() {
        let text = "abcdefghij"
        #expect(ClipboardSearch.truncateToPreview(text, maxLength: 5) == "abcde...")
        #expect(ClipboardSearch.truncateToPreview(text, maxLength: 10) == "abcdefghij")
    }

    // MARK: - detectClipboardText
    //
    // Tests use a private named pasteboard to avoid interfering with the
    // system pasteboard and to prevent test-to-test clobbering from
    // parallel execution.

    /// Creates a fresh named pasteboard for each test.
    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("DeepFinder-Test-\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    @Test("detectClipboardText returns nil when pasteboard has no text")
    func detectReturnsNilForNoText() {
        let pasteboard = makePasteboard()
        // Fresh pasteboard, no content set -> should return nil
        let result = ClipboardSearch.detectClipboardText(pasteboard: pasteboard)
        #expect(result == nil)
    }

    @Test("detectClipboardText returns content for text in pasteboard")
    func detectReturnsText() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("test clipboard content", forType: .string)

        let result = ClipboardSearch.detectClipboardText(pasteboard: pasteboard)
        #expect(result != nil)
        #expect(result?.text == "test clipboard content")
        #expect(result?.preview == "test clipboard content")
    }

    @Test("detectClipboardText truncates long text in preview")
    func detectTruncatesLongText() {
        let longText = String(repeating: "x", count: 200)
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString(longText, forType: .string)

        let result = ClipboardSearch.detectClipboardText(pasteboard: pasteboard)
        #expect(result != nil)
        #expect(result?.text == longText)
        #expect(result?.preview.count == 103) // 100 + "..."
        #expect(result?.preview.hasSuffix("...") == true)
    }

    @Test("detectClipboardText ignores file URLs (returns nil for URL-only content)")
    func detectIgnoresFileURLs() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        // Set only a URL, no plain text string
        let url = NSURL.fileURL(withPath: "/tmp/test.txt")
        pasteboard.setData(url.dataRepresentation, forType: .fileURL)
        // Do NOT set .string type -- should not find text

        let result = ClipboardSearch.detectClipboardText(pasteboard: pasteboard)
        // Without .string type set, should return nil
        #expect(result == nil)
    }

    @Test("detectClipboardText ignores empty strings")
    func detectIgnoresEmptyString() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)

        let result = ClipboardSearch.detectClipboardText(pasteboard: pasteboard)
        #expect(result == nil)
    }
}
