import Foundation
import Testing
@testable import DeepFinderAI

@Suite("VectorStore")
struct VectorStoreTests {

    @Test("insert and search returns closest vectors by cosine similarity")
    func insertAndSearch() async throws {
        let store = MockVectorStore()
        try await store.insert(id: 1, vector: [1.0, 0.0, 0.0])
        try await store.insert(id: 2, vector: [0.0, 1.0, 0.0])
        try await store.insert(id: 3, vector: [1.0, 0.1, 0.0])

        let results = try await store.search(query: [1.0, 0.0, 0.0], topK: 2)
        #expect(results.count == 2)
        // ID 1 should be closest (exact match)
        #expect(results[0].id == 1)
        #expect(results[0].score > results[1].score)
    }

    @Test("delete removes vector from store")
    func deleteRemovesVector() async throws {
        let store = MockVectorStore()
        try await store.insert(id: 42, vector: [1.0, 2.0, 3.0])
        #expect(await store.count() == 1)
        try await store.delete(id: 42)
        #expect(await store.count() == 0)
    }

    @Test("delete of non-existent ID is no-op")
    func deleteNonExistentIdIsNoOp() async throws {
        let store = MockVectorStore()
        try await store.insert(id: 1, vector: [1.0, 0.0])
        #expect(await store.count() == 1)
        try await store.delete(id: 999)
        #expect(await store.count() == 1)
    }

    @Test("insert replaces existing vector for same ID")
    func insertReplacesExisting() async throws {
        let store = MockVectorStore()
        try await store.insert(id: 1, vector: [1.0, 0.0, 0.0])
        try await store.insert(id: 1, vector: [0.0, 1.0, 0.0])
        #expect(await store.count() == 1)
        let results = try await store.search(query: [0.0, 1.0, 0.0], topK: 1)
        #expect(results[0].id == 1)
        #expect(results[0].score > 0.99)
    }

    @Test("empty store returns empty search results")
    func emptyStoreReturnsEmptyResults() async throws {
        let store = MockVectorStore()
        let results = try await store.search(query: [1.0, 0.0], topK: 5)
        #expect(results.isEmpty)
    }

    @Test("search with topK larger than store count returns all vectors")
    func searchWithTopKLargerThanStore() async throws {
        let store = MockVectorStore()
        try await store.insert(id: 1, vector: [1.0, 0.0])
        let results = try await store.search(query: [0.0, 1.0], topK: 10)
        #expect(results.count == 1)
    }

    @Test("count reflects inserts and deletes")
    func countReflectsInsertsAndDeletes() async throws {
        let store = MockVectorStore()
        for i in 0..<100 { try await store.insert(id: UInt64(i), vector: [Float(i)]) }
        #expect(await store.count() == 100)
        for i in 0..<50 { try await store.delete(id: UInt64(i)) }
        #expect(await store.count() == 50)
    }
}

/// In-memory mock using brute-force cosine similarity.
final class MockVectorStore: VectorStore, @unchecked Sendable {
    private var vectors: [(id: UInt64, vector: [Float])] = []
    private let lock = NSLock()

    func insert(id: UInt64, vector: [Float]) async throws {
        lock.withLock {
            vectors.removeAll { $0.id == id }
            vectors.append((id, vector))
        }
    }

    func search(query: [Float], topK: Int) async throws -> [(id: UInt64, score: Float)] {
        lock.withLock {
            Array(vectors
                .map { (id: $0.id, score: Self.cosineSimilarity(query, $0.vector)) }
                .sorted { $0.score > $1.score }
                .prefix(topK))
        }
    }

    func delete(id: UInt64) async throws {
        lock.withLock {
            vectors.removeAll { $0.id == id }
        }
    }

    func count() async -> Int {
        lock.withLock {
            vectors.count
        }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).map(*).reduce(0, +)
        let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }
}
