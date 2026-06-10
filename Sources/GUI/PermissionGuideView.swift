import SwiftUI

// MARK: - PermissionStep

/// Steps in the permission guide flow.
enum PermissionStep: Int, CaseIterable, Sendable {
    case welcome
    case fda
    case accessibility
    case complete

    var isLast: Bool { self == .complete }
}

// MARK: - PermissionGuideView

/// Multi-step permission guidance view used in onboarding and accessible from Settings.
///
/// Walks the user through:
/// 1. **Welcome** — brief explanation of why permissions are needed.
/// 2. **FDA** (required) — Full Disk Access with real-time status badge.
/// 3. **Accessibility** (optional) — for global hotkey support.
/// 4. **Complete** — confirmation with hotkey reminder.
///
/// Wrapped in `GlassEffectContainer` for visual consistency with the main search panel.
/// Each step uses `GlowColors` brand colors for icons. Real-time permission status
/// updates via `PermissionChecker` polling.
struct PermissionGuideView: View {

    @State private var step: PermissionStep = .welcome
    @State private var fdaGranted: Bool = false
    @State private var axGranted: Bool = false
    @State private var fdaBadgeScale: CGFloat = 1
    @State private var axBadgeScale: CGFloat = 1
    @State private var fdaSettingsHovering: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called when the flow completes (all steps done or skipped).
    var onComplete: () -> Void = {}

    // MARK: - Design Tokens

    private enum Design {
        static let iconSize: CGFloat = 40
        static let stepSpacing: CGFloat = 20
        static let buttonHeight: CGFloat = 44
        static let cornerRadius: CGFloat = 16
        static let statusBadgePadding: CGFloat = 6
    }

    // MARK: - Body

    var body: some View {
        GlassEffectContainer(cornerRadius: 24, glowActive: false) {
            VStack(spacing: Design.stepSpacing) {
                Spacer().frame(height: 8)

                stepContent

                Spacer()

                navigationButtons

                Spacer().frame(height: 8)
            }
            .padding(32)
            .frame(width: 440)
        }
        .onAppear {
            fdaGranted = PermissionChecker.isFDAGranted()
            axGranted = PermissionChecker.isAccessibilityGranted()
        }
        .onChange(of: step) { _, newStep in
            if newStep == .fda {
                startFDAPolling()
            } else if newStep == .accessibility {
                startAXPolling()
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        // Step progress indicator
        stepProgressIndicator

        switch step {
        case .welcome:
            welcomeStep
                .transition(.opacity)
        case .fda:
            fdaStep
                .transition(.opacity)
        case .accessibility:
            axStep
                .transition(.opacity)
        case .complete:
            completeStep
                .transition(.opacity)
        }
    }

    /// Horizontal dots showing which step the user is on.
    private var stepProgressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Array(PermissionStep.allCases.enumerated()), id: \.offset) { index, stepCase in
                Circle()
                    .fill(step == stepCase ? GlowColors.teal : GlowColors.teal.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .animation(DeepFinderMotion.springSnappy, value: step)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(GlowColors.teal)
                .background(
                    Circle()
                        .fill(GlowColors.teal.opacity(0.15))
                        .frame(width: 60, height: 60)
                )

            Text("权限配置")
                .font(DeepFinderTypography.heading(size: 22))

            Text("DeepFinder 在本地建立搜索索引，不上传任何数据。\n以下权限帮助 DeepFinder 更好地为你服务。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - FDA Step

    private var fdaStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(GlowColors.teal)
                .background(
                    Circle()
                        .fill(GlowColors.teal.opacity(0.15))
                        .frame(width: 60, height: 60)
                )

            Text("完全磁盘访问")
                .font(DeepFinderTypography.heading(size: 20))

            Text("完全磁盘访问让 DeepFinder 搜索所有文件和文件夹。所有索引数据完全保留在本机，不上传云端。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("你随时可以在「系统设置 > 隐私与安全 > 完全磁盘访问」中撤销此权限。")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            statusBadge(granted: fdaGranted, label: fdaGranted ? "已授权" : "未授权")

            if !fdaGranted {
                Button {
                    PermissionChecker.openFDASettings()
                } label: {
                    Label("前往系统设置", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(GlowColors.teal.opacity(0.15))
                        .allowsHitTesting(false)
                        .shadow(color: GlowColors.teal.opacity(0.3), radius: 8)
                        .opacity(fdaSettingsHovering ? 1 : 0)
                        .animation(DeepFinderMotion.springSnappy, value: fdaSettingsHovering)
                }
                .onHover { hovering in
                    fdaSettingsHovering = hovering
                }
            }
        }
    }

    // MARK: - Accessibility Step

    private var axStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(GlowColors.violet)
                .background(
                    Circle()
                        .fill(GlowColors.violet.opacity(0.15))
                        .frame(width: 60, height: 60)
                )

            Text("辅助功能权限")
                .font(DeepFinderTypography.heading(size: 20))

            Text("辅助功能权限用于注册全局快捷键（Control+Command+K），让你从任何应用快速唤起搜索。此权限为可选。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            statusBadge(granted: axGranted, label: axGranted ? "已授权" : "未授权")

            if !axGranted {
                Button {
                    PermissionChecker.openAccessibilitySettings()
                } label: {
                    Label("前往系统设置", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(.green)
                .background(
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 60, height: 60)
                )

            Text("设置完成！")
                .font(DeepFinderTypography.heading(size: 20))

            Text("按 Control+Command+K 开始搜索")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private var navigationButtons: some View {
        if step == .complete {
            Button {
                onComplete()
            } label: {
                Text("开始使用")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            HStack(spacing: 12) {
                Button("跳过") {
                    onComplete()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)

                Spacer()

                if step == .fda && !fdaGranted {
                    Button("下一步") {
                        withAnimation(reduceMotion ? nil : DeepFinderMotion.springSnappy) {
                            advanceStep()
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("下一步") {
                        withAnimation(reduceMotion ? nil : DeepFinderMotion.springSnappy) {
                            advanceStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Helpers

    private func advanceStep() {
        guard let currentIndex = PermissionStep.allCases.firstIndex(of: step),
              currentIndex + 1 < PermissionStep.allCases.count else { return }
        step = PermissionStep.allCases[currentIndex + 1]
    }

    private func statusBadge(granted: Bool, label: String) -> some View {
        let currentScale: CGFloat = step == .fda ? fdaBadgeScale : axBadgeScale

        return HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? GlowColors.teal : .red)
                .scaleEffect(currentScale)
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(granted ? GlowColors.teal : .secondary)
        }
        .padding(.horizontal, Design.statusBadgePadding * 2)
        .padding(.vertical, Design.statusBadgePadding)
        .background(
            granted ? GlowColors.teal.opacity(0.12) : Color.red.opacity(0.08),
            in: Capsule()
        )
        .onChange(of: fdaGranted) { _, _ in
            if step == .fda { animateBadgeScale(isFDA: true) }
        }
        .onChange(of: axGranted) { _, _ in
            if step == .accessibility { animateBadgeScale(isFDA: false) }
        }
    }

    private func animateBadgeScale(isFDA: Bool) {
        let bounceScale: CGFloat = 1.25
        if isFDA {
            fdaBadgeScale = bounceScale
        } else {
            axBadgeScale = bounceScale
        }
        withAnimation(DeepFinderMotion.springSnappy) {
            if isFDA {
                fdaBadgeScale = 1.0
            } else {
                axBadgeScale = 1.0
            }
        }
    }

    // MARK: - Permission Polling

    /// Starts polling FDA status so the badge updates in real time when user grants permission.
    private func startFDAPolling() {
        Task { @MainActor in
            for await granted in PermissionChecker.fdaStatusStream(interval: 2) {
                fdaGranted = granted
                if granted { break } // Stop polling once granted.
            }
        }
    }

    /// Starts polling Accessibility status.
    private func startAXPolling() {
        Task { @MainActor in
            for await granted in PermissionChecker.accessibilityStatusStream(interval: 2) {
                axGranted = granted
                if granted { break }
            }
        }
    }
}
