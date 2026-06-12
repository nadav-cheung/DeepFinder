// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 nadav.com.cn

import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - IndexHealthBanner

/// Non-modal warning banner for degraded index health.
///
/// "Conspicuous but not disruptive" — shown inline in the search panel when
/// index health is degraded (FDA missing, daemon disconnected, stale index).
/// Persistent but dismissible per session. Does NOT block interaction with results.
///
/// Placed in `SearchPanelView` between the filter bar and the content area.
public struct IndexHealthBanner: View {

    public let healthState: IndexHealthState

    /// Called when the user taps the "前往设置" button.
    public var onOpenSettings: () -> Void = {}

    @State private var isDismissed: Bool = false
    @State private var dismissHovering: Bool = false

    // MARK: - Design Tokens

    private enum Design {
        public static let cornerRadius: CGFloat = 8
        public static let hPadding: CGFloat = 12
        public static let iconSize: CGFloat = 14
    }

    // MARK: - Body

    public var body: some View {
        if !isDismissed, case .degraded(let reason) = healthState {
            bannerContent(reason: reason)
                .transition(.opacity.combined(with: .move(edge: .top)).animation(.spring(duration: 0.3, bounce: 0.15)))
        }
    }

    // MARK: - Content

    private func bannerContent(reason: DegradationReason) -> some View {
        HStack(spacing: 8) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(.orange)
                .frame(width: 3)
                .padding(.vertical, 2)

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

            dismissButton
        }
        .padding(.horizontal, Design.hPadding)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Design.cornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityMessage(for: reason))
        .accessibilityHint("双击打开设置")
    }

    // MARK: - Dismiss Button

    private var dismissButton: some View {
        Button {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
                isDismissed = true
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10))
                .foregroundStyle(dismissHovering ? .secondary : .tertiary)
                .padding(4)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(dismissHovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(duration: 0.2, bounce: 0.1)) {
                dismissHovering = hovering
            }
        }
        .accessibilityLabel("关闭警告")
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
