import Testing
import Foundation
@testable import DeepFinderGUILib

@Suite("AccessHistoryStore")
struct AccessHistoryTests {

    // MARK: - Recording

    @Test("recordAccess adds new record for unique path")
    func testRecordAccessNewPath() {
        let store = AccessHistoryStore()
        let uniquePath = "/tmp/deepfinder-test-\(UUID().uuidString).txt"

        store.recordAccess(uniquePath)

        // The record must exist with openCount=1 regardless of eviction
        let record = store.allRecords.first { $0.filePath == uniquePath }
        #expect(record != nil)
        #expect(record?.openCount == 1)
    }

    @Test("recordAccess increments count for existing path")
    func testRecordAccessExistingPath() {
        let store = AccessHistoryStore()
        let uniquePath = "/tmp/deepfinder-test-\(UUID().uuidString).txt"

        store.recordAccess(uniquePath)
        store.recordAccess(uniquePath)
        store.recordAccess(uniquePath)

        let record = store.allRecords.first { $0.filePath == uniquePath }
        #expect(record?.openCount == 3)
    }

    // MARK: - Ranking

    @Test("sortedPaths returns paths including newly recorded ones")
    func testSortedPathsIncludesRecorded() {
        let store = AccessHistoryStore()
        let uniqueA = "/tmp/deepfinder-test-a-\(UUID().uuidString).txt"
        let uniqueB = "/tmp/deepfinder-test-b-\(UUID().uuidString).txt"

        // File A: opened 10 times (high frequency)
        for _ in 0..<10 {
            store.recordAccess(uniqueA)
        }

        // File B: opened 1 time
        store.recordAccess(uniqueB)

        let ranked = store.sortedPaths()
        #expect(ranked.contains(uniqueA))
        #expect(ranked.contains(uniqueB))
        // File A should rank higher due to higher open count
        let indexA = ranked.firstIndex(of: uniqueA)
        let indexB = ranked.firstIndex(of: uniqueB)
        #expect(indexA != nil)
        #expect(indexB != nil)
        #expect(indexA! < indexB!)
    }

    // MARK: - Eviction

    @Test("store respects maxEntries limit")
    func testMaxEntriesLimit() {
        let store = AccessHistoryStore()
        let limit = AccessHistoryStore.maxEntries

        // Add more than limit entries with unique UUIDs
        let uuid = UUID().uuidString
        for i in 0..<(limit + 100) {
            store.recordAccess("/tmp/df-test-\(uuid)-\(i).txt")
        }

        #expect(store.allRecords.count <= limit)
    }

    // MARK: - AccessRecord

    @Test("AccessRecord Codable round-trip")
    func testAccessRecordCodable() throws {
        let record = AccessRecord(filePath: "/test/path.txt", openCount: 5, lastOpened: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AccessRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test("AccessRecord Equatable works")
    func testAccessRecordEquatable() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = AccessRecord(filePath: "/a.txt", openCount: 1, lastOpened: date)
        let b = AccessRecord(filePath: "/a.txt", openCount: 1, lastOpened: date)
        let c = AccessRecord(filePath: "/b.txt", openCount: 1, lastOpened: date)
        #expect(a == b)
        #expect(a != c)
    }
}
