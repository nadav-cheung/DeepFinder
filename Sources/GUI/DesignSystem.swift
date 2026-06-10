import SwiftUI
import DeepFinderIndex
import DeepFinderSearch
import DeepFinderDaemon
import DeepFinderAI
import DeepFinderFS
import DeepFinderCLILib

// MARK: - Typography

/// Shared type scales for DeepFinder UI.
public enum DeepFinderTypography {
    public static func heading(size: CGFloat = 24) -> Font {
        .system(size: size, weight: .bold, design: .default)
    }

    public static func subheading(size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    public static func body(size: CGFloat = 14) -> Font {
        .system(size: size)
    }

    public static func metadata(size: CGFloat = 11) -> Font {
        .system(size: size, design: .monospaced)
    }

    public static func badge(size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium)
    }
}

// MARK: - Glow Color Tints

extension GlowColors {
    public static var selectionTint: Color { teal.opacity(0.12) }
    public static var hoverTint: Color { teal.opacity(0.06) }
    public static var errorBackground: Color { coral.opacity(0.12) }
    public static var warningBackground: Color { amber.opacity(0.12) }
    public static var successBackground: Color { teal.opacity(0.12) }
}

// MARK: - Shadow Configuration

/// A reusable shadow configuration with color, radius, and vertical offset.
public struct ShadowConfig: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let y: CGFloat
}

/// Named shadow presets for consistent depth across the UI.
public enum DeepFinderShadow {
    public static let glass = ShadowConfig(color: Color.white.opacity(0.08), radius: 0.5, y: -0.5)
    public static let elevated = ShadowConfig(color: .black.opacity(0.12), radius: 12, y: 4)
    public static let glow = ShadowConfig(color: GlowColors.teal.opacity(0.15), radius: 16, y: 0)
    public static let subtle = ShadowConfig(color: .black.opacity(0.06), radius: 8, y: 2)
}

// MARK: - Shadow View Extension

extension View {
    /// Applies a named shadow preset to this view.
    public func deepShadow(style: ShadowConfig) -> some View {
        shadow(color: style.color, radius: style.radius, y: style.y)
    }
}

// MARK: - Spacing

/// Consistent spatial rhythm tokens for padding and layout spacing.
public enum DeepFinderSpacing {
    public static let tight: CGFloat = 4
    public static let compact: CGFloat = 8
    public static let standard: CGFloat = 12
    public static let relaxed: CGFloat = 16
    public static let spacious: CGFloat = 24
    public static let generous: CGFloat = 32
}

// MARK: - Corner Radius

/// Consistent corner radius tokens for shapes and containers.
public enum DeepFinderCornerRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
    public static let xl: CGFloat = 20
    public static let pill: CGFloat = 999
}

// MARK: - Icon Size

/// Consistent icon size tokens for SF Symbols and custom icons.
public enum DeepFinderIconSize {
    public static let inline: CGFloat = 12
    public static let small: CGFloat = 14
    public static let standard: CGFloat = 16
    public static let large: CGFloat = 20
    public static let display: CGFloat = 28
}

// MARK: - Motion

/// Standardized animation durations and easing for DeepFinder.
public enum DeepFinderMotion {
    public static let staggerDelay: Double = 0.03
    public static let quick: Double = 0.15
    public static let standard: Double = 0.2
    public static let gentle: Double = 0.35

    public static func staggered(index: Int) -> Animation {
        .easeOut(duration: standard).delay(staggerDelay * Double(index))
    }

    /// Snappy spring for buttons and toggles.
    public static let springSnappy: Animation = .spring(duration: 0.3, bounce: 0.1)

    /// Smooth spring for panels and sheets.
    public static let springSmooth: Animation = .spring(duration: 0.4, bounce: 0.15)

    /// Gentle spring for large layout transitions.
    public static let springGentle: Animation = .spring(duration: 0.5, bounce: 0.2)
}
