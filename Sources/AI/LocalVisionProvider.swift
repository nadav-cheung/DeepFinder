// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

/// On-device image classification using Vision framework's VNClassifyImageRequest.
///
/// Produces text labels (scene/object tags) for indexing, running on the Neural Engine/GPU.
/// No image data leaves the device. Tags are persisted to SQLite as vision_metadata fields.
// Sources/AI/LocalVisionProvider.swift
import Foundation
import Vision
import OSLog
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderPersist

private let logger = Logger(subsystem: Product.aiSubsystem, category: "local-vision")

/// Analyzes image files locally using the Vision framework to produce
/// text labels (scene/object tags) suitable for indexing.
///
/// **Privacy**: Completely local execution, zero network calls. Uses
/// `VNClassifyImageRequest` which runs on the Neural Engine / GPU.
/// No image data ever leaves the device.
///
/// **Graceful degradation**: Returns `nil` if:
/// - The file doesn't exist or isn't readable
/// - Vision framework can't create a handler for the image format
/// - `VNClassifyImageRequest` fails to perform analysis
/// - No observations are returned
/// The caller should treat `nil` as "no tags available" and continue indexing
/// without Vision-generated tags.
///
/// REQ-3.0-10: Local image classification.
public struct LocalVisionProvider: Sendable {

    public init() {}

    /// File extensions that this provider can analyze.
    /// Images with other extensions are silently skipped.
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif"]

    /// Minimum confidence threshold (0-1) for a label to be included.
    /// Tuned to produce useful tags without excessive noise.
    private static let confidenceThreshold: Float = 0.3

    /// Analyzes the image at the given URL and returns classification tags.
    ///
    /// - Parameter url: File URL of the image to analyze.
    /// - Returns: Array of tag strings (e.g. ["sunset", "beach", "ocean"]),
    ///   or `nil` if the image cannot be read or analyzed.
    public func analyzeImage(at url: URL) async -> [String]? {
        // Verify the file exists and is readable
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        // Create a Vision request handler for the image
        let handler: VNImageRequestHandler
        do {
            handler = try VNImageRequestHandler(url: url, options: [:])
        } catch {
            logger.debug("Vision handler creation failed for \(url.lastPathComponent): \(error)")
            return nil
        }

        // Create the classification request
        let request = VNClassifyImageRequest()

        do {
            try handler.perform([request])
        } catch {
            logger.debug("Vision classification failed for \(url.lastPathComponent): \(error)")
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

    /// Converts vision tags into `ExtractedMetadata` for SQLite persistence.
    ///
    /// Tags are stored as a comma-separated string under the key "vision_tags".
    /// Returns `nil` if the tags array is empty, so callers can skip persistence
    /// when there is nothing to store.
    ///
    /// REQ-3.0-10: Vision tags persistence.
    public static func tagsToMetadata(_ tags: [String]) -> ExtractedMetadata? {
        guard !tags.isEmpty else { return nil }
        return ExtractedMetadata(
            fileExtension: "",
            fields: ["vision_tags": .string(tags.joined(separator: ","))]
        )
    }
}
