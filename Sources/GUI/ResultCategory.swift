import Foundation

// MARK: - ResultCategory

/// Categories for grouping search results by file type.
///
/// Each case maps to a set of file extensions, a display name, an SF Symbol,
/// and a sort priority (lower = higher priority in grouped displays).
enum ResultCategory: String, CaseIterable, Sendable {
    case code
    case documents
    case images
    case video
    case audio
    case archives
    case other

    // MARK: - Extension Sets

    /// File extensions belonging to each category (lowercased, no leading dot).
    private static let extensionMap: [String: ResultCategory] = {
        var map: [String: ResultCategory] = [:]
        let categories: [(ResultCategory, [String])] = [
            (.code,      ["swift", "py", "js", "ts", "html", "css", "json", "yaml", "yml", "xml",
                          "rb", "go", "rs", "c", "cpp", "h", "java", "sh", "m", "mm"]),
            (.documents,  ["pdf", "doc", "docx", "txt", "rtf", "pages", "md"]),
            (.images,     ["png", "jpg", "jpeg", "gif", "svg", "tiff", "tif", "heic", "webp", "bmp", "ico"]),
            (.video,      ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm"]),
            (.audio,      ["mp3", "wav", "aac", "flac", "aiff", "m4a", "ogg", "wma"]),
            (.archives,   ["zip", "gz", "tar", "rar", "7z", "bz2", "xz", "dmg", "iso"]),
        ]
        for (category, extensions) in categories {
            for ext in extensions {
                map[ext] = category
            }
        }
        return map
    }()

    // MARK: - Classification

    /// Determines the category for a search result based on its file extension.
    ///
    /// Directories always fall into `.other`. Unknown extensions also map to `.other`.
    static func categorize(_ result: SearchResult) -> ResultCategory {
        guard let ext = result.record.extension?.lowercased() else {
            return .other
        }
        return extensionMap[ext] ?? .other
    }

    // MARK: - Display Properties

    /// Human-readable name for UI display.
    var displayName: String {
        switch self {
        case .code:      return "Code"
        case .documents:  return "Documents"
        case .images:     return "Images"
        case .video:      return "Video"
        case .audio:      return "Audio"
        case .archives:   return "Archives"
        case .other:      return "Other"
        }
    }

    /// SF Symbol name for the category icon.
    var systemImage: String {
        switch self {
        case .code:      return "chevron.left.forwardslash.chevron.right"
        case .documents:  return "doc.fill"
        case .images:     return "photo.fill"
        case .video:      return "film.fill"
        case .audio:      return "music.note"
        case .archives:   return "doc.zipper.fill"
        case .other:      return "questionmark.folder.fill"
        }
    }

    /// Sort priority (lower = shown first in grouped results).
    var sortPriority: Int {
        switch self {
        case .code:      return 0
        case .documents:  return 1
        case .images:     return 2
        case .video:      return 3
        case .audio:      return 4
        case .archives:   return 5
        case .other:      return 6
        }
    }
}
