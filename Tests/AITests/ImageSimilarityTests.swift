// Tests/AITests/ImageSimilarityTests.swift
import Testing
import Foundation
import ImageIO
@testable import DeepFinder

@Suite("ImageSimilaritySearch")
struct ImageSimilarityTests {

    private let searcher = ImageSimilaritySearch()

    // MARK: - Feature Vector Extraction

    @Test("extractFeatureVector returns non-empty data for valid image")
    func extractFeatureVectorReturnsDataForValidImage() async throws {
        let url = createTestPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = await searcher.extractFeatureVector(from: url)
        #expect(data != nil)
        #expect(!data!.isEmpty)
    }

    @Test("extractFeatureVector returns nil for non-existent file")
    func extractFeatureVectorReturnsNilForMissingFile() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).png")
        let data = await searcher.extractFeatureVector(from: url)
        #expect(data == nil)
    }

    // MARK: - Cosine Similarity

    @Test("cosine similarity between identical vectors is 1.0")
    func cosineSimilarityIdentical() {
        // Create a known Float32 vector
        let floats: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let data = floats.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }

        let similarity = searcher.cosineSimilarity(data, data)
        #expect(abs(similarity - 1.0) < 0.0001)
    }

    @Test("cosine similarity between different vectors is between 0 and 1")
    func cosineSimilarityDifferent() {
        let floatsA: [Float] = [1.0, 0.0, 0.0]
        let floatsB: [Float] = [0.0, 1.0, 0.0]

        let dataA = floatsA.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        let dataB = floatsB.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }

        let similarity = searcher.cosineSimilarity(dataA, dataB)
        // Orthogonal vectors: cosine similarity = 0
        #expect(similarity >= 0.0)
        #expect(similarity <= 1.0)
        #expect(abs(similarity) < 0.0001)
    }

    @Test("cosine similarity of parallel vectors with same direction is 1.0")
    func cosineSimilarityParallel() {
        let floatsA: [Float] = [1.0, 2.0, 3.0]
        let floatsB: [Float] = [2.0, 4.0, 6.0] // same direction, scaled

        let dataA = floatsA.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        let dataB = floatsB.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }

        let similarity = searcher.cosineSimilarity(dataA, dataB)
        #expect(abs(similarity - 1.0) < 0.0001)
    }

    // MARK: - Find Similar

    @Test("findSimilar returns top-K results sorted by similarity descending")
    func findSimilarReturnsTopK() {
        let queryVector = floatVectorData([1.0, 0.0, 0.0])

        // Candidate 1: exact match (similarity = 1.0)
        let c1 = ImageFeatureVector(
            data: floatVectorData([1.0, 0.0, 0.0]),
            fileID: 1
        )
        // Candidate 2: 45-degree (similarity = 0.707)
        let c2 = ImageFeatureVector(
            data: floatVectorData([1.0, 1.0, 0.0]),
            fileID: 2
        )
        // Candidate 3: orthogonal (similarity = 0.0)
        let c3 = ImageFeatureVector(
            data: floatVectorData([0.0, 1.0, 0.0]),
            fileID: 3
        )
        // Candidate 4: opposite direction (similarity < 0)
        let c4 = ImageFeatureVector(
            data: floatVectorData([-1.0, 0.0, 0.0]),
            fileID: 4
        )

        let results = searcher.findSimilar(
            queryVector: queryVector,
            candidates: [c3, c4, c1, c2],
            topK: 2
        )

        // Should return only top 2 (above 0.1 threshold)
        #expect(results.count == 2)
        #expect(results[0].fileID == 1) // highest similarity
        #expect(results[1].fileID == 2) // second highest

        // Verify sorted descending by similarity
        #expect(results[0].similarity > results[1].similarity)
    }

    @Test("findSimilar filters out results below 0.1 similarity threshold")
    func findSimilarFiltersLowSimilarity() {
        let queryVector = floatVectorData([1.0, 0.0, 0.0])

        let c1 = ImageFeatureVector(
            data: floatVectorData([0.0, 1.0, 0.0]), // similarity = 0
            fileID: 1
        )

        let results = searcher.findSimilar(
            queryVector: queryVector,
            candidates: [c1],
            topK: 20
        )

        #expect(results.isEmpty)
    }

    @Test("findSimilar with empty candidates returns empty")
    func findSimilarEmptyCandidates() {
        let queryVector = floatVectorData([1.0, 0.0, 0.0])

        let results = searcher.findSimilar(
            queryVector: queryVector,
            candidates: [],
            topK: 20
        )

        #expect(results.isEmpty)
    }

    // MARK: - Helpers

    private func floatVectorData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
    }

    private func createTestPNG(width: Int, height: Int) -> URL {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_sim_\(UUID().uuidString).png")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 4 * width,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            Issue.record("Failed to create CGContext")
            return url
        }
        // Use a varied color so Vision produces meaningful features
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            Issue.record("Failed to create CGImage")
            return url
        }

        let uti = "public.png" as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
            Issue.record("Failed to create CGImageDestination")
            return url
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("Failed to finalize PNG")
            return url
        }

        return url
    }
}
