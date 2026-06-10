import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - Glow Colors

/// The four colors used by the Intelligence Glow animation.
///
/// Fixed palette: teal, violet, coral, amber — matching the spec's Apple Intelligence
/// aesthetic. Defined as static constants so tests can verify them without constructing views.
public enum GlowColors {
    public static let teal   = Color(red: 0x00 / 255, green: 0xC9 / 255, blue: 0xA7 / 255)
    public static let violet = Color(red: 0x84 / 255, green: 0x5E / 255, blue: 0xC2 / 255)
    public static let coral  = Color(red: 0xFF / 255, green: 0x6F / 255, blue: 0x91 / 255)
    public static let amber  = Color(red: 0xFF / 255, green: 0xC7 / 255, blue: 0x5F / 255)

    /// Eight interpolated color stops for smoother gradients.
    ///
    /// Returns the 4 base colors plus 4 midpoints, where each midpoint is the
    /// per-channel RGB average of its two adjacent base colors:
    /// `[teal, teal+vi, violet, violet+co, coral, coral+am, amber, amber+te]`
    public static func interpolatedColors() -> [Color] {
        return [
            teal,
            average(teal, violet),
            violet,
            average(violet, coral),
            coral,
            average(coral, amber),
            amber,
            average(amber, teal),
        ]
    }

    /// Perceptual average of two colors by averaging RGB channels.
    private static func average(_ a: Color, _ b: Color) -> Color {
        let ar = a.components
        let br = b.components
        return Color(
            red: (ar.red + br.red) / 2,
            green: (ar.green + br.green) / 2,
            blue: (ar.blue + br.blue) / 2
        )
    }
}

// MARK: - Color RGB extraction

private extension Color {
    /// RGB components in the [0, 1] range.
    ///
    /// Uses `NSColor` conversion for reliable channel extraction on macOS.
    public struct RGBA { var red, green, blue: Double }

    public var components: RGBA {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RGBA(red: Double(ns.redComponent),
                    green: Double(ns.greenComponent),
                    blue: Double(ns.blueComponent))
    }
}

// MARK: - GlowLayer configuration

/// Describes one visual layer of the 4-layer glow effect.
private struct GlowLayerConfig {
    public let lineWidth: CGFloat
    public let blur: CGFloat
    public let rotationDuration: Double
    public let clockwise: Bool
    public let activeOpacity: Double
}

// MARK: - IntelligenceGlow

/// A rotating, color-cycling glow effect inspired by Apple Intelligence.
///
/// Renders **four overlapping** `AngularGradient` stroke layers, each rotating at a
/// different speed and direction, with increasing blur to create a depth-faded bloom
/// effect. The layers are:
///
/// 1. **Sharp Core** — thin, no blur, fastest rotation.
/// 2. **Soft Inner** — slightly thicker, light blur, counter-rotating.
/// 3. **Medium Glow** — thicker still, heavier blur, slow rotation.
/// 4. **Bloom** — thickest, heaviest blur, slowest counter-rotation + subtle pulse.
///
/// When `isActive` is true, all layers animate. When inactive, opacity is reduced and
/// all rotation halts. Respects the system Reduce Motion preference.
///
/// Intended as an overlay or border around the search panel — never as a standalone
/// view. Use ``GlassEffectContainer`` for the complete wrapper.
public struct IntelligenceGlow: View {

    /// Whether the glow is active (focused) or inactive (idle).
    public let isActive: Bool

    /// Corner radius matching the panel's Liquid Glass shape.
    public let cornerRadius: CGFloat

    /// Border stroke width (applied to the sharpest core layer).
    public let borderWidth: CGFloat

    // Four independent rotation angles — one per layer.
    @State private var rotation1: Double = 0
    @State private var rotation2: Double = 0
    @State private var rotation3: Double = 0
    @State private var rotation4: Double = 0

    /// Subtle opacity pulse for the bloom layer (active state only).
    @State private var bloomPulse: Double = 0.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates an Intelligence Glow overlay.
    ///
    /// - Parameters:
    ///   - isActive: Whether the glow should animate actively. Defaults to `true`.
    ///   - cornerRadius: Corner radius of the glow shape. Defaults to `24`.
    ///   - borderWidth: Stroke width of the core glow border. Defaults to `2`.
    public init(
        isActive: Bool = true,
        cornerRadius: CGFloat = 24,
        borderWidth: CGFloat = 2
    ) {
        self.isActive = isActive
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
    }

    // MARK: - Layer definitions

    /// Fixed configuration for the four glow layers.
    private static let layerConfigs: [GlowLayerConfig] = [
        GlowLayerConfig(lineWidth: 2,  blur: 0,  rotationDuration: 1.8, clockwise: true,  activeOpacity: 0.8),
        GlowLayerConfig(lineWidth: 4,  blur: 3,  rotationDuration: 2.4, clockwise: false, activeOpacity: 0.8),
        GlowLayerConfig(lineWidth: 6,  blur: 8,  rotationDuration: 3.2, clockwise: true,  activeOpacity: 0.8),
        GlowLayerConfig(lineWidth: 10, blur: 16, rotationDuration: 4.0, clockwise: false, activeOpacity: 0.4),
    ]

    // MARK: - Body

    public var body: some View {
        let colors = GlowColors.interpolatedColors()
        // Prepend the first color at the end for a seamless loop (9 stops total).
        let gradientColors = colors + [colors[0]]

        let averageGlow = averageGlowColor(colors: colors)

        ZStack {
            layerView(
                config: Self.layerConfigs[0],
                rotation: rotation1,
                gradientColors: gradientColors
            )
            layerView(
                config: Self.layerConfigs[1],
                rotation: rotation2,
                gradientColors: gradientColors
            )
            layerView(
                config: Self.layerConfigs[2],
                rotation: rotation3,
                gradientColors: gradientColors
            )
            // Layer 4 (bloom): opacity pulses in active state.
            layerView(
                config: Self.layerConfigs[3],
                rotation: rotation4,
                gradientColors: gradientColors
            )
            .opacity(layer4Opacity)
        }
        .shadow(color: averageGlow.opacity(0.15), radius: 12)
        .onAppear { startAnimations() }
        .onChange(of: isActive) { _, newValue in
            reactivateAnimations(active: newValue)
        }
    }

    // MARK: - Layer View

    /// Builds a single RoundedRectangle stroke layer with gradient + blur + opacity.
    private func layerView(
        config: GlowLayerConfig,
        rotation: Double,
        gradientColors: [Color]
    ) -> some View {
        let gradient = AngularGradient(
            colors: gradientColors,
            center: .center,
            startAngle: .degrees(rotation),
            endAngle: .degrees(rotation + 360)
        )

        return RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(gradient, lineWidth: config.lineWidth)
            .blur(radius: config.blur)
            .opacity(resolvedLayerOpacity(config.activeOpacity))
    }

    // MARK: - Opacity

    /// Resolved opacity for layers 1-3 based on active state and accessibility.
    private func resolvedLayerOpacity(_ baseActiveOpacity: Double) -> Double {
        if reduceMotion {
            return isActive ? baseActiveOpacity : 0.3
        }
        return isActive ? baseActiveOpacity : 0.3
    }

    /// Layer 4 (bloom) has a subtle pulse in active state (0.3 — 0.5).
    private var layer4Opacity: Double {
        if reduceMotion {
            return isActive ? 0.4 : 0.3
        }
        if !isActive {
            return 0.3
        }
        return bloomPulse
    }

    /// Computes an average glow color from the interpolated stops for the inner shadow.
    private func averageGlowColor(colors: [Color]) -> Color {
        let comps = colors.map { $0.components }
        let count = Double(comps.count)
        return Color(
            red: comps.reduce(0) { $0 + $1.red } / count,
            green: comps.reduce(0) { $0 + $1.green } / count,
            blue: comps.reduce(0) { $0 + $1.blue } / count
        )
    }

    // MARK: - Animation Lifecycle

    /// Starts all layer animations on first appear.
    private func startAnimations() {
        guard isActive && !reduceMotion else { return }
        animateLayer1()
        animateLayer2()
        animateLayer3()
        animateLayer4()
        animateBloomPulse()
    }

    /// Re-applies or cancels animations when `isActive` changes.
    private func reactivateAnimations(active: Bool) {
        if active && !reduceMotion {
            animateLayer1()
            animateLayer2()
            animateLayer3()
            animateLayer4()
            animateBloomPulse()
        } else {
            // Transition to inactive: ease out all rotation to current position.
            withAnimation(.easeOut(duration: 0.3)) {
                rotation1 = rotation1.truncatingRemainder(dividingBy: 360)
                rotation2 = rotation2.truncatingRemainder(dividingBy: 360)
                rotation3 = rotation3.truncatingRemainder(dividingBy: 360)
                rotation4 = rotation4.truncatingRemainder(dividingBy: 360)
                bloomPulse = 0.3
            }
        }
    }

    // MARK: - Per-Layer Animations

    /// Layer 1 — Sharp Core: 1.8s clockwise.
    private func animateLayer1() {
        withAnimation(
            .linear(duration: 1.8)
            .repeatForever(autoreverses: false)
        ) {
            rotation1 = 360
        }
    }

    /// Layer 2 — Soft Inner: 2.4s counter-clockwise.
    private func animateLayer2() {
        withAnimation(
            .linear(duration: 2.4)
            .repeatForever(autoreverses: false)
        ) {
            rotation2 = -360
        }
    }

    /// Layer 3 — Medium Glow: 3.2s clockwise.
    private func animateLayer3() {
        withAnimation(
            .linear(duration: 3.2)
            .repeatForever(autoreverses: false)
        ) {
            rotation3 = 360
        }
    }

    /// Layer 4 — Bloom: 4.0s counter-clockwise.
    private func animateLayer4() {
        withAnimation(
            .linear(duration: 4.0)
            .repeatForever(autoreverses: false)
        ) {
            rotation4 = -360
        }
    }

    /// Subtle pulse on the bloom layer: 0.3 — 0.5 on a 3s cycle.
    private func animateBloomPulse() {
        bloomPulse = 0.3
        withAnimation(
            .easeInOut(duration: 3.0)
            .repeatForever(autoreverses: true)
        ) {
            bloomPulse = 0.5
        }
    }
}
