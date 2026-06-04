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
        switch step {
        case .welcome:
            welcomeStep
        case .fda:
            fdaStep
        case .accessibility:
            axStep
        case .complete:
            completeStep
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(GlowColors.teal)

            Text("权限配置")
                .font(.title2)
                .fontWeight(.bold)

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

            Text("完全磁盘访问")
                .font(.title3)
                .fontWeight(.bold)

            Text("完全磁盘访问让 DeepFinder 搜索所有文件和文件夹。所有索引数据完全保留在本机，不上传云端。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
            }
        }
    }

    // MARK: - Accessibility Step

    private var axStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard")
                .font(.system(size: Design.iconSize, weight: .medium))
                .foregroundStyle(GlowColors.violet)

            Text("辅助功能权限")
                .font(.title3)
                .fontWeight(.bold)

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

            Text("设置完成！")
                .font(.title3)
                .fontWeight(.bold)

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
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            advanceStep()
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("下一步") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
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
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(label)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(granted ? .green : .secondary)
        }
        .padding(.horizontal, Design.statusBadgePadding * 2)
        .padding(.vertical, Design.statusBadgePadding)
        .background(
            granted ? Color.green.opacity(0.12) : Color.red.opacity(0.08),
            in: Capsule()
        )
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
