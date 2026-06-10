// Sources/Index/ExtractedMetadata.swift
import Foundation

/// A polymorphic metadata value extracted from a media file.
///
/// Wraps common types (string, integer, double, date) into a single enum
/// so that heterogeneous metadata fields can be stored in a uniform dictionary.
/// Provides typed accessors that return `nil` when the stored type doesn't match.
public enum MetadataValue: Sendable, Equatable, Codable {
    /// A string value (e.g. artist name, codec, title).
    case string(String)
    /// An integer value (e.g. image width, page count, bitrate).
    case integer(Int)
    /// A floating-point value (e.g. duration in seconds, DPI).
    case double(Double)
    /// A date value (e.g. creation date from EXIF, PDF mod date).
    case date(Date)

    /// Returns the string value if this is a `.string` case, otherwise `nil`.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Returns the integer value if this is an `.integer` case, otherwise `nil`.
    public var intValue: Int? {
        if case .integer(let v) = self { return v }
        return nil
    }

    /// Returns the double value if this is `.double` or `.integer`, otherwise `nil`.
    /// Integer values are implicitly converted to `Double`.
    public var doubleValue: Double? {
        if case .double(let v) = self { return v }
        if case .integer(let v) = self { return Double(v) }
        return nil
    }

    /// Returns the date value if this is a `.date` case, otherwise `nil`.
    public var dateValue: Date? {
        if case .date(let v) = self { return v }
        return nil
    }
}

/// Metadata extracted from a single media file.
///
/// Stores a dictionary of named metadata fields. The key names are standardized
/// per file type (e.g. "width" and "height" for images, "duration" for audio/video,
/// "pageCount" for PDFs). All keys are lowercase.
///
/// Conforms to `Codable` for SQLite persistence and `Sendable` for safe cross-actor transfer.
public struct ExtractedMetadata: Sendable, Equatable, Codable {
    /// The file extension that was used to select the extractor (lowercase, no dot).
    public let fileExtension: String

    /// Named metadata fields. Keys are lowercase strings like "width", "artist", "duration".
    /// Values are ``MetadataValue`` instances wrapping typed data.
    public var fields: [String: MetadataValue]

    public init(fileExtension: String, fields: [String: MetadataValue] = [:]) {
        self.fileExtension = fileExtension
        self.fields = fields
    }
}
