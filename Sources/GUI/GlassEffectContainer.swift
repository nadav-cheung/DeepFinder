import SwiftUI

// MARK: - GlassEffectContainer

/// Wraps content with Liquid Glass material and an Intelligence Glow border overlay.
///
/// Combines `.glassEffect(.regular)` with `IntelligenceGlow` to produce the
/// signature DeepFinder search panel appearance: frosted glass with a slowly
/// rotating, color-cycling outline.
///
/// When Reduce Motion is enabled, the glow border is static (no rotation,
/// no opacity pulsing).
struct GlassEffectContainer<Content: View>: View {

    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = 24,
        borderWidth: CGFloat = 2,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.content = content
    }

    var body: some View {
        content()
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                IntelligenceGlow(
                    cornerRadius: cornerRadius,
                    borderWidth: borderWidth
                )
                .allowsHitTesting(false)
            }
    }
}
