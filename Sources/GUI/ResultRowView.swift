import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - ResultRowView

/// Single result row showing file icon, highlighted filename, path, size, date, and match badge.
///
/// Design language: "Luxury Refined" — Apple's design elevated.
/// - 20pt icons for confident presence
/// - Typographic hierarchy: semibold filename → regular metadata → tertiary path
/// - Generous horizontal rhythm (12pt inner, 16pt outer padding)
/// - Selection: accent-tinted background with cornerRadius 8, subtle elevation shadow
/// - Hover: featherlight .quaternary wash, 0.15s ease
public struct ResultRowView: View, Equatable {

    public let result: SearchResult
    public let isSelected: Bool
    public var query: String = ""
    public var workspace: (any WorkspaceProtocol)? = nil

    @State private var isHovered = false

    // MARK: - Equatable (REQ-3.2-14)

    public nonisolated static func == (lhs: ResultRowView, rhs: ResultRowView) -> Bool {
        lhs.result.record.id == rhs.result.record.id
            && lhs.isSelected == rhs.isSelected
            && lhs.query == rhs.query
    }

    // MARK: - Design Tokens

    private enum Design {
        public static let iconSize: CGFloat = 20
        public static let filenameSize: CGFloat = 13
        public static let filenameWeight: Font.Weight = .semibold
        public static let pathSize: CGFloat = 11
        public static let metaSize: CGFloat = 11
        public static let badgeSize: CGFloat = 10
        public static let hSpacing: CGFloat = 12
        public static let vSpacing: CGFloat = 2
        public static let hPadding: CGFloat = 14
        public static let vPadding: CGFloat = 8
        public static let selectionRadius: CGFloat = 8
        public static let selectionInset: CGFloat = 4
    }

    public var body: some View {
        let ext = result.record.extension
        let icon = result.record.isDirectory
            ? FileIconCache.icon(forExtension: nil, isDirectory: true)
            : FileIconCache.icon(forExtension: ext, isDirectory: false)

        return VStack(spacing: 0) {
            HStack(spacing: Design.hSpacing) {
                // ── File icon
                iconView(icon)

                // ── Filename + path stack
                VStack(alignment: .leading, spacing: Design.vSpacing) {
                    filenameView
                    pathView
                }

                Spacer(minLength: 8)

                // ── Match type badge (subtle, right-aligned)
                badgeView

                // ── Metadata (size + date, aligned right)
                metadataView
            }
            Divider().opacity(0.2)
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, Design.vPadding)
        .background(backgroundView)
        .shadow(
            color: isSelected ? .black.opacity(0.08) : .clear,
            radius: isSelected ? 2 : 0,
            y: isSelected ? 1 : 0
        )
        .contentShape(.rect)
        .help(result.record.parentPath)
        .onHover { hovering in
            withAnimation(.spring(duration: 0.25, bounce: 0.15)) {
                isHovered = hovering
            }
        }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.record.originalName)，\(PathShortener.shorten(result.record.parentPath))，\(FileSizeFormatter.format(result.record.size))")
    }

    // MARK: - Subviews

    private func iconView(_ icon: NSImage) -> some View {
        Image(nsImage: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: Design.iconSize, height: Design.iconSize)
            // REQ-3.2-15: directory badge indicator
            .overlay(alignment: .bottomTrailing) {
                if result.record.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
            }
            // Subtle luminance boost when selected
            .brightness(isSelected ? 0.08 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.1), value: isSelected)
    }

    private var filenameView: some View {
        Text(
            query.isEmpty
                ? AttributedString(result.record.originalName)
                : MatchHighlighter.highlight(
                    filename: result.record.originalName,
                    query: query
                )
        )
        .font(.system(size: Design.filenameSize, weight: Design.filenameWeight))
        .lineLimit(1)
        // Truncate from middle for long filenames — shows beginning + end
        .truncationMode(.middle)
    }

    private var pathView: some View {
        Text(PathShortener.shorten(result.record.parentPath))
            .font(.system(size: Design.pathSize, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var badgeView: some View {
        let badge = Text(result.matchType.badgeLabel)
            .font(.system(size: Design.badgeSize, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)

        switch result.matchType {
        case .exact:
            badge
                .foregroundStyle(GlowColors.teal)
                .background(GlowColors.teal.opacity(0.12), in: Capsule(style: .continuous))
                .shadow(color: GlowColors.teal.opacity(0.15), radius: 2, y: 1)
        case .prefix:
            badge
                .foregroundStyle(GlowColors.violet)
                .background(GlowColors.violet.opacity(0.12), in: Capsule(style: .continuous))
                .shadow(color: GlowColors.violet.opacity(0.15), radius: 2, y: 1)
        case .pinyin:
            badge
                .foregroundStyle(GlowColors.amber)
                .background(GlowColors.amber.opacity(0.12), in: Capsule(style: .continuous))
                .shadow(color: GlowColors.amber.opacity(0.15), radius: 2, y: 1)
        case .substring:
            badge
                .foregroundStyle(.secondary)
                .background(.fill.tertiary.opacity(0.6), in: Capsule(style: .continuous))
        }
    }

    private var metadataView: some View {
        VStack(alignment: .trailing, spacing: Design.vSpacing) {
            Text(FileSizeFormatter.format(result.record.size))
                .font(.system(size: Design.metaSize))
                .foregroundStyle(.secondary)

            Text(result.record.modifiedAt, style: .date)
                .font(.system(size: Design.metaSize, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: Design.selectionRadius, style: .continuous)
            .fill(
                isSelected
                    ? AnyShapeStyle(GlowColors.teal.opacity(0.12))
                    : isHovered
                        ? AnyShapeStyle(GlowColors.teal.opacity(0.06))
                        : AnyShapeStyle(.clear)
            )
            .padding(.horizontal, Design.selectionInset)
            .animation(.spring(duration: 0.2, bounce: 0.1), value: isSelected)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: isHovered)
    }
}

// MARK: - FileIconCache

/// Caches file icons by extension using NSWorkspace.
///
/// Icons are rendered at 22×22 for confident visual presence in result rows.
/// NSCache handles automatic eviction under memory pressure.
public enum FileIconCache {

    private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    /// Returns a cached 22×22 icon for the given extension.
    /// - Parameters:
    ///   - ext: File extension without dot, or nil for no extension.
    ///   - isDirectory: Whether the item is a directory.
    public static func icon(forExtension ext: String?, isDirectory: Bool = false) -> NSImage {
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

        let size: CGFloat = 20
        let sized = NSImage(size: NSSize(width: size, height: size))
        sized.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        sized.unlockFocus()
        cache.setObject(sized, forKey: key)
        return sized
    }
}

// MARK: - MatchHighlighter

/// Highlights all matching substrings in a filename using AttributedString.
///
/// Uses accent color with a subtle bold weight for highlighted ranges,
/// creating clear visual distinction without harsh contrast.
/// Case-insensitive. Unicode-compatible. Finds ALL occurrences.
public enum MatchHighlighter {

    public static func highlight(filename: String, query: String) -> AttributedString {
        guard !query.isEmpty else {
            return AttributedString(filename)
        }

        var attributed = AttributedString(filename)
        let loweredFilename = filename.lowercased()
        let loweredQuery = query.lowercased()

        var searchStart = loweredFilename.startIndex
        while searchStart < loweredFilename.endIndex {
            guard let range = loweredFilename.range(of: loweredQuery, range: searchStart..<loweredFilename.endIndex) else {
                break
            }

            if let lower = AttributedString.CharacterView.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.CharacterView.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = .accentColor
                attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }

            searchStart = range.upperBound
        }

        return attributed
    }
}

// MARK: - PathShortener

/// Shortens file paths: replaces home with ~, then truncates middle for long paths.
///
/// Two-stage shortening:
/// 1. Home directory -> `~`
/// 2. If result > 60 chars: keep first 25 + "..." + last 30
public enum PathShortener {

    public static let maxDisplayLength = 60
    private static let headLength = 25
    private static let tailLength = 30

    public static func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shortened: String
        if path.hasPrefix(home) {
            let relative = path.dropFirst(home.count)
            shortened = "~" + relative
        } else {
            shortened = path
        }
        return truncateMiddle(shortened)
    }

    /// Truncates a path in the middle if it exceeds `maxLength`.
    /// Keeps the first 25 chars + "..." + last 30 chars.
    public static func truncateMiddle(_ path: String, maxLength: Int = maxDisplayLength) -> String {
        guard path.count > maxLength else { return path }
        let head = path.prefix(headLength)
        let tail = path.suffix(tailLength)
        return head + "..." + tail
    }
}

// MARK: - FileSizeFormatter

/// Formats byte counts into human-readable strings (B, KB, MB, GB).
public enum FileSizeFormatter {

    public static func format(_ bytes: Int64) -> String {
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
    public var badgeLabel: String {
        switch self {
        case .exact: "精确"
        case .prefix: "前缀"
        case .pinyin: "拼音"
        case .substring: "子串"
        }
    }
}
