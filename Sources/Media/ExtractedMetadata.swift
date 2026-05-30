// Sources/Media/ExtractedMetadata.swift
import Foundation

/// A polymorphic metadata value extracted from a media file.
enum MetadataValue: Sendable, Equatable, Codable {
    case string(String)
    case integer(Int)
    case double(Double)
    case date(Date)

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .integer(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let v) = self { return v }
        if case .integer(let v) = self { return Double(v) }
        return nil
    }

    var dateValue: Date? {
        if case .date(let v) = self { return v }
        return nil
    }
}

/// Metadata extracted from a single media file.
struct ExtractedMetadata: Sendable, Equatable, Codable {
    let fileExtension: String
    var fields: [String: MetadataValue]

    init(fileExtension: String, fields: [String: MetadataValue] = [:]) {
        self.fileExtension = fileExtension
        self.fields = fields
    }
}
