import SwiftUI

// MARK: - FilterType

/// Category filters for search results.
///
/// REQ-3.2-35: Pill-style filter bar with SF Symbol icons and Chinese labels.
/// Each type maps to a search syntax expression for filtering by file extension or type.
enum FilterType: String, CaseIterable, Identifiable, Sendable {
    case documents
    case images
    case code
    case video
    case audio
    case directories

    var id: String { rawValue }

    /// SF Symbol name for the filter icon.
    var systemImage: String {
        switch self {
        case .documents:  return "doc.fill"
        case .images:     return "photo.fill"
        case .code:       return "chevron.left.forwardslash.chevron.right"
        case .video:      return "film.fill"
        case .audio:      return "music.note"
        case .directories: return "folder.fill"
        }
    }

    /// Display label in Chinese.
    var label: String {
        switch self {
        case .documents:  return "文档"
        case .images:     return "图片"
        case .code:       return "代码"
        case .video:      return "视频"
        case .audio:      return "音频"
        case .directories: return "目录"
        }
    }

    /// Search syntax string for this filter (e.g. "ext:pdf,doc,docx").
    func filterSyntax() -> String {
        switch self {
        case .documents:
            return "ext:pdf,doc,docx,txt,rtf,pages,md"
        case .images:
            return "ext:png,jpg,jpeg,gif,svg,tiff,heic,webp"
        case .code:
            return "ext:swift,py,js,ts,html,css,json,yaml,xml,rb,go,rs,c,cpp,h,java,sh"
        case .video:
            return "ext:mp4,mov,avi,mkv"
        case .audio:
            return "ext:mp3,wav,aac,flac,aiff,m4a"
        case .directories:
            return "type:dir"
        }
    }
}

// MARK: - FilterPill

/// A single filter pill view used inside SearchFilterBar.
///
/// Not intended for standalone use — rendered by `SearchFilterBar`.
struct FilterPill: Identifiable {
    let type: FilterType
    var id: String { type.rawValue }
}

// MARK: - SearchFilterBar

/// Horizontal scrollable filter bar with toggle-able category pills.
///
/// REQ-3.2-35: ScrollView(.horizontal) with capsule-shaped pills. Active pills
/// use `.tint` background, inactive use `.quaternary`. Tapping toggles membership
/// in the `activeFilters` set. Each pill shows an SF Symbol icon + Chinese label.
struct SearchFilterBar: View {

    /// Currently active filters, bound to the parent view.
    @Binding var activeFilters: Set<FilterType>

    /// All available filter pills.
    private let pills = FilterType.allCases.map { FilterPill(type: $0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pills) { pill in
                    pillButton(for: pill.type)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Pill Button

    private func pillButton(for type: FilterType) -> some View {
        FilterPillButton(
            type: type,
            isActive: activeFilters.contains(type),
            toggle: {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    if activeFilters.contains(type) {
                        activeFilters.remove(type)
                    } else {
                        activeFilters.insert(type)
                    }
                }
            }
        )
    }
}

// MARK: - FilterPillButton

/// Individual pill button with hover state tracking.
private struct FilterPillButton: View {
    let type: FilterType
    let isActive: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: type.systemImage)
                    .font(.system(size: 12))

                Text(type.label)
                    .font(.system(size: 12))
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(isHovered ? 0.7 : 1.0)),
                in: .capsule
            )
            .shadow(color: isActive ? Color.accentColor.opacity(0.2) : .clear, radius: 3, y: 1)
            .foregroundStyle(isActive ? .white : .primary)
            .animation(.spring(duration: 0.2, bounce: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(type.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
