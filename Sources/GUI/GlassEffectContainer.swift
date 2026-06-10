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

    /// Whether to add a subtle vignette texture overlay to break the flat glass look.
    private let showTexture: Bool

    /// Whether to add inner shadow depth effects (inner light edge + top highlight).
    private let innerShadow: Bool

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
    ///   - showTexture: Whether to add a subtle vignette overlay. Defaults to `false`.
    ///   - innerShadow: Whether to add inner shadow depth (light edge + top highlight). Defaults to `false`.
    ///   - content: The view content to wrap.
    init(
        intensity: GlassIntensity = .regular,
        cornerRadius: CGFloat = 24,
        borderWidth: CGFloat? = 2,
        glowActive: Bool = true,
        showTexture: Bool = false,
        innerShadow: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.intensity = intensity
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.glowActive = glowActive
        self.showTexture = showTexture
        self.innerShadow = innerShadow
        self.content = content
    }

    var body: some View {
        content()
            .glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
            .overlay {
                if showTexture {
                    // Subtle vignette at edges — barely perceptible, breaks the flat glass look.
                    RadialGradient(
                        colors: [.clear, .black.opacity(0.05)],
                        center: .center,
                        startRadius: cornerRadius,
                        endRadius: 300
                    )
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
                    .blendMode(.multiply)
                }
            }
            .overlay {
                if innerShadow {
                    // Inner light edge — gives the glass "thickness".
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if innerShadow {
                    // Top highlight — subtle "light from above" on the glass surface.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .frame(height: cornerRadius)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
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
