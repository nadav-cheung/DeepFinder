import Testing
import Foundation
@testable import DeepFinder

@Suite("IPCProtocol Codable round-trip")
struct IPCProtocolTests {

    // MARK: - IPCRequest

    @Test("IPCRequest.query encodes and decodes without loss")
    func testRequestQueryRoundTrip() throws {
        let original = IPCRequest.query("hello world", limit: 50)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCRequest.query without limit encodes and decodes")
    func testRequestQueryNoLimit() throws {
        let original = IPCRequest.query("test", limit: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCRequest.cancel encodes and decodes")
    func testRequestCancelRoundTrip() throws {
        let original = IPCRequest.cancel(queryID: "abc-123")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCRequest.stats encodes and decodes")
    func testRequestStatsRoundTrip() throws {
        let original = IPCRequest.stats
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCRequest.configGet and configSet round-trip")
    func testRequestConfigRoundTrip() throws {
        let getOriginal = IPCRequest.configGet(key: "exclude_paths")
        let getData = try JSONEncoder().encode(getOriginal)
        let getDecoded = try JSONDecoder().decode(IPCRequest.self, from: getData)
        #expect(getDecoded == getOriginal)

        // configGet with nil key (get all config)
        let getAllOriginal = IPCRequest.configGet(key: nil)
        let getAllData = try JSONEncoder().encode(getAllOriginal)
        let getAllDecoded = try JSONDecoder().decode(IPCRequest.self, from: getAllData)
        #expect(getAllDecoded == getAllOriginal)

        let setOriginal = IPCRequest.configSet(key: "exclude_paths", value: "/tmp,/var")
        let setData = try JSONEncoder().encode(setOriginal)
        let setDecoded = try JSONDecoder().decode(IPCRequest.self, from: setData)
        #expect(setDecoded == setOriginal)
    }

    @Test("IPCRequest.indexStatus round-trip")
    func testRequestIndexStatusRoundTrip() throws {
        let original = IPCRequest.indexStatus
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - IPCResponse

    @Test("IPCResponse.results encodes and decodes with SearchResults")
    func testResponseResultsRoundTrip() throws {
        let record = FileRecord(
            id: 42,
            name: "test.txt",
            originalName: "Test.txt",
            path: "/Users/test/test.txt",
            parentPath: "/Users/test",
            isDirectory: false,
            size: 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
        let result = SearchResult(record: record, providerID: "file-index", score: 0.95, matchType: .exact)
        let original = IPCResponse.results([result], queryID: "q-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCResponse.error round-trip for all error cases")
    func testResponseErrorRoundTrip() throws {
        let errors: [IPCError] = [
            .daemonNotReady,
            .queryError("bad syntax"),
            .invalidRequest("missing field"),
            .permissionDenied("no access"),
            .incompatibleProtocolVersion,
        ]
        for err in errors {
            let original = IPCResponse.error(err)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test("IPCResponse.stats round-trip")
    func testResponseStatsRoundTrip() throws {
        let stats = DaemonStats(
            totalFiles: 123_456,
            indexState: "live",
            uptimeSeconds: 3600.5,
            memoryUsageMB: 256.7
        )
        let original = IPCResponse.stats(stats)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("IPCResponse.ack and .indexStatus round-trip")
    func testResponseAckAndIndexStatusRoundTrip() throws {
        let ackOriginal = IPCResponse.ack
        let ackData = try JSONEncoder().encode(ackOriginal)
        let ackDecoded = try JSONDecoder().decode(IPCResponse.self, from: ackData)
        #expect(ackDecoded == ackOriginal)

        let status = DaemonIndexStatus(
            state: "verifying",
            filesIndexed: 50_000,
            lastScanDate: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let statusOriginal = IPCResponse.indexStatus(status)
        let statusData = try JSONEncoder().encode(statusOriginal)
        let statusDecoded = try JSONDecoder().decode(IPCResponse.self, from: statusData)
        #expect(statusDecoded == statusOriginal)

        // indexStatus with nil lastScanDate
        let noScanStatus = DaemonIndexStatus(state: "starting", filesIndexed: 0, lastScanDate: nil)
        let noScanOriginal = IPCResponse.indexStatus(noScanStatus)
        let noScanData = try JSONEncoder().encode(noScanOriginal)
        let noScanDecoded = try JSONDecoder().decode(IPCResponse.self, from: noScanData)
        #expect(noScanDecoded == noScanOriginal)
    }

    // MARK: - IPCFraming

    @Test("Length prefix round-trip preserves data")
    func testLengthPrefixRoundTrip() throws {
        let payload = Data("hello ipc".utf8)
        let framed = IPCFraming.addLengthPrefix(to: payload)
        #expect(framed.count == 4 + payload.count)

        let stripped = try IPCFraming.stripLengthPrefix(from: framed)
        #expect(stripped == payload)
    }

    @Test("Length prefix rejects truncated data")
    func testLengthPrefixRejectsTruncated() {
        let payload = Data("hello".utf8)
        let framed = IPCFraming.addLengthPrefix(to: payload)

        // Only 3 bytes of header — not enough
        let truncated = framed.prefix(3)
        #expect(throws: IPCFramingError.self) {
            try IPCFraming.stripLengthPrefix(from: truncated)
        }
    }

    @Test("Length prefix rejects incomplete payload")
    func testLengthPrefixRejectsIncompletePayload() {
        let payload = Data("hello world".utf8)
        let framed = IPCFraming.addLengthPrefix(to: payload)

        // Header says 11 bytes, but we only give 4 + 5 bytes
        let incomplete = framed.prefix(4 + 5)
        #expect(throws: IPCFramingError.self) {
            try IPCFraming.stripLengthPrefix(from: incomplete)
        }
    }

    // MARK: - Protocol version

    // MARK: - Query length validation

    @Test("Query at exactly maxQueryLength decodes successfully")
    func testQueryAtMaxLengthDecodes() throws {
        let exactLengthQuery = String(repeating: "a", count: maxQueryLength)
        let original = IPCRequest.query(exactLengthQuery, limit: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("Query exceeding maxQueryLength is rejected on decode")
    func testOversizedQueryRejected() throws {
        let oversizedQuery = String(repeating: "x", count: maxQueryLength + 1)
        let request = IPCRequest.query(oversizedQuery, limit: nil)
        let data = try JSONEncoder().encode(request)

        do {
            _ = try JSONDecoder().decode(IPCRequest.self, from: data)
            Issue.record("Expected decode to throw for oversized query, but it succeeded")
        } catch let error as IPCError {
            if case .queryError(let msg) = error {
                #expect(msg.contains("too long") || msg.contains("max"))
            } else {
                Issue.record("Expected .queryError but got: \(error)")
            }
        } catch {
            Issue.record("Expected IPCError.queryError but got: \(error)")
        }
    }

    @Test("Very large query (100KB) is rejected on decode")
    func testVeryLargeQueryRejected() throws {
        let hugeQuery = String(repeating: "z", count: 100_000)
        let request = IPCRequest.query(hugeQuery, limit: nil)
        let data = try JSONEncoder().encode(request)

        #expect(throws: IPCError.self) {
            try JSONDecoder().decode(IPCRequest.self, from: data)
        }
    }

    // MARK: - Protocol version

    @Test("Encoded JSON includes ipcProtocolVersion field")
    func testProtocolVersionInJSON() throws {
        let request = IPCRequest.query("test", limit: nil)
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"ipcProtocolVersion\""))
        #expect(json.contains("1"))
    }

    // MARK: - IPCFraming convenience helpers

    @Test("IPCFraming.encode and decode convenience round-trip")
    func testFramingConvenienceRoundTrip() throws {
        let stats = DaemonStats(
            totalFiles: 999,
            indexState: "live",
            uptimeSeconds: 42.0,
            memoryUsageMB: 128.0
        )
        let response = IPCResponse.stats(stats)
        let framed = try IPCFraming.encode(response)
        let decoded = try IPCFraming.decode(IPCResponse.self, from: framed)
        #expect(decoded == response)
    }

    // MARK: - Duplicate IPC (REQ-1.5-06)

    @Test("IPCRequest.duplicateQuery round-trip for all strategies")
    func testRequestDuplicateQueryRoundTrip() throws {
        for strategy in DuplicateQueryStrategy.allCases {
            let original = IPCRequest.duplicateQuery(strategy: strategy)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test("IPCResponse.duplicates round-trip with groups")
    func testResponseDuplicatesRoundTrip() throws {
        let record1 = FileRecord(
            id: 1, name: "test.txt", originalName: "test.txt",
            path: "/a/test.txt", parentPath: "/a",
            isDirectory: false, size: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
        let record2 = FileRecord(
            id: 2, name: "test.txt", originalName: "test.txt",
            path: "/b/test.txt", parentPath: "/b",
            isDirectory: false, size: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "txt"
        )
        let group = DuplicateGroup(key: "test.txt", records: [record1, record2])
        let original = IPCResponse.duplicates([group])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded == original)
    }

    @Test("DuplicateGroup Codable round-trip")
    func testDuplicateGroupCodable() throws {
        let record = FileRecord(
            id: 1, name: "dup.pdf", originalName: "dup.pdf",
            path: "/x/dup.pdf", parentPath: "/x",
            isDirectory: false, size: 2048,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
            extension: "pdf"
        )
        let group = DuplicateGroup(key: "size:2048", records: [record])
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(DuplicateGroup.self, from: data)
        #expect(decoded == group)
    }

    @Test("DuplicateGroup Equatable compares by key and record IDs")
    func testDuplicateGroupEquatable() {
        let r1 = FileRecord(
            id: 1, name: "a.txt", originalName: "a.txt",
            path: "/a", parentPath: "/",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )
        let r2 = FileRecord(
            id: 2, name: "a.txt", originalName: "a.txt",
            path: "/b", parentPath: "/",
            isDirectory: false, size: 0,
            createdAt: Date(), modifiedAt: Date(), extension: "txt"
        )
        let group1 = DuplicateGroup(key: "a.txt", records: [r1, r2])
        let group2 = DuplicateGroup(key: "a.txt", records: [r1, r2])
        let group3 = DuplicateGroup(key: "b.txt", records: [r1])
        #expect(group1 == group2)
        #expect(group1 != group3)
    }
}
