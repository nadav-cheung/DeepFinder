import SwiftUI

// MARK: - Typography

/// Shared type scales for DeepFinder UI.
enum DeepFinderTypography {
    static func heading(size: CGFloat = 24) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    static func subheading(size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func body(size: CGFloat = 14) -> Font {
        .system(size: size)
    }

    static func metadata(size: CGFloat = 11) -> Font {
        .system(size: size, design: .monospaced)
    }

    static func badge(size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium)
    }
}

// MARK: - Glow Color Tints

extension GlowColors {
    static var selectionTint: Color { teal.opacity(0.12) }
    static var hoverTint: Color { teal.opacity(0.06) }
    static var errorBackground: Color { coral.opacity(0.12) }
    static var warningBackground: Color { amber.opacity(0.12) }
    static var successBackground: Color { teal.opacity(0.12) }
}

// MARK: - Shadow Configuration

/// A reusable shadow configuration with color, radius, and vertical offset.
struct ShadowConfig {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

/// Named shadow presets for consistent depth across the UI.
enum DeepFinderShadow {
    static let glass = ShadowConfig(color: Color.white.opacity(0.08), radius: 0.5, y: -0.5)
    static let elevated = ShadowConfig(color: .black.opacity(0.12), radius: 12, y: 4)
    static let glow = ShadowConfig(color: GlowColors.teal.opacity(0.15), radius: 16, y: 0)
    static let subtle = ShadowConfig(color: .black.opacity(0.06), radius: 8, y: 2)
}

// MARK: - Shadow View Extension

extension View {
    /// Applies a named shadow preset to this view.
    func deepShadow(style: ShadowConfig) -> some View {
        shadow(color: style.color, radius: style.radius, y: style.y)
    }
}

// MARK: - Spacing

/// Consistent spatial rhythm tokens for padding and layout spacing.
enum DeepFinderSpacing {
    static let tight: CGFloat = 4
    static let compact: CGFloat = 8
    static let standard: CGFloat = 12
    static let relaxed: CGFloat = 16
    static let spacious: CGFloat = 24
    static let generous: CGFloat = 32
}

// MARK: - Corner Radius

/// Consistent corner radius tokens for shapes and containers.
enum DeepFinderCornerRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
    static let xl: CGFloat = 20
    static let pill: CGFloat = 999
}

// MARK: - Icon Size

/// Consistent icon size tokens for SF Symbols and custom icons.
enum DeepFinderIconSize {
    static let inline: CGFloat = 12
    static let small: CGFloat = 14
    static let standard: CGFloat = 16
    static let large: CGFloat = 20
    static let display: CGFloat = 28
}

// MARK: - Motion

/// Standardized animation durations and easing for DeepFinder.
enum DeepFinderMotion {
    static let staggerDelay: Double = 0.03
    static let quick: Double = 0.15
    static let standard: Double = 0.2
    static let gentle: Double = 0.35

    static func staggered(index: Int) -> Animation {
        .easeOut(duration: standard).delay(staggerDelay * Double(index))
    }

    /// Snappy spring for buttons and toggles.
    static let springSnappy: Animation = .spring(duration: 0.3, bounce: 0.1)

    /// Smooth spring for panels and sheets.
    static let springSmooth: Animation = .spring(duration: 0.4, bounce: 0.15)

    /// Gentle spring for large layout transitions.
    static let springGentle: Animation = .spring(duration: 0.5, bounce: 0.2)
}
