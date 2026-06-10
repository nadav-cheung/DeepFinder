// Sources/Media/PDFMetadataExtractor.swift
import Foundation
import PDFKit
import DeepFinderIndex

/// Extracts metadata from PDF files using PDFKit.
public struct PDFMetadataExtractor: MetadataExtractor, Sendable {
    public let supportedExtensions: Set<String> = ["pdf"]

    public func extract(url: URL) async -> ExtractedMetadata? {
        guard let document = PDFDocument(url: url) else {
            return nil
        }

        var meta = ExtractedMetadata(fileExtension: "pdf")

        meta.fields["pageCount"] = .integer(document.pageCount)
        meta.fields["isEncrypted"] = .integer(document.isEncrypted ? 1 : 0)

        // Document attributes
        let attributes = document.documentAttributes
        if let title = attributes?[PDFDocumentAttribute.titleAttribute] as? String {
            meta.fields["title"] = .string(title)
        }
        if let author = attributes?[PDFDocumentAttribute.authorAttribute] as? String {
            meta.fields["author"] = .string(author)
        }
        if let subject = attributes?[PDFDocumentAttribute.subjectAttribute] as? String {
            meta.fields["subject"] = .string(subject)
        }
        if let creator = attributes?[PDFDocumentAttribute.creatorAttribute] as? String {
            meta.fields["creator"] = .string(creator)
        }
        if let creationDate = attributes?[PDFDocumentAttribute.creationDateAttribute] as? Date {
            meta.fields["creationDate"] = .date(creationDate)
        }
        if let modDate = attributes?[PDFDocumentAttribute.modificationDateAttribute] as? Date {
            meta.fields["modificationDate"] = .date(modDate)
        }

        return meta
    }
}
