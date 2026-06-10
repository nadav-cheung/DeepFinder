import AppKit
import SwiftUI

// MARK: - OnboardingStep

/// Steps in the onboarding flow.
enum OnboardingStep: Int, CaseIterable {
    case welcome
    case features
    case permissions
    case complete
}

// MARK: - OnboardingViewModel

/// View model driving the first-launch onboarding flow.
///
/// Manages the onboarding UI state: permissions setup and completion.
/// Sets `UserDefaults` key `cn.com.nadav.deepfinder.didCompleteOnboarding` when
/// the user finishes onboarding, so subsequent launches skip it.
@MainActor
final class OnboardingViewModel: ObservableObject {

    /// UserDefaults key for tracking whether onboarding was completed.
    static let didCompleteKey = "\(Product.identifier).didCompleteOnboarding"

    /// Check whether onboarding has been completed in a previous launch.
    static var didCompleteOnboarding: Bool {
        UserDefaults.standard.bool(forKey: didCompleteKey)
    }

    /// Called when the onboarding window should be dismissed.
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    /// Mark onboarding as complete, persist to UserDefaults, and dismiss.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
        onDismiss()
    }

    /// Open System Settings > Privacy & Security > Accessibility to allow
    /// the global hotkey to function.
    func openAccessibilitySettings() {
        HotkeyPermissionHelper.openAccessibilitySettings()
    }
}

// MARK: - FeatureCard

/// A single feature highlight card used in the onboarding flow.
private struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    var accentColor: Color? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            if let accentColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3)
            }
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DeepFinderTypography.subheading(size: 14))
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(isHovering ? 0.06 : 0), radius: 8, y: isHovering ? 2 : 0)
        .animation(.easeOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - OnboardingView

/// Multi-step first-launch onboarding with welcome, feature highlights,
/// permissions setup, and completion confirmation.
struct OnboardingView: View {

    @ObservedObject var viewModel: OnboardingViewModel
    @State private var currentStep: OnboardingStep = .welcome
    @State private var isWelcomeIconPulsing = false
    @State private var isCompleteStepVisible = false
    @State private var isNextButtonHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(cornerRadius: 24, glowActive: false) {
            VStack(spacing: 24) {
                stepContent

                stepIndicator

                Spacer().frame(height: 4)

                navigationButtons
            }
            .padding(32)
        }
        .frame(width: 480)
    }

    // MARK: - Step Content

    private var stepTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.95))
    }

    private var stepAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep
                .transition(stepTransition)
        case .features:
            featuresStep
                .transition(stepTransition)
        case .permissions:
            permissionsStep
                .transition(stepTransition)
        case .complete:
            completeStep
                .transition(stepTransition)
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(GlowColors.teal)
                .scaleEffect(isWelcomeIconPulsing ? 1.03 : 1.0)
                .background(
                    ZStack {
                        RadialGradient(
                            colors: [GlowColors.teal.opacity(0.08), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 70
                        )
                        RadialGradient(
                            colors: [GlowColors.teal.opacity(0.2), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 50
                        )
                    }
                    .frame(width: 100, height: 100)
                )
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.spring(duration: 2, bounce: 0.2).repeatForever()) {
                        isWelcomeIconPulsing = true
                    }
                }

            Text("欢迎使用 \(Product.name)")
                .font(DeepFinderTypography.heading(size: 26))

            Text("macOS 快速文件搜索工具")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Features Step

    private var featuresStep: some View {
        VStack(spacing: 10) {
            FeatureCard(
                icon: "bolt.fill",
                color: GlowColors.amber,
                title: "即时搜索",
                description: "毫秒级全盘搜索，瞬间找到任何文件。",
                accentColor: GlowColors.amber
            )
            FeatureCard(
                icon: "lock.shield.fill",
                color: GlowColors.teal,
                title: "隐私优先 AI",
                description: "AI 功能完全在本地运行，数据绝不出设备。",
                accentColor: GlowColors.teal
            )
            FeatureCard(
                icon: "command",
                color: GlowColors.violet,
                title: "全局快捷键",
                description: "按 \u{2303}\u{2318}K 随时唤起搜索，无需切换应用。",
                accentColor: GlowColors.violet
            )
        }
    }

    // MARK: - Permissions Step

    private var permissionsStep: some View {
        PermissionGuideView {
            withAnimation(stepAnimation) {
                currentStep = .complete
            }
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.green)
                .scaleEffect(isCompleteStepVisible ? 1.0 : 0.5)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: isCompleteStepVisible)

            Text("设置完成！")
                .font(DeepFinderTypography.heading(size: 26))

            Text("按 Control+Command+K 开始搜索")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .onAppear {
            guard !reduceMotion else {
                isCompleteStepVisible = true
                return
            }
            isCompleteStepVisible = true
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == currentStep ? AnyShapeStyle(GlowColors.teal) : AnyShapeStyle(.quaternary))
                    .frame(width: step == currentStep ? 8 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: currentStep)
    }

    // MARK: - Navigation

    @ViewBuilder
    private var navigationButtons: some View {
        switch currentStep {
        case .welcome, .features:
            HStack {
                Button("跳过") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)

                Spacer()

                Button("下一步") {
                    withAnimation(stepAnimation) {
                        advanceStep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .brightness(isNextButtonHovering ? 0.08 : 0)
                .animation(.easeOut(duration: 0.15), value: isNextButtonHovering)
                .onHover { hovering in
                    isNextButtonHovering = hovering
                }
            }
        case .permissions:
            // PermissionGuideView handles its own navigation.
            EmptyView()
        case .complete:
            Button {
                viewModel.completeOnboarding()
            } label: {
                Text("开始使用")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Helpers

    private func advanceStep() {
        guard let currentIndex = OnboardingStep.allCases.firstIndex(of: currentStep),
              currentIndex + 1 < OnboardingStep.allCases.count else { return }
        currentStep = OnboardingStep.allCases[currentIndex + 1]
    }
}

// MARK: - OnboardingWindow

/// NSWindow wrapper for the onboarding flow.
///
/// Creates a standalone titled window hosting the ``OnboardingView``.
/// The caller is responsible for positioning and presenting the window.
enum OnboardingWindow {

    /// Create the onboarding NSWindow.
    ///
    /// - Parameter onDismiss: Called when the user taps "Get Started".
    /// - Returns: A configured NSWindow ready to be displayed.
    @MainActor
    static func createWindow(onDismiss: @escaping () -> Void) -> NSWindow {
        let viewModel = OnboardingViewModel(onDismiss: onDismiss)
        let view = OnboardingView(viewModel: viewModel)

        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Product.name) Setup"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()

        return window
    }
}
