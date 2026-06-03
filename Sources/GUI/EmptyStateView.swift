import SwiftUI

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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Animation State

    @State private var iconScale: CGFloat = 1.0

    // MARK: - Constants

    private static let animationDuration: Double = 1.5
    private static let scaleTarget: CGFloat = 1.05

    // MARK: - Suggestions

    /// Static suggestion rows. The AI entry is conditionally included.
    private var suggestions: [String] {
        var items = ["检查拼写是否正确"]
        if hasAIEnabled {
            items.append("使用 AI 语义搜索")
        }
        items.append("缩小搜索范围")
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
        VStack(spacing: 8) {
            ForEach(suggestions, id: \.self) { text in
                Button {
                    onSuggestionTap(text)
                } label: {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
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
