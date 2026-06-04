import SwiftUI

// MARK: - FeatureTip

/// A feature discovery tip shown to the user in the search panel idle state.
///
/// Each tip highlights an advanced capability the user may not know about.
/// Tips rotate on each panel open and are individually dismissible.
enum FeatureTip: String, CaseIterable, Identifiable, Sendable {
    case nlSearch
    case voiceInput
    case filterBar
    case quickLook
    case contentSearch

    var id: String { rawValue }

    /// SF Symbol icon for the tip.
    var icon: String {
        switch self {
        case .nlSearch:       return "text.bubble.fill"
        case .voiceInput:     return "mic.fill"
        case .filterBar:      return "line.3.horizontal.decrease.circle.fill"
        case .quickLook:      return "eye.fill"
        case .contentSearch:  return "doc.text.magnifyingglass"
        }
    }

    /// Chinese description text.
    var text: String {
        switch self {
        case .nlSearch:       return "试试自然语言搜索：「上个月修改的 PDF」"
        case .voiceInput:     return "点击麦克风按钮使用语音搜索"
        case .filterBar:      return "使用筛选栏按文件类型过滤结果"
        case .quickLook:      return "按 Space 快速预览文件"
        case .contentSearch:  return "搜索文件内容：使用 content:关键词"
        }
    }

    /// Brand color for the tip icon.
    var color: Color {
        switch self {
        case .nlSearch:       return GlowColors.coral
        case .voiceInput:     return GlowColors.violet
        case .filterBar:      return GlowColors.teal
        case .quickLook:      return GlowColors.amber
        case .contentSearch:  return GlowColors.teal
        }
    }

    /// UserDefaults key for tracking dismissal.
    var dismissedKey: String {
        "\(Product.identifier).dismissedTip.\(rawValue)"
    }

    /// Whether this tip has been dismissed by the user.
    var isDismissed: Bool {
        UserDefaults.standard.bool(forKey: dismissedKey)
    }

    /// Mark this tip as dismissed.
    func dismiss() {
        UserDefaults.standard.set(true, forKey: dismissedKey)
    }

    /// All tips that haven't been dismissed yet.
    static var undismissed: [FeatureTip] {
        allCases.filter { !$0.isDismissed }
    }
}

// MARK: - FeatureDiscoveryTipCard

/// Lightweight inline tip card shown in the search panel idle state.
///
/// Displays a single `FeatureTip` with an icon, text, and dismiss button.
/// Rotates tips on each panel open. Once all tips are dismissed, no card is shown.
struct FeatureDiscoveryTipCard: View {

    /// The tip to display.
    let tip: FeatureTip

    /// Called when the user dismisses the tip.
    var onDismiss: () -> Void = {}

    // MARK: - Design Tokens

    private enum Design {
        static let cornerRadius: CGFloat = 8
        static let hPadding: CGFloat = 12
        static let vPadding: CGFloat = 8
        static let iconSize: CGFloat = 14
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tip.icon)
                .font(.system(size: Design.iconSize))
                .foregroundStyle(tip.color)

            Text(tip.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                tip.dismiss()
                withAnimation(.easeInOut(duration: 0.2)) {
                    onDismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, Design.vPadding)
        .background(tip.color.opacity(0.08), in: .rect(cornerRadius: Design.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tip.text)
        .accessibilityHint("双击关闭提示")
    }
}
