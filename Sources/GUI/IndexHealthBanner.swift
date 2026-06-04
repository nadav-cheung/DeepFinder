import SwiftUI

// MARK: - IndexHealthBanner

/// Non-modal warning banner for degraded index health.
///
/// "Conspicuous but not disruptive" — shown inline in the search panel when
/// index health is degraded (FDA missing, daemon disconnected, stale index).
/// Persistent but dismissible per session. Does NOT block interaction with results.
///
/// Placed in `SearchPanelView` between the filter bar and the content area.
struct IndexHealthBanner: View {

    let healthState: IndexHealthState

    /// Called when the user taps the "前往设置" button.
    var onOpenSettings: () -> Void = {}

    @State private var isDismissed: Bool = false

    // MARK: - Design Tokens

    private enum Design {
        static let cornerRadius: CGFloat = 8
        static let hPadding: CGFloat = 12
        static let iconSize: CGFloat = 14
    }

    // MARK: - Body

    var body: some View {
        if !isDismissed, case .degraded(let reason) = healthState {
            bannerContent(reason: reason)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Content

    private func bannerContent(reason: DegradationReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Design.iconSize))
                .foregroundStyle(.orange)

            Text(message(for: reason))
                .font(.system(size: 12))
                .lineLimit(2)

            Spacer()

            Button {
                onOpenSettings()
            } label: {
                Text("前往设置")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭警告")
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Design.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage(for: reason))
        .accessibilityHint("双击打开设置")
    }

    // MARK: - Helpers

    private func message(for reason: DegradationReason) -> String {
        switch reason {
        case .fdaMissing:
            return "完全磁盘访问权限未启用，部分文件可能无法搜索"
        case .daemonDisconnected:
            return "搜索服务未连接"
        case .indexStale:
            return "索引可能不是最新"
        }
    }

    private func accessibilityMessage(for reason: DegradationReason) -> String {
        switch reason {
        case .fdaMissing:
            return "警告：完全磁盘访问权限未启用，部分文件可能无法搜索。前往设置修复。"
        case .daemonDisconnected:
            return "警告：搜索服务未连接。前往设置查看。"
        case .indexStale:
            return "警告：索引可能不是最新。前往设置重建索引。"
        }
    }
}
