import SwiftUI

// MARK: - DiagnosticSuggestion

/// A single suggestion row in the empty-state view with diagnostic context.
private struct DiagnosticSuggestion: Identifiable {
    let text: String
    let icon: String?
    let isActionable: Bool  // true = uses brand color, false = uses .quaternary
    let action: String      // key for dispatch: "openSettings", "checkSpelling", etc.
    var id: String { text }
}

// MARK: - EmptyStateView

/// Centered empty-state placeholder shown when a search returns no results.
///
/// REQ-3.2-22, REQ-3.2-34: Animated magnifying glass icon, localized "no results"
/// message including the query, and tappable suggestion chips for spelling check,
/// AI semantic search (when enabled), and narrowing scope.
///
/// When **Reduce Motion** is enabled the icon is displayed without animation.
struct EmptyStateView: View {

    /// The query that produced no results.
    let query: String

    /// Whether AI semantic search is available. When `true`, an additional
    /// suggestion chip is shown.
    var hasAIEnabled: Bool = false

    /// Called when the user taps a suggestion chip. The argument is the
    /// suggestion text (used both as label and as a dispatch key).
    var onSuggestionTap: (String) -> Void = { _ in }

    /// Whether Full Disk Access has been granted. `nil` = unknown/not checked.
    var fdaGranted: Bool? = nil

    /// Whether the index is currently being built.
    var isIndexing: Bool = false

    /// Called when the user taps a suggestion that should open settings.
    var onOpenSettings: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Animation State

    @State private var iconScale: CGFloat = 1.0

    // MARK: - Constants

    private static let animationDuration: Double = 1.5
    private static let scaleTarget: CGFloat = 1.05

    // MARK: - Design Tokens

    private enum Design {
        static let iconSize: CGFloat = 14
        static let pillHPadding: CGFloat = 12
        static let pillVPadding: CGFloat = 6
        static let pillCornerRadius: CGFloat = 8
        static let spacing: CGFloat = 8
    }

    // MARK: - Suggestions

    /// Dynamic suggestion rows built from diagnostic context.
    private var suggestions: [DiagnosticSuggestion] {
        var items: [DiagnosticSuggestion] = []

        if fdaGranted == false {
            items.append(DiagnosticSuggestion(
                text: "完全磁盘访问未启用",
                icon: "shield.fill",
                isActionable: true,
                action: "openSettings"
            ))
        }

        if isIndexing {
            items.append(DiagnosticSuggestion(
                text: "索引正在构建中",
                icon: "arrow.triangle.2.circlepath",
                isActionable: false,
                action: "indexing"
            ))
        }

        items.append(DiagnosticSuggestion(
            text: "检查拼写是否正确",
            icon: nil,
            isActionable: false,
            action: "checkSpelling"
        ))

        if hasAIEnabled {
            items.append(DiagnosticSuggestion(
                text: "使用 AI 语义搜索",
                icon: nil,
                isActionable: false,
                action: "aiSearch"
            ))
        }

        items.append(DiagnosticSuggestion(
            text: "缩小搜索范围",
            icon: nil,
            isActionable: false,
            action: "narrowScope"
        ))

        return items
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            icon

            Text("未找到「\(query)」的匹配文件")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            suggestionsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startAnimationIfNeeded() }
    }

    // MARK: - Subviews

    private var icon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 32))
            .foregroundStyle(.tertiary)
            .scaleEffect(iconScale)
    }

    private var suggestionsList: some View {
        VStack(spacing: Design.spacing) {
            ForEach(suggestions) { suggestion in
                if suggestion.isActionable {
                    actionablePill(suggestion)
                } else {
                    informationalPill(suggestion)
                }
            }
        }
    }

    /// Diagnostic/actionable pill with brand color background and optional icon.
    private func actionablePill(_ suggestion: DiagnosticSuggestion) -> some View {
        Button {
            dispatch(suggestion)
        } label: {
            HStack(spacing: 4) {
                if let icon = suggestion.icon {
                    Image(systemName: icon)
                        .font(.system(size: Design.iconSize))
                }
                Text(suggestion.text)
                    .font(.system(size: 12))
            }
            .foregroundStyle(GlowColors.teal)
            .padding(.horizontal, Design.pillHPadding)
            .padding(.vertical, Design.pillVPadding)
            .background(GlowColors.teal.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Informational pill with default quaternary style.
    private func informationalPill(_ suggestion: DiagnosticSuggestion) -> some View {
        Button {
            onSuggestionTap(suggestion.text)
        } label: {
            Text(suggestion.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Design.pillHPadding)
                .padding(.vertical, Design.pillVPadding)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dispatch

    /// Routes a suggestion tap to the appropriate handler.
    private func dispatch(_ suggestion: DiagnosticSuggestion) {
        switch suggestion.action {
        case "openSettings":
            onOpenSettings?()
        default:
            onSuggestionTap(suggestion.text)
        }
    }

    // MARK: - Animation

    /// Starts the breathing scale animation unless Reduce Motion is active.
    private func startAnimationIfNeeded() {
        guard !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: Self.animationDuration)
                .repeatForever(autoreverses: true)
        ) {
            iconScale = Self.scaleTarget
        }
    }
}
