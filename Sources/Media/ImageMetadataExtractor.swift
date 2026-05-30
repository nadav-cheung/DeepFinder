// Sources/Media/ImageMetadataExtractor.swift
import Foundation
import ImageIO

/// Extracts metadata from image files using ImageIO/CGImageSource.
struct ImageMetadataExtractor: MetadataExtractor, Sendable {
    let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "gif", "tiff", "tif", "bmp", "webp"
    ]

    func extract(url: URL) async -> ExtractedMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        var meta = ExtractedMetadata(fileExtension: url.pathExtension.lowercased())

        // Pixel dimensions
        if let width = properties[kCGImagePropertyPixelWidth] as? Int {
            meta.fields["width"] = .integer(width)
        }
        if let height = properties[kCGImagePropertyPixelHeight] as? Int {
            meta.fields["height"] = .integer(height)
        }

        // DPI
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Int {
            meta.fields["dpi"] = .integer(dpi)
        }

        // Color space
        if let colorSpace = properties[kCGImagePropertyColorModel] as? String {
            meta.fields["colorSpace"] = .string(colorSpace)
        }

        // Orientation
        if let orientation = properties[kCGImagePropertyOrientation] as? Int {
            meta.fields["orientation"] = .integer(orientation)
        }

        // EXIF date
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: dateStr) {
                meta.fields["dateTaken"] = .date(date)
            }
        }

        return meta
    }
}
