// Tests/MediaTests/PDFMetadataExtractorTests.swift
import Testing
import Foundation
import PDFKit
@testable import DeepFinderMedia

@Suite("PDFMetadataExtractor")
struct PDFMetadataExtractorTests {

    private let extractor = PDFMetadataExtractor()

    @Test("Supported extensions include pdf")
    func supportedExtensions() {
        #expect(extractor.supportedExtensions.contains("pdf"))
    }

    @Test("Extract returns nil for non-existent file")
    func nonExistentFile() async {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_nonexistent_\(UUID().uuidString).pdf")
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract returns nil for corrupt PDF")
    func corruptPdf() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_corrupt_\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await extractor.extract(url: url)
        #expect(result == nil)
    }

    @Test("Extract metadata from valid PDF")
    func extractFromValidPdf() async throws {
        // Create a minimal single-page PDF using Core Graphics
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_valid_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let mutableData = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            #expect(Bool(false), "Failed to create CGContext for PDF")
            return
        }
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()

        try (mutableData as Data).write(to: url)

        let result = await extractor.extract(url: url)
        #expect(result != nil)
        #expect(result?.fields["pageCount"]?.intValue == 1)
    }

    @Test("Extract returns fileExtension as pdf")
    func extractFileExtension() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_ext_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let mutableData = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            #expect(Bool(false), "Failed to create CGContext")
            return
        }
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()

        try (mutableData as Data).write(to: url)

        let result = await extractor.extract(url: url)
        #expect(result?.fileExtension == "pdf")
    }

    @Test("Extract isEncrypted field for valid PDF")
    func extractIsEncrypted() async throws {
        let url = URL(fileURLWithPath: "/tmp/deepfinder_test_encrypted_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let mutableData = NSMutableData()
        var mediaBox = pageRect
        guard let consumer = CGDataConsumer(data: mutableData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            #expect(Bool(false), "Failed to create CGContext")
            return
        }
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()

        try (mutableData as Data).write(to: url)

        let result = await extractor.extract(url: url)
        #expect(result?.fields["isEncrypted"]?.intValue == 0)
    }
}
