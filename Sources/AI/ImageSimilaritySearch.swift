/// On-device image similarity search using Vision framework feature vectors.
///
/// Extracts VNFeaturePrintObservation embeddings from images, computes cosine similarity,
/// and returns ranked results. Entirely local -- no image data leaves the device.
// Sources/AI/ImageSimilaritySearch.swift
import Foundation
import Vision
import OSLog

private let logger = Logger(subsystem: Product.aiSubsystem, category: "image-similarity")

/// A feature vector extracted from an image by the Vision framework.
///
/// REQ-3.0-11: Stores the raw feature print data for later similarity comparison.
struct ImageFeatureVector: Sendable, Equatable {
    /// Raw feature data (array of Float32 values encoded as bytes).
    let data: Data
    /// The FileRecord ID this vector was extracted from.
    let fileID: UInt32
}

/// A similarity search result pairing a file ID with its similarity score.
struct SimilarityResult: Sendable, Equatable {
    /// The FileRecord ID of the matching image.
    let fileID: UInt32
    /// Cosine similarity score in range [0.0, 1.0].
    let similarity: Double
}

/// Extracts feature vectors from images and finds visually similar images.
///
/// **Privacy**: Uses `VNFeaturePrintObservation` (Vision framework) for completely
/// local feature extraction. Feature vectors never leave the device. No network calls.
///
/// **Graceful degradation**:
/// - `extractFeatureVector(from:)` returns `nil` if the file doesn't exist,
///   isn't a valid image, or Vision analysis fails
/// - `findSimilar()` returns an empty array if no candidates meet the similarity
///   threshold
/// - `cosineSimilarity()` returns 0.0 for empty or zero-magnitude vectors
///
/// REQ-3.0-11: Image similarity search via on-device embeddings.
struct ImageSimilaritySearch: Sendable {

    /// Minimum similarity score (0-1) for a result to be included.
    /// Filters out noise from unrelated images. Tuned for Vision feature prints,
    /// which typically produce scores in [0.0, 1.0] for similar images.
    static let similarityThreshold: Double = 0.1

    // MARK: - Feature Extraction

    /// Extracts a feature vector from the image at the given URL.
    ///
    /// Uses `VNGenerateImageFeaturePrintRequest` which runs entirely on-device.
    ///
    /// - Parameter url: File URL of the image to analyze.
    /// - Returns: Feature data bytes, or `nil` if extraction fails.
    func extractFeatureVector(from url: URL) async -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let handler: VNImageRequestHandler
        do {
            handler = try VNImageRequestHandler(url: url, options: [:])
        } catch {
            logger.debug("Vision handler creation failed for \(url.lastPathComponent): \(error)")
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()

        do {
            try handler.perform([request])
        } catch {
            logger.debug("Vision feature print failed for \(url.lastPathComponent): \(error)")
            return nil
        }

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            return nil
        }

        return observation.data
    }

    // MARK: - Similarity Computation

    /// Computes cosine similarity between two feature vectors.
    ///
    /// Treats the data as a contiguous array of Float32 values.
    /// Returns 0.0 if either vector is empty or has zero magnitude.
    ///
    /// - Parameters:
    ///   - a: First feature vector data.
    ///   - b: Second feature vector data.
    /// - Returns: Cosine similarity in range [-1.0, 1.0] (typically [0.0, 1.0]
    ///   for Vision feature prints).
    func cosineSimilarity(_ a: Data, _ b: Data) -> Double {
        let stride = MemoryLayout<Float>.stride
        let count = min(a.count / stride, b.count / stride)
        guard count > 0 else { return 0.0 }

        return a.withUnsafeBytes { rawA in
            b.withUnsafeBytes { rawB in
                guard let ptrA = rawA.baseAddress?.assumingMemoryBound(to: Float.self),
                      let ptrB = rawB.baseAddress?.assumingMemoryBound(to: Float.self) else {
                    return 0.0
                }

                var dotProduct: Double = 0.0
                var normA: Double = 0.0
                var normB: Double = 0.0

                for i in 0..<count {
                    let va = Double(ptrA[i])
                    let vb = Double(ptrB[i])
                    dotProduct += va * vb
                    normA += va * va
                    normB += vb * vb
                }

                let denominator = sqrt(normA) * sqrt(normB)
                guard denominator > 0.0 else { return 0.0 }
                return dotProduct / denominator
            }
        }
    }

    // MARK: - Similarity Search

    /// Finds the top-K most similar images to a query vector.
    ///
    /// Computes cosine similarity between the query and each candidate,
    /// filters out results below the similarity threshold, and returns
    /// the top K results sorted by similarity descending.
    ///
    /// - Parameters:
    ///   - queryVector: Feature vector of the query image.
    ///   - candidates: Array of indexed image feature vectors to search against.
    ///   - topK: Maximum number of results to return (default 20).
    /// - Returns: Similarity results sorted by similarity descending.
    func findSimilar(
        queryVector: Data,
        candidates: [ImageFeatureVector],
        topK: Int = 20
    ) -> [SimilarityResult] {
        guard !candidates.isEmpty else { return [] }

        var results: [SimilarityResult] = []
        results.reserveCapacity(min(candidates.count, topK))

        for candidate in candidates {
            let sim = cosineSimilarity(queryVector, candidate.data)
            guard sim >= Self.similarityThreshold else { continue }
            results.append(SimilarityResult(fileID: candidate.fileID, similarity: sim))
        }

        // Sort descending by similarity, take top K
        results.sort { $0.similarity > $1.similarity }
        if results.count > topK {
            results = Array(results.prefix(topK))
        }

        return results
    }
}
