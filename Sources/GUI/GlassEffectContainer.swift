import SwiftUI

// MARK: - GlassIntensity

/// Configurable intensity levels for Liquid Glass material.
///
/// Maps to the built-in `Glass` variants used by `.glassEffect()`:
/// - `regular`: standard Liquid Glass appearance (default).
/// - `clear`: more translucent, minimal glass frosting.
/// - `identity`: no glass effect — content is rendered unmodified.
enum GlassIntensity {
    case regular
    case clear
    case identity
}

// MARK: - GlassEffectContainer

/// Wraps content with Liquid Glass material and an optional Intelligence Glow border overlay.
///
/// Combines `.glassEffect()` with ``IntelligenceGlow`` to produce the
/// signature DeepFinder search panel appearance: frosted glass with a slowly
/// rotating, color-cycling outline.
///
/// When **Reduce Motion** is enabled, the glow border is static (no rotation,
/// no opacity pulsing). When **High Contrast** is enabled, the border stroke
/// is drawn thicker for visibility.
///
/// Usage:
/// ```swift
/// GlassEffectContainer(intensity: .regular, cornerRadius: 24) {
///     Text("Hello")
/// }
/// ```
struct GlassEffectContainer<Content: View>: View {

    /// Glass material intensity.
    private let intensity: GlassIntensity

    /// Corner radius for the glass shape and glow overlay.
    private let cornerRadius: CGFloat

    /// Stroke width of the Intelligence Glow border. Pass `nil` to disable the glow.
    private let borderWidth: CGFloat?

    /// Whether the glow is in its active (focused) state.
    private let glowActive: Bool

    @ViewBuilder private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Creates a glass effect container.
    ///
    /// - Parameters:
    ///   - intensity: Glass material thickness. Defaults to `.regular`.
    ///   - cornerRadius: Corner radius of the glass shape. Defaults to `24`.
    ///   - borderWidth: Stroke width of the glow border. Pass `nil` to skip the glow entirely. Defaults to `2`.
    ///   - glowActive: Whether the glow is active (focused). Defaults to `true`.
    ///   - content: The view content to wrap.
    init(
        intensity: GlassIntensity = .regular,
        cornerRadius: CGFloat = 24,
        borderWidth: CGFloat? = 2,
        glowActive: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.intensity = intensity
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.glowActive = glowActive
        self.content = content
    }

    var body: some View {
        content()
            .glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                if let borderWidth {
                    let effectiveWidth = highContrastBoost(borderWidth)
                    IntelligenceGlow(
                        isActive: glowActive,
                        cornerRadius: cornerRadius,
                        borderWidth: effectiveWidth
                    )
                    .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Internal Helpers

    /// Maps `GlassIntensity` to the SwiftUI `Glass` variant used by `.glassEffect()`.
    private var glassVariant: Glass {
        switch intensity {
        case .regular: return .regular
        case .clear:   return .clear
        case .identity: return .identity
        }
    }

    /// Increases border width under high contrast to improve visibility.
    private func highContrastBoost(_ width: CGFloat) -> CGFloat {
        colorSchemeContrast == .increased ? width * 1.5 : width
    }
}
