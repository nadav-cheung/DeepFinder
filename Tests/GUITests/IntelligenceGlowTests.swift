import Testing
import SwiftUI
@testable import DeepFinder

@Suite("IntelligenceGlow")
struct IntelligenceGlowTests {

    // MARK: - 1. IntelligenceGlow creates without crash

    @Test("IntelligenceGlow constructs with default and custom parameters")
    func testIntelligenceGlowCreates() {
        // Default parameters
        let glowDefault = IntelligenceGlow()
        let _ = glowDefault

        // Custom parameters
        let glowCustom = IntelligenceGlow(cornerRadius: 32, borderWidth: 4)
        let _ = glowCustom

        // If we reach here, construction succeeded without crash.
        #expect(Bool(true))
    }

    // MARK: - 2. GlassEffectContainer wraps content

    @Test("GlassEffectContainer constructs with content")
    func testGlassEffectContainerWrapsContent() {
        let container = GlassEffectContainer(cornerRadius: 24, borderWidth: 2) {
            Text("Hello")
        }
        let _ = container

        let containerDefault = GlassEffectContainer {
            Color.red
        }
        let _ = containerDefault

        #expect(Bool(true))
    }

    // MARK: - 3. Colors match spec

    @Test("GlowColors are defined and distinct")
    func testGlowColorsAreDistinct() {
        // The GlowColors enum exposes four static Color constants.
        // We verify they are constructed and their descriptions are non-empty.
        let teal = GlowColors.teal
        let violet = GlowColors.violet
        let coral = GlowColors.coral
        let amber = GlowColors.amber

        let descriptions = [
            String(describing: teal),
            String(describing: violet),
            String(describing: coral),
            String(describing: amber),
        ]

        // All descriptions should be non-empty (Color was constructed)
        for desc in descriptions {
            #expect(!desc.isEmpty)
        }

        // The four colors should not all be identical.
        // This catches a regression where all four are accidentally the same.
        let unique = Set(descriptions)
        #expect(unique.count >= 2)

        // Verify the specific hex values by constructing reference colors
        // with the same RGB ratios and confirming their descriptions match.
        let refTeal = Color(red: 0x00 / 255.0, green: 0xC9 / 255.0, blue: 0xA7 / 255.0)
        let refViolet = Color(red: 0x84 / 255.0, green: 0x5E / 255.0, blue: 0xC2 / 255.0)
        let refCoral = Color(red: 0xFF / 255.0, green: 0x6F / 255.0, blue: 0x91 / 255.0)
        let refAmber = Color(red: 0xFF / 255.0, green: 0xC7 / 255.0, blue: 0x5F / 255.0)

        // The descriptions of GlowColors should match the reference colors
        // because they use the same Color(red:green:blue:) initializer.
        #expect(String(describing: teal) == String(describing: refTeal))
        #expect(String(describing: violet) == String(describing: refViolet))
        #expect(String(describing: coral) == String(describing: refCoral))
        #expect(String(describing: amber) == String(describing: refAmber))
    }
}
