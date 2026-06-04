import AppKit
import SwiftUI

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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

// MARK: - OnboardingView

/// First-launch onboarding with feature highlights, permissions setup,
/// and a Get Started button to complete onboarding.
struct OnboardingView: View {

    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        GlassEffectContainer(cornerRadius: 24) {
            VStack(spacing: 24) {
                headerSection

                featureCardsSection

                Spacer().frame(height: 4)

                buttonsSection
            }
            .padding(32)
        }
        .frame(width: 480)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(GlowColors.teal)

            Text("Welcome to \(Product.name)")
                .font(.title2)
                .fontWeight(.bold)

            Text("Fast file search for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    // MARK: - Feature Cards

    private var featureCardsSection: some View {
        VStack(spacing: 10) {
            FeatureCard(
                icon: "bolt.fill",
                color: GlowColors.amber,
                title: "Instant Search",
                description: "Find any file instantly across your entire Mac with sub-millisecond search."
            )
            FeatureCard(
                icon: "lock.shield.fill",
                color: GlowColors.teal,
                title: "Privacy-First AI",
                description: "AI features run locally on your device. Your data never leaves your Mac."
            )
            FeatureCard(
                icon: "command",
                color: GlowColors.violet,
                title: "Global Hotkey",
                description: "Press \u{2303}\u{2318}K anytime to open \(Product.name) search, from any application."
            )
        }
    }

    // MARK: - Buttons

    private var buttonsSection: some View {
        VStack(spacing: 10) {
            Button {
                viewModel.openAccessibilitySettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                    Text("Set Up Permissions")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                viewModel.completeOnboarding()
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
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
