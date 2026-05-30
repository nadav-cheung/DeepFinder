// Sources/AI/LocalVisionProvider.swift
import Foundation
import Vision

/// Analyzes image files locally using the Vision framework to produce
/// text labels (scene/object tags) suitable for indexing.
///
/// REQ-3.0-10: Completely local execution, zero network calls.
/// Uses VNClassifyImageRequest which produces English-only labels.
struct LocalVisionProvider: Sendable {

    /// File extensions that this provider can analyze.
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]

    /// Minimum confidence threshold (0-1) for a label to be included.
    /// Tuned to produce useful tags without excessive noise.
    private static let confidenceThreshold: Float = 0.3

    /// Analyzes the image at the given URL and returns classification tags.
    ///
    /// - Parameter url: File URL of the image to analyze.
    /// - Returns: Array of tag strings (e.g. ["sunset", "beach", "ocean"]),
    ///   or `nil` if the image cannot be read or analyzed.
    func analyzeImage(at url: URL) async -> [String]? {
        // Verify the file exists and is readable
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        // Create a Vision request handler for the image
        let handler: VNImageRequestHandler
        do {
            handler = try VNImageRequestHandler(url: url, options: [:])
        } catch {
            return nil
        }

        // Create the classification request
        let request = VNClassifyImageRequest()

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        // Extract classification observations
        guard let observations = request.results else {
            return nil
        }

        // Filter by confidence and extract identifier strings
        let tags = observations
            .filter { $0.confidence >= Self.confidenceThreshold }
            .map { $0.identifier }

        // Return the tags (may be empty if nothing met threshold)
        return tags
    }
}
