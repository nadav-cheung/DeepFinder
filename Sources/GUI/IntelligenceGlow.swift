import SwiftUI

// MARK: - Glow Colors

/// The four colors used by the Intelligence Glow animation.
///
/// Fixed palette: teal, violet, coral, amber — matching the spec's Apple Intelligence
/// aesthetic. Defined as static constants so tests can verify them without constructing views.
enum GlowColors {
    static let teal = Color(red: 0x00 / 255, green: 0xC9 / 255, blue: 0xA7 / 255)
    static let violet = Color(red: 0x84 / 255, green: 0x5E / 255, blue: 0xC2 / 255)
    static let coral = Color(red: 0xFF / 255, green: 0x6F / 255, blue: 0x91 / 255)
    static let amber = Color(red: 0xFF / 255, green: 0xC7 / 255, blue: 0x5F / 255)
}

// MARK: - IntelligenceGlow

/// A rotating, color-cycling glow effect inspired by Apple Intelligence.
///
/// Renders an `AngularGradient` with four colors (teal, violet, coral, amber)
/// that rotates continuously at ~1.8 s per revolution. Opacity pulses subtly
/// on a 3 s cycle (0.6 to 1.0 and back). Respects the system Reduce Motion
/// preference: when enabled, the gradient is static and opacity is fixed at 0.8.
///
/// Intended as an overlay or border around the search panel — never as a
/// standalone view. Use `GlassEffectContainer` for the complete wrapper.
struct IntelligenceGlow: View {

    /// Corner radius matching the panel's Liquid Glass shape.
    let cornerRadius: CGFloat

    /// Border stroke width.
    let borderWidth: CGFloat

    @State private var rotation: Double = 0
    @State private var glowOpacity: Double = 0.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(cornerRadius: CGFloat = 24, borderWidth: CGFloat = 2) {
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
    }

    var body: some View {
        let gradient = AngularGradient(
            colors: [
                GlowColors.teal,
                GlowColors.violet,
                GlowColors.coral,
                GlowColors.amber,
                GlowColors.teal,  // seamless loop
            ],
            center: .center,
            startAngle: .degrees(rotation),
            endAngle: .degrees(rotation + 360)
        )

        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(gradient, lineWidth: borderWidth)
            .opacity(reduceMotion ? 0.8 : glowOpacity)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: 1.8)
                    .repeatForever(autoreverses: false)
                ) {
                    rotation = 360
                }
                withAnimation(
                    .easeInOut(duration: 3.0)
                    .repeatForever(autoreverses: true)
                ) {
                    glowOpacity = 1.0
                }
            }
    }
}
