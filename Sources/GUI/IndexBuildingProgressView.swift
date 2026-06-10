import SwiftUI

// MARK: - IndexBuildingProgressView

/// Compact inline progress indicator shown while the daemon is building or verifying the index.
///
/// Displays an animated spinner + file count + subtitle hinting that search is already
/// available for indexed files. Uses `GlowColors.teal` for the spinner tint.
///
/// Placed in `SearchPanelView` (between filter bar and content area) and in
/// `OnboardingView` during the indexing step.
struct IndexBuildingProgressView: View {

    /// Number of files indexed so far.
    let filesIndexed: Int

    /// Estimated seconds remaining. When non-nil, an ETA suffix is appended to the file count.
    /// The view does NOT calculate ETA — the caller provides it.
    var estimatedSeconds: Int? = nil

    /// Raw daemon state string ("indexing", "verifying", "polling").
    var stateLabel: String = "索引中"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared: Bool = false

    // MARK: - Design Tokens

    private enum Design {
        static let height: CGFloat = 36
        static let iconSize: CGFloat = 16
        static let cornerRadius: CGFloat = 8
        static let hPadding: CGFloat = 12
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: Design.iconSize))
                    .foregroundStyle(GlowColors.teal)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(GlowColors.teal)
            }

            Text("正在\(stateLabel)... \(filesIndexed.formatted()) 个文件\(etaSuffix.isEmpty ? "" : " \(etaSuffix)")")
                .font(.system(size: 12))
                .contentTransition(.numericText())

            Spacer()

            Text("可搜索已索引文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, 8)
        .background(GlowColors.teal.opacity(0.06), in: .rect(cornerRadius: Design.cornerRadius))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(DeepFinderMotion.springSmooth) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityProgressText)
    }

    // MARK: - Formatted Text

    /// ETA suffix string, empty when no estimate available.
    private var etaSuffix: String {
        guard let eta = estimatedSeconds else { return "" }
        return " · 预计剩余 \(formatETA(eta))"
    }

    /// Accessibility label mirrors the visual text.
    private var accessibilityProgressText: String {
        var text = "正在\(stateLabel)，已完成 \(filesIndexed) 个文件，可以搜索已索引的文件"
        if let eta = estimatedSeconds {
            text += "，预计剩余 \(formatETA(eta))"
        }
        return text
    }

    /// Formats seconds into a human-readable Chinese string.
    /// - <60s: "15s"
    /// - 60-120s: "1分15s"
    /// - >120s: "3分"
    private func formatETA(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 1 {
            return "1分\(remainder)s"
        }
        return "\(minutes)分"
    }
}
