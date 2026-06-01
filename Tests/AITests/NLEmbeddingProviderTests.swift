import Foundation
import Testing
@testable import DeepFinder

@Suite("NLEmbeddingProvider", .serialized)
struct NLEmbeddingProviderTests {

    @Test("provider returns 512 dimensions")
    func dimensionsAre512() async throws {
        let provider = NLEmbeddingProvider()
        #expect(provider.name == "nlcontextual")
        #expect(provider.dimensions == 512)
    }

    @Test("embed Chinese text returns non-zero 512-dim vector")
    func embedChineseText() async throws {
        let provider = NLEmbeddingProvider()
        let vector = try await provider.embed(text: "财务报表2024.xlsx")
        #expect(vector.count == 512)
        let hasNonZero = vector.contains { $0 != 0 }
        #expect(hasNonZero)
    }

    @Test("embed English text returns non-zero 512-dim vector")
    func embedEnglishText() async throws {
        let provider = NLEmbeddingProvider()
        let vector = try await provider.embed(text: "budget-report-2024.xlsx")
        #expect(vector.count == 512)
        let hasNonZero = vector.contains { $0 != 0 }
        #expect(hasNonZero)
    }

    @Test("embed mixed Chinese-English text returns non-zero vector")
    func embedMixedText() async throws {
        let provider = NLEmbeddingProvider()
        let vector = try await provider.embed(text: "Q4财务report-final.pdf")
        #expect(vector.count == 512)
        let hasNonZero = vector.contains { $0 != 0 }
        #expect(hasNonZero)
    }

    @Test("embedBatch preserves count and order")
    func embedBatchPreservesOrder() async throws {
        let provider = NLEmbeddingProvider()
        let texts = ["file-a.txt", "文件B.doc", "mixed-C.pdf"]
        let results = try await provider.embedBatch(texts: texts)
        #expect(results.count == 3)
        for (i, vector) in results.enumerated() {
            #expect(vector.count == 512)
            let expected = try await provider.embed(text: texts[i])
            #expect(vector == expected)
        }
    }

    @Test("similar Chinese texts cluster closer than dissimilar")
    func similarChineseTextsCluster() async throws {
        let provider = NLEmbeddingProvider()
        let v1 = try await provider.embed(text: "财务报表2024.xlsx")
        let v2 = try await provider.embed(text: "财务报表2025.xlsx")
        let v3 = try await provider.embed(text: "度假照片.jpg")

        let sim12 = cosineSimilarity(v1, v2)
        let sim13 = cosineSimilarity(v1, v3)
        #expect(sim12 > sim13)
    }

    @Test("similar English texts cluster closer than dissimilar")
    func similarEnglishTextsCluster() async throws {
        let provider = NLEmbeddingProvider()
        let v1 = try await provider.embed(text: "budget-2024.xlsx")
        let v2 = try await provider.embed(text: "budget-2025.xlsx")
        let v3 = try await provider.embed(text: "vacation-photo.jpg")

        let sim12 = cosineSimilarity(v1, v2)
        let sim13 = cosineSimilarity(v1, v3)
        #expect(sim12 > sim13)
    }

    @Test("empty text returns zero vector")
    func emptyTextReturnsZeroVector() async throws {
        let provider = NLEmbeddingProvider()
        let vector = try await provider.embed(text: "")
        #expect(vector.count == 512)
        #expect(vector.allSatisfy { $0 == 0 })
    }

    @Test("NLEmbeddingProvider is Sendable")
    func isSendable() {
        let provider = NLEmbeddingProvider()
        func assertSendable<T: Sendable>(_: T) {}
        assertSendable(provider)
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    let dot = zip(a, b).map(*).reduce(0, +)
    let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
    let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
    guard normA > 0, normB > 0 else { return 0 }
    return dot / (normA * normB)
}
