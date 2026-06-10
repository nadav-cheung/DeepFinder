import Foundation
import Testing
@testable import DeepFinderServices

@Suite("URLSchemeHandler")
struct URLSchemeHandlerTests {

    // MARK: - Valid search URLs

    @Test("parse deepfinder://search?q=test returns .search(query:limit:filter:)")
    func parseSimpleSearchURL() {
        let url = URL(string: "deepfinder://search?q=test")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: nil))
    }

    @Test("parse deepfinder://search?q=hello%20world&limit=20 returns decoded query and limit")
    func parseSearchURLWithLimit() {
        let url = URL(string: "deepfinder://search?q=hello%20world&limit=20")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "hello world", limit: 20, filter: nil))
    }

    @Test("parse deepfinder://search?q=test&filter=ext:pdf returns search with filter")
    func parseSearchURLWithFilter() {
        let url = URL(string: "deepfinder://search?q=test&filter=ext:pdf")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: "ext:pdf"))
    }

    @Test("parse deepfinder://search?q=report&limit=50&filter=size>1MB returns all params")
    func parseSearchURLWithAllParams() {
        let url = URL(string: "deepfinder://search?q=report&limit=50&filter=size%3E1MB")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "report", limit: 50, filter: "size>1MB"))
    }

    @Test("limit=0 is treated as nil (no limit)")
    func limitZeroTreatedAsNil() {
        let url = URL(string: "deepfinder://search?q=test&limit=0")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: nil))
    }

    @Test("negative limit is treated as nil")
    func negativeLimitTreatedAsNil() {
        let url = URL(string: "deepfinder://search?q=test&limit=-5")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: nil))
    }

    @Test("non-numeric limit is treated as nil")
    func nonNumericLimitTreatedAsNil() {
        let url = URL(string: "deepfinder://search?q=test&limit=abc")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: nil))
    }

    @Test("empty filter is treated as nil")
    func emptyFilterTreatedAsNil() {
        let url = URL(string: "deepfinder://search?q=test&filter=")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "test", limit: nil, filter: nil))
    }

    // MARK: - Invalid URLs

    @Test("parse deepfinder://invalid returns nil (unknown host)")
    func parseInvalidHostReturnsNil() {
        let url = URL(string: "deepfinder://invalid")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    @Test("parse bare path-only URL returns nil")
    func parseBareURLReturnsNil() {
        // URL(string: "") returns nil on Apple platforms, so test with a
        // valid but irrelevant URL instead.
        let url = URL(string: "/some/path")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    @Test("parse URL without query parameter returns nil")
    func parseSearchURLWithoutQueryReturnsNil() {
        let url = URL(string: "deepfinder://search")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    @Test("parse URL with wrong scheme returns nil")
    func parseWrongSchemeReturnsNil() {
        let url = URL(string: "https://search?q=test")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    @Test("parse search URL with empty q parameter returns nil")
    func parseSearchURLEmptyQReturnsNil() {
        let url = URL(string: "deepfinder://search?q=")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    @Test("parse URL with only limit and no q returns nil")
    func parseSearchURLNoQOnlyLimitReturnsNil() {
        let url = URL(string: "deepfinder://search?limit=20")!
        let result = SearchURL.parse(url)
        #expect(result == nil)
    }

    // MARK: - Unicode

    @Test("parse URL with CJK query decodes correctly")
    func parseCJKQuery() {
        let url = URL(string: "deepfinder://search?q=%E6%8A%A5%E5%91%8A")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "报告", limit: nil, filter: nil))
    }

    @Test("parse URL with encoded special characters")
    func parseEncodedSpecialCharacters() {
        let url = URL(string: "deepfinder://search?q=file%20name%26test")!
        let result = SearchURL.parse(url)
        #expect(result == .search(query: "file name&test", limit: nil, filter: nil))
    }
}
