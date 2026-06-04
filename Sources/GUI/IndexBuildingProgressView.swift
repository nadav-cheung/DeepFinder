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

    /// Raw daemon state string ("indexing", "verifying", "polling").
    var stateLabel: String = "索引中"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Design Tokens

    private enum Design {
        static let height: CGFloat = 36
        static let iconSize: CGFloat = 14
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

            Text("正在\(stateLabel)... \(filesIndexed) 个文件")
                .font(.system(size: 12))

            Spacer()

            Text("可搜索已索引文件")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, 8)
        .background(GlowColors.teal.opacity(0.06), in: .rect(cornerRadius: Design.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在\(stateLabel)，已完成 \(filesIndexed) 个文件，可以搜索已索引的文件")
    }
}
