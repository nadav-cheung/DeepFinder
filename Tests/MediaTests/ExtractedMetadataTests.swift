// Tests/MediaTests/ExtractedMetadataTests.swift
import Testing
import Foundation
import DeepFinderIndex
@testable import DeepFinderMedia

@Suite("ExtractedMetadata")
struct ExtractedMetadataTests {

    @Test("MetadataValue string access")
    func metadataValueStringAccess() {
        let val = MetadataValue.string("test")
        #expect(val.stringValue == "test")
        #expect(val.intValue == nil)
        #expect(val.doubleValue == nil)
    }

    @Test("MetadataValue int access")
    func metadataValueIntAccess() {
        let val = MetadataValue.integer(42)
        #expect(val.intValue == 42)
        #expect(val.doubleValue == 42.0)
        #expect(val.stringValue == nil)
    }

    @Test("MetadataValue double access")
    func metadataValueDoubleAccess() {
        let val = MetadataValue.double(3.14)
        #expect(val.doubleValue == 3.14)
        #expect(val.intValue == nil)
        #expect(val.stringValue == nil)
    }

    @Test("MetadataValue date access")
    func metadataValueDateAccess() {
        let date = Date(timeIntervalSince1970: 1000000)
        let val = MetadataValue.date(date)
        #expect(val.dateValue == date)
        #expect(val.stringValue == nil)
    }

    @Test("ExtractedMetadata stores and retrieves values")
    func extractedMetadataStoresValues() {
        var meta = ExtractedMetadata(fileExtension: "jpg")
        meta.fields["width"] = .integer(1920)
        meta.fields["height"] = .integer(1080)

        #expect(meta.fields["width"]?.intValue == 1920)
        #expect(meta.fields["height"]?.intValue == 1080)
        #expect(meta.fields["missing"] == nil)
    }

    @Test("ExtractedMetadata is Sendable and Codable")
    func extractedMetadataSendable() {
        var meta = ExtractedMetadata(fileExtension: "jpg")
        meta.fields["width"] = .integer(1920)
        meta.fields["artist"] = .string("test")

        let data = try! JSONEncoder().encode(meta)
        let decoded = try! JSONDecoder().decode(ExtractedMetadata.self, from: data)
        #expect(decoded.fields["width"]?.intValue == 1920)
        #expect(decoded.fileExtension == "jpg")
    }

    @Test("Empty ExtractedMetadata")
    func emptyMetadata() {
        let meta = ExtractedMetadata(fileExtension: "txt")
        #expect(meta.fields.isEmpty)
        #expect(meta.fileExtension == "txt")
    }
}
