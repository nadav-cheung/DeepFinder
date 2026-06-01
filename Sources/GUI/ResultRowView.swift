import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ResultRowView

/// Single result row showing file icon, highlighted filename, path, size, date, and match badge.
///
/// REQ-2.0-04: File icon + match-highlighted filename + shortened path + size/date + match badge.
struct ResultRowView: View {

    let result: SearchResult
    let isSelected: Bool
    var query: String = ""
    var workspace: (any WorkspaceProtocol)? = nil

    var body: some View {
        let ext = result.record.extension
        let icon = result.record.isDirectory
            ? FileIconCache.icon(forExtension: nil, isDirectory: true)
            : FileIconCache.icon(forExtension: ext, isDirectory: false)
        return HStack(spacing: 10) {
            // File icon
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

            // Filename + path
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    query.isEmpty
                        ? AttributedString(result.record.originalName)
                        : MatchHighlighter.highlight(
                            filename: result.record.originalName,
                            query: query
                        )
                )
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

                Text(PathShortener.shorten(result.record.parentPath))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Match type badge
            Text(result.matchType.badgeLabel)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)

            // Size + date
            VStack(alignment: .trailing, spacing: 2) {
                Text(FileSizeFormatter.format(result.record.size))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(result.record.modifiedAt, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .contextMenu {
            if workspace != nil {
                let items = ResultContextMenu.menuItems(
                    for: result.record.path,
                    actions: ResultContextMenuHandler()
                )
                ForEach(items, id: \.id) { item in
                    Button(item.label) { item.action() }
                }
            }
        }
        .resultDrag(path: result.record.path)
    }
}

// MARK: - FileIconCache

/// Caches file icons by extension using NSWorkspace.
///
/// REQ-2.0-06: NSCache by extension, 16x16 icons, directory and generic fallbacks.
enum FileIconCache {

    private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    /// Returns a cached 16x16 icon for the given extension.
    /// - Parameters:
    ///   - ext: File extension without dot, or nil for no extension.
    ///   - isDirectory: Whether the item is a directory.
    static func icon(forExtension ext: String?, isDirectory: Bool = false) -> NSImage {
        let key: NSString
        if isDirectory {
            key = "__directory__" as NSString
        } else if let ext {
            key = ext.lowercased() as NSString
        } else {
            key = "__generic__" as NSString
        }

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let icon: NSImage
        if isDirectory {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if let ext, !ext.isEmpty {
            if let utType = UTType(filenameExtension: ext) {
                icon = NSWorkspace.shared.icon(for: utType)
            } else {
                icon = NSWorkspace.shared.icon(for: .item)
            }
        } else {
            icon = NSWorkspace.shared.icon(for: .item)
        }

        let sized = NSImage(size: NSSize(width: 16, height: 16))
        sized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        sized.unlockFocus()
        cache.setObject(sized, forKey: key)
        return sized
    }
}

// MARK: - MatchHighlighter

/// Highlights matching substring in a filename using AttributedString.
enum MatchHighlighter {

    /// Returns an AttributedString with the matched range highlighted in the system accent color.
    /// Case-insensitive matching. Returns plain text if query is empty.
    static func highlight(filename: String, query: String) -> AttributedString {
        guard !query.isEmpty else {
            return AttributedString(filename)
        }

        var attributed = AttributedString(filename)

        // Case-insensitive range search
        guard let range = filename.lowercased().range(of: query.lowercased()) else {
            return attributed
        }

        guard let lower = AttributedString.CharacterView.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.CharacterView.Index(range.upperBound, within: attributed) else {
            return attributed
        }
        attributed[lower..<upper].foregroundColor = .accentColor
        attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized

        return attributed
    }
}

// MARK: - PathShortener

/// Shortens file paths by replacing the user's home directory with `~`.
enum PathShortener {

    /// Replaces `/Users/<whoami>` prefix with `~`.
    static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        let relative = path.dropFirst(home.count)
        return "~" + relative
    }
}

// MARK: - FileSizeFormatter

/// Formats byte counts into human-readable strings (B, KB, MB, GB).
enum FileSizeFormatter {

    static func format(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB", kb)
                .replacingOccurrences(of: ".0 KB", with: " KB")
        } else if bytes < 1_073_741_824 {
            let mb = Double(bytes) / 1_048_576.0
            return String(format: "%.1f MB", mb)
                .replacingOccurrences(of: ".0 MB", with: " MB")
        } else {
            let gb = Double(bytes) / 1_073_741_824.0
            let formatted = String(format: "%.2f GB", gb)
            // Strip trailing zeros after decimal: "1.00 GB" → "1 GB", "2.30 GB" → "2.3 GB"
            if formatted.hasSuffix(".00 GB") {
                return formatted.replacingOccurrences(of: ".00 GB", with: " GB")
            } else if formatted.hasSuffix("0 GB") {
                return formatted.replacingOccurrences(of: "0 GB", with: " GB")
            }
            return formatted
        }
    }
}

// MARK: - MatchType badge label

extension MatchType {

    /// Badge label for display in ResultRowView.
    var badgeLabel: String {
        switch self {
        case .exact: "Exact"
        case .prefix: "Prefix"
        case .pinyin: "Pinyin"
        case .substring: "Substring"
        }
    }
}
