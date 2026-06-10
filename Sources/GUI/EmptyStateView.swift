import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - DiagnosticSuggestion

/// A single suggestion row in the empty-state view with diagnostic context.
private struct DiagnosticSuggestion: Identifiable {
    public let text: String
    public let icon: String?
    public let isActionable: Bool  // true = uses brand color, false = uses .quaternary
    public let action: String      // key for dispatch: "openSettings", "checkSpelling", etc.
    public var id: String { text }
}

// MARK: - EmptyStateView

/// Centered empty-state placeholder shown when a search returns no results.
///
/// REQ-3.2-22, REQ-3.2-34: Animated magnifying glass icon, localized "no results"
/// message including the query, and tappable suggestion chips for spelling check,
/// AI semantic search (when enabled), and narrowing scope.
///
/// When **Reduce Motion** is enabled the icon is displayed without animation.
public struct EmptyStateView: View {

    /// The query that produced no results.
    public let query: String

    /// Whether AI semantic search is available. When `true`, an additional
    /// suggestion chip is shown.
    public var hasAIEnabled: Bool = false

    /// Called when the user taps a suggestion chip. The argument is the
    /// suggestion text (used both as label and as a dispatch key).
    public var onSuggestionTap: (String) -> Void = { _ in }

    /// Whether Full Disk Access has been granted. `nil` = unknown/not checked.
    public var fdaGranted: Bool? = nil

    /// Whether the index is currently being built.
    public var isIndexing: Bool = false

    /// Called when the user taps a suggestion that should open settings.
    public var onOpenSettings: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Animation State

    @State private var iconScale: CGFloat = 1.0

    // MARK: - Constants

    private static let animationDuration: Double = 1.5
    private static let scaleTarget: CGFloat = 1.05

    // MARK: - Design Tokens

    private enum Design {
        public static let iconSize: CGFloat = 14
        public static let pillHPadding: CGFloat = 12
        public static let pillVPadding: CGFloat = 6
        public static let pillCornerRadius: CGFloat = 8
        public static let spacing: CGFloat = 8
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

    public var body: some View {
        VStack(spacing: 20) {
            icon

            Text("未找到「\(query)」的匹配文件")
                .font(DeepFinderTypography.heading(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            suggestionsList
        }
        .padding(24)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding(16)
        .shadow(color: GlowColors.teal.opacity(0.12), radius: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startAnimationIfNeeded() }
    }

    // MARK: - Subviews

    private var icon: some View {
        ZStack {
            // Outer gradient ring for layered depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [GlowColors.violet.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 44
                    )
                )
                .frame(width: 88, height: 88)

            // Inner radial gradient for depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [GlowColors.teal.opacity(0.15), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 40
                    )
                )
                .frame(width: 80, height: 80)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [GlowColors.teal, GlowColors.violet],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: GlowColors.teal.opacity(0.2), radius: 8)
                .scaleEffect(iconScale)
        }
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
                        .font(DeepFinderTypography.badge(size: Design.iconSize))
                }
                Text(suggestion.text)
                    .font(DeepFinderTypography.badge(size: 12))
            }
            .foregroundStyle(GlowColors.teal)
            .padding(.horizontal, Design.pillHPadding)
            .padding(.vertical, Design.pillVPadding)
            .background(GlowColors.teal.opacity(0.15), in: Capsule())
            .shadow(color: GlowColors.teal.opacity(0.15), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// Informational pill with subtle left border accent.
    private func informationalPill(_ suggestion: DiagnosticSuggestion) -> some View {
        InformationalPillView(suggestion: suggestion, onTap: onSuggestionTap)
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
            .spring(duration: 1.5, bounce: 0.3)
                .repeatForever(autoreverses: true)
        ) {
            iconScale = Self.scaleTarget
        }
    }
}

// MARK: - InformationalPillView

/// Informational pill with hover scale effect, extracted to support @State.
private struct InformationalPillView: View {
    public let suggestion: DiagnosticSuggestion
    public let onTap: (String) -> Void

    @State private var isHovered = false

    private enum Design {
        public static let pillHPadding: CGFloat = 12
        public static let pillVPadding: CGFloat = 6
    }

    public var body: some View {
        Button {
            onTap(suggestion.text)
        } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(GlowColors.teal.opacity(0.3))
                    .frame(width: 3, height: 14)

                Text(suggestion.text)
                    .font(DeepFinderTypography.badge(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, Design.pillHPadding)
            .padding(.vertical, Design.pillVPadding)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
