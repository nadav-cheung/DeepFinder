# macOS Version Compatibility Strategy

**Status**: Planning | **Date**: 2026-06-03 | **Last verified**: 2026-06-03 | **Author**: macOS Compatibility Engineer

---

## Executive Summary

DeepFinder targets **macOS 26 (Tahoe) minimum**, which was released on **September 15, 2025** and is currently at version **26.5.1** (June 1, 2026). With macOS 27 expected to be announced at WWDC 2026 (June 8, 2026), the macOS 26 platform target is well-established and correct.

This document evaluates whether optional backward compatibility with macOS 15 (Sequoia) or macOS 14 (Sonoma) is warranted to expand the addressable user base, and provides the technical plan for doing so if the decision is made.

**Key finding**: Backward compatibility is a "nice to have" — not an emergency. DeepFinder can ship today on macOS 26 with a substantial user base. Optional Sequoia support would increase reach by ~55%.

---

## 1. Current Platform Assessment

### 1.1 macOS Version Landscape (June 2026)

| macOS Version | Released | Market Share (est.) | DeepFinder Supported |
|---|---|---|---|
| macOS 26 (Tahoe) | Sept 2025 | ~45% | ✅ Yes (target) |
| macOS 15 (Sequoia) | Sept 2024 | ~40% | ❌ Not yet |
| macOS 14 (Sonoma) | Sept 2023 | ~15% | ❌ Not yet |

**macOS 26 is the correct primary target.** It has been publicly available for 9 months and has significant adoption. DeepFinder's macOS 26 requirement is not a blocker — it's a reasonable baseline for a new project that leverages Tahoe-specific features (Liquid Glass, Swift 6 improvements, LanguageModelSession).

### 1.2 Homebrew Distribution Gate

Homebrew 5.0.0+ enforces a hard deadline: **September 1, 2026** — all Casks without Apple code-signing and notarization will be removed from official taps. DeepFinder must:

- Have a paid Apple Developer account ($99/year)
- Code-sign with a Developer ID Application certificate
- Enable Hardened Runtime
- Notarize via `notarytool`
- Staple the notarization ticket to the bundle

These requirements apply regardless of the macOS deployment target, but targeting only macOS 26 means **all user testing and early adoption must wait until the public OS ships** -- missing the critical window to build an install base before the Homebrew deadline.

### 1.3 Notarization Requires Running on Public macOS

The notarization process requires Xcode 26, which itself requires **macOS 15.6+ (Sequoia)** to run. This means:

- Xcode 26 **cannot run** on macOS 14
- Code-signing and notarization tooling (`notarytool`, `stapler`) ships with Xcode 26 on macOS 15.6+
- CI must run on macOS 15.6+ runners

Targeting macOS 14 as deployment target while building on macOS 15.6+ with Xcode 26 is fully supported and standard practice.

---

## 2. Build Toolchain Compatibility

### 2.1 Xcode 26 Deployment Target Range

Per Apple's official Xcode support page:

| Attribute | Value |
|---|---|
| Xcode version | 26.0 |
| Host OS required | macOS Sequoia **15.6** or later |
| Swift version | 6.2 |
| macOS SDK | macOS 26 |
| **macOS deployment target range** | **macOS 11 – 26** |

**Key finding**: Xcode 26 with Swift 6.2 supports deployment targets as low as macOS 11. There is no toolchain obstacle to targeting macOS 14 or 15.

### 2.2 Swift Tools Version

`Package.swift` currently specifies `// swift-tools-version: 6.2`. This is compatible with targeting older macOS versions -- the swift-tools-version constrains the **Package.swift manifest syntax**, not the deployment target. The deployment target is set independently via `.macOS(.v14)` or `.macOS(.v15)`.

---

## 3. API Dependency Audit

### 3.1 Critical: `.glassEffect()` -- macOS 26 ONLY

The Liquid Glass material view modifier `.glassEffect()` is introduced in SwiftUI for macOS 26 and has **no direct equivalent** on earlier OS versions. The closest approximations are:

| API | macOS 26 | macOS 15 | macOS 14 |
|---|---|---|---|
| `.glassEffect(.regular, in: .rect(cornerRadius:))` | Native | N/A | N/A |
| `.glassEffect(.regular, in: .capsule)` | Native | N/A | N/A |
| `.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius:))` | Works | Works | Works |
| `.background(.regularMaterial, in: RoundedRectangle(cornerRadius:))` | Works | Works | Works |
| `NSVisualEffectView(material: .hudWindow)` | Works | Works | Works |

**Files using `.glassEffect()` directly** (must be guarded):

| File | Line | Usage |
|---|---|---|
| `Sources/GUI/SearchBarView.swift` | 48 | `.glassEffect()` (no shape variant) |
| `Sources/GUI/FileDetailView.swift` | 40 | `.glassEffect()` (no shape variant) |
| `Sources/GUI/OnboardingView.swift` | 69 | `.glassEffect(.regular, in: .rect(cornerRadius: 12))` |
| `Sources/GUI/SpeechOverlayView.swift` | 215 | `.glassEffect(.regular, in: .rect(cornerRadius: 16))` |
| `Sources/GUI/GlassEffectContainer.swift` | 78 | `.glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))` (core wrapper) |

**Files using `GlassEffectContainer`** (which internally calls `.glassEffect()`):

| File | Line | Usage |
|---|---|---|
| `Sources/GUI/SearchPanelView.swift` | 107 | `GlassEffectContainer(intensity: .regular, cornerRadius: 24, glowActive: isSearchFocused)` |
| `Sources/GUI/ActionPanelView.swift` | 102 | `GlassEffectContainer(intensity: .regular, cornerRadius: 16, borderWidth: nil)` |
| `Sources/GUI/OnboardingView.swift` | 82 | `GlassEffectContainer(cornerRadius: 24)` |

### 3.2 Symbols Referencing `Glass` Type -- macOS 26 ONLY

The `Glass` enum (used internally by `GlassEffectContainer.glassVariant`) does not exist on macOS < 26:

```swift
// Sources/GUI/GlassEffectContainer.swift:95-101
private var glassVariant: Glass {  // ERROR: Cannot find type 'Glass' on macOS < 26
    switch intensity {
    case .regular: return .regular
    case .clear:   return .clear
    case .identity: return .identity
    }
}
```

This means the entire `GlassEffectContainer` body references a macOS 26-only type and will fail to compile when targeting macOS < 26 unless guarded.

### 3.3 `IntelligenceGlow` -- No macOS 26-Only APIs

`Sources/GUI/IntelligenceGlow.swift` uses only standard SwiftUI APIs:
- `ZStack`, `RoundedRectangle`, `AngularGradient`, `.rotationEffect()`, `.opacity()`, `.blur()`, `.shadow()`, `.onAppear()`, `.onChange()`
- `Timer.scheduledTimer` (Foundation)
- `@State`, `@Environment`

**Verdict**: No changes needed. The glow animation works on macOS 14+ without modification.

### 3.4 `@Observable` Macro -- Available from macOS 14

The `@Observable` macro (replacing `ObservableObject` + `@Published`) is available from:
- macOS 14.0+
- iOS 17.0+
- Swift 5.9+

**Files using `@Observable`**:
- `Sources/GUI/AccessHistory.swift:28`
- `Sources/GUI/SearchHistory.swift:22`
- `Sources/GUI/SpeechOverlayView.swift:26`
- `Sources/GUI/SettingsView.swift:129`
- `Sources/GUI/QuickLookPreview.swift:113`
- `Sources/GUI/ResultsListView.swift:9`

**Verdict**: No changes needed. `@Observable` is available on both macOS 14 and macOS 15. However, if macOS 13 were a target, these would need migration back to `ObservableObject`.

### 3.5 `@Bindable` -- Available from macOS 14

The `@Bindable` property wrapper is available from:
- macOS 14.0+
- Swift 5.9+

Used in: `SpeechOverlayView.swift:181`, `SettingsView.swift:379,552`, `ResultsListView.swift`.

**Verdict**: No changes needed.

### 3.6 `SFSpeechRecognizer` -- Available Since macOS 10.15

The Speech framework (`SFSpeechRecognizer`, `SFSpeechRecognizerAuthorizationStatus`) has been available since macOS 10.15 (Catalina).

**Files**: `Sources/AI/LocalSpeechProvider.swift`, `Sources/AI/SpeechAuthorization.swift`, `Sources/GUI/SearchPanelView.swift`

**Verdict**: No changes needed.

### 3.7 `RegisterEventHotKey` / `CGEventTap` -- Carbon, Available Since macOS 10.0

Used in `Sources/GUI/GlobalHotkey.swift`. These are ancient Carbon APIs available on all macOS versions. The `CGEvent.tapCreate` API is also available since macOS 10.5.

**Verdict**: No changes needed.

### 3.8 `NSPanel` + `.hidesOnDeactivate` -- Available Since macOS 10.0

Used in `Sources/GUI/SearchPanelView.swift` (`SearchPanelHostingController`). Standard AppKit.

**Verdict**: No changes needed.

### 3.9 `.onChange(of: initial:)` Two-Parameter Form -- Available from macOS 14

The new `.onChange(of:)` with `(oldValue, newValue)` closure signature is SwiftUI macOS 14+:

```swift
// New form (macOS 14+)
.onChange(of: text) { _, newValue in ... }

// Old form (deprecated in macOS 14, removed in macOS 15+)
.onChange(of: text) { newValue in ... }
```

DeepFinder currently uses the two-parameter form in multiple files (SearchPanelView, ResultsListView, etc.).

**Verdict**: Compatible with macOS 14+. No changes needed for macOS 14/15 targets. Would be incompatible with macOS 13.

### 3.10 `.task {}` Modifier -- Available from macOS 12

**Verdict**: Compatible with macOS 14+. No changes needed.

### 3.11 `.onKeyPress()` -- Available from macOS 14

This SwiftUI keyboard event modifier is available from macOS 14.0+.

Used in: `SearchPanelView.swift`, `ResultsListView.swift`.

**Verdict**: Compatible with macOS 14+. Would require alternative (AppKit keyboard events) for macOS 13.

### 3.12 Summary of Blocking APIs

| API | macOS 26 | macOS 15 | macOS 14 | Action Required |
|---|---|---|---|---|
| `.glassEffect()` | Native | **BLOCKED** | **BLOCKED** | Guard + fallback |
| `Glass` enum | Native | **BLOCKED** | **BLOCKED** | Guard + fallback |
| `@Observable` | Native | Native | Native | None |
| `@Bindable` | Native | Native | Native | None |
| `SFSpeechRecognizer` | Native | Native | Native | None |
| `RegisterEventHotKey` | Native | Native | Native | None |
| `.onChange(of:initial:)` | Native | Native | Native | None |
| `.onKeyPress()` | Native | Native | Native | None |
| `.task {}` | Native | Native | Native | None |
| `NSPanel` | Native | Native | Native | None |

**Key finding**: Only `.glassEffect()` and the `Glass` type are actual blockers. Everything else in the current codebase is compatible with macOS 14 and 15.

---

## 4. Backport Strategy

### 4.1 Minimum Deployment Targets

| Tier | Target | Rationale |
|---|---|---|
| **Primary** | **macOS 15.0 (Sequoia)** | Xcode 26 runs on 15.6+, covers ~55% of Macs |
| **Stretch** | **macOS 14.4 (Sonoma)** | Requires CI on macOS 15.6+ host building for 14.4 target |

macOS 13 is explicitly excluded: `.onChange(of:initial:)`, `@Observable`, and `.onKeyPress()` are unavailable. The effort to backport beyond macOS 14 would require substantial API shimming.

### 4.2 Guard Pattern: `#if swift(>=6.2)` + `#available(macOS 26, *)`

There are two layers of guarding required:

1. **Compile-time**: `#if swift(>=6.2)` — The Swift compiler type-checks all code inside `#available` blocks. `.glassEffect()` does not exist in the Xcode 16.x / Swift 6.0 SDK, so it will fail compilation even inside an `if #available`. Wrapping in `#if swift(>=6.2)` physically excludes the code from older compilers.

2. **Runtime**: `#available(macOS 26, *)` — On macOS 26, use the Liquid Glass API. On older OS, use the fallback material.

**Standard pattern for every `.glassEffect()` call site**:

```swift
struct GlassBackedView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var cornerRadius: CGFloat
    var intensity: GlassIntensity = .regular

    var body: some View {
        content()
            #if swift(>=6.2)
            if #available(macOS 26.0, *) {
                content()
                    .glassEffect(macOS26Glass, in: .rect(cornerRadius: cornerRadius))
            } else {
                fallbackView
            }
            #else
            fallbackView
            #endif
    }

    @ViewBuilder
    private var fallbackView: some View {
        content()
            .background(
                materialForIntensity,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }

    private var materialForIntensity: Material {
        switch intensity {
        case .regular: return .ultraThinMaterial
        case .clear:   return .ultraThinMaterial
        case .identity: return .ultraThickMaterial  // closest fallback
        }
    }

    #if swift(>=6.2)
    private var macOS26Glass: Glass {
        switch intensity {
        case .regular: return .regular
        case .clear:   return .clear
        case .identity: return .identity
        }
    }
    #endif
}
```

### 4.3 Specific `#available` Guard Locations

#### File: `Sources/GUI/GlassEffectContainer.swift` (Lines 35-107)

**Change**: Rewrite `body` to guard `.glassEffect()` + `Glass` type references. Extract a `FallbackGlassContainer` or use `#if swift(>=6.2)` branching.

**Current (line 76-90)**:
```swift
var body: some View {
    content()
        .glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))
        .overlay {
            if let borderWidth {
                let effectiveWidth = highContrastBoost(borderWidth)
                IntelligenceGlow(/* ... */)
            }
        }
}
```

**Target**:
```swift
var body: some View {
    let base = content()
    #if swift(>=6.2)
    if #available(macOS 26.0, *) {
        base
            .glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))
            .overlay { glowOverlay }
    } else {
        base
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { glowOverlay }
    }
    #else
    base
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { glowOverlay }
    #endif
}
```

And the `glassVariant` property (lines 95-101) must be guarded:
```swift
#if swift(>=6.2)
private var glassVariant: Glass {
    switch intensity {
    case .regular: return .regular
    case .clear:   return .clear
    case .identity: return .identity
    }
}
#endif
```

#### File: `Sources/GUI/SearchBarView.swift` (Line 48)

```swift
// Current
.glassEffect()

// Target
#if swift(>=6.2)
if #available(macOS 26.0, *) {
    .glassEffect()
} else {
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}
#else
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
#endif
```

#### File: `Sources/GUI/FileDetailView.swift` (Line 40)

```swift
// Current
.glassEffect()

// Target
#if swift(>=6.2)
if #available(macOS 26.0, *) {
    .glassEffect()
} else {
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}
#else
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
#endif
```

#### File: `Sources/GUI/OnboardingView.swift` (Line 69, FeatureCard)

```swift
// Current
.glassEffect(.regular, in: .rect(cornerRadius: 12))

// Target
#if swift(>=6.2)
if #available(macOS 26.0, *) {
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
} else {
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
}
#else
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
#endif
```

#### File: `Sources/GUI/SpeechOverlayView.swift` (Line 215)

```swift
// Current
.glassEffect(.regular, in: .rect(cornerRadius: 16))

// Target
#if swift(>=6.2)
if #available(macOS 26.0, *) {
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
} else {
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}
#else
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
#endif
```

### 4.4 Refactoring Opportunity: `GlassBackedView` Reusable Component

Instead of duplicating the guard pattern 5+ times, extract a reusable wrapper:

```swift
// Sources/GUI/GlassBackedView.swift (new file)
import SwiftUI

/// Wraps content in either Liquid Glass (macOS 26) or a material fallback.
struct GlassBackedView<Content: View>: View {
    let cornerRadius: CGFloat
    let intensity: GlassIntensity
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        cornerRadius: CGFloat = 12,
        intensity: GlassIntensity = .regular,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.intensity = intensity
        self.content = content
    }

    var body: some View {
        #if swift(>=6.2)
        if #available(macOS 26.0, *) {
            content()
                .glassEffect(glassVariant, in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        content()
            .background(fallbackMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fallbackMaterial: Material {
        switch intensity {
        case .regular: return .ultraThinMaterial
        case .clear:   return .ultraThinMaterial
        case .identity: return .ultraThickMaterial
        }
    }

    #if swift(>=6.2)
    private var glassVariant: Glass {
        switch intensity {
        case .regular: return .regular
        case .clear:   return .clear
        case .identity: return .identity
        }
    }
    #endif
}
```

Then `GlassEffectContainer` becomes:

```swift
struct GlassEffectContainer<Content: View>: View {
    // ... (properties unchanged)

    var body: some View {
        GlassBackedView(cornerRadius: cornerRadius, intensity: intensity) {
            content()
        }
        .overlay {
            if let borderWidth {
                IntelligenceGlow(
                    isActive: glowActive,
                    cornerRadius: cornerRadius,
                    borderWidth: highContrastBoost(borderWidth)
                )
                .allowsHitTesting(false)
            }
        }
    }
}
```

This approach:
- Centralizes the guard logic in one place
- Allows future Glass API adoption without touching every call site
- Makes the fallback behavior testable independently

---

## 5. Feature Degradation Table

| Feature | macOS 26 (Tahoe) | macOS 15 (Sequoia) | macOS 14 (Sonoma) |
|---|---|---|---|
| **Liquid Glass material** | Full native `.glassEffect()` | `.ultraThinMaterial` fallback | `.ultraThinMaterial` fallback |
| **Intelligence Glow border** | Full fidelity | Full fidelity (no dependency on Glass) | Full fidelity |
| **GlassEffectContainer** | Full native | Degraded (material fallback) | Degraded (material fallback) |
| **Animated glow rotation** | 60fps | 60fps | 60fps |
| **Search panel appearance** | Liquid Glass + glow | Frosted material + glow | Frosted material + glow |
| **Speech recognition (voice input)** | Full | Full | Full |
| **Global hotkey (⌃⌘K)** | Full | Full | Full |
| **File search** | Full | Full | Full |
| **CLI (daemon + REPL)** | Full | Full | Full |
| **AI semantic search** | Full | Full (on-device only) | Full (on-device only) |
| **Settings window** | `.quaternary` material | `.quaternary` material | `.quaternary` material |
| **Onboarding window** | Glass cards | Material cards | Material cards |

**Bottom line**: The only visual difference is Glass vs. `.ultraThinMaterial`. All functionality is preserved on macOS 14 and 15. The IntelligenceGlow (animated teal/violet/coral/amber border) works identically on all versions because it uses standard SwiftUI primitives.

---

## 6. Liquid Glass Migration Detail

### 6.1 macOS 26: Native Liquid Glass

```swift
.glassEffect(.regular, in: .rect(cornerRadius: 24))
```

Characteristics:
- Hardware-accelerated translucency with parallax lighting
- Real-time reacts to ambient light and display tilt
- Built-in interactive highlight (`.interactive()` modifier)
- Tint support (`.tint(Color)` modifier)
- Glass element morphing via `glassEffectID` + `@Namespace`

### 6.2 macOS 15: `.ultraThinMaterial` + `.hudWindow` (AppKit)

For SwiftUI views:

```swift
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
```

For AppKit hosting controllers (e.g., the NSPanel in `SearchPanelHostingController`):

```swift
// In SearchPanelHostingController.show():
newPanel.isOpaque = false
newPanel.backgroundColor = .clear

// Optionally, wrap contentView in NSVisualEffectView for AppKit-level glass:
let visualEffectView = NSVisualEffectView(frame: newPanel.contentView?.bounds ?? .zero)
visualEffectView.material = .hudWindow     // closest to Liquid Glass on macOS 15
visualEffectView.blendingMode = .behindWindow
visualEffectView.state = .active
visualEffectView.wantsLayer = true
visualEffectView.autoresizingMask = [.width, .height]
```

### 6.3 macOS 14: Plain `.ultraThinMaterial`

macOS 14 does not have `.hudWindow` material. Use `.sheet` or `.contentBackground`:

```swift
// AppKit fallback
visualEffectView.material = .sheet         // macOS 14 compatible
visualEffectView.blendingMode = .behindWindow
```

The visual difference between `.hudWindow` (macOS 15) and `.sheet` (macOS 14) is subtle -- slightly less frosted appearance on Sonoma, but still a professional translucent material.

### 6.4 Comparison Matrix

| Property | macOS 26 Glass | macOS 15 .ultraThinMaterial | macOS 14 .ultraThinMaterial |
|---|---|---|---|
| Translucency | Full (parallax) | Static | Static |
| Tinting | `.tint()` API | Manual overlay | Manual overlay |
| Interactivity | `.interactive()` | None | None |
| Hardware acceleration | Yes (Metal) | Yes (CoreAnimation) | Yes (CoreAnimation) |
| Performance | Excellent | Excellent | Excellent |
| Visual quality | Premium | High | Good |
| Known bugs | Menu flash, scroll clarity | Stable | Stable |

---

## 7. Build Configuration

### 7.1 Package.swift Changes

**Current** (`Package.swift` line 6):
```swift
platforms: [.macOS(.v26)],
```

**Target (primary -- macOS 15)**:
```swift
platforms: [.macOS(.v15)],
```

**Target (stretch -- macOS 14)**:
```swift
platforms: [.macOS(.v14)],
```

**Recommended approach**: Use `.macOS(.v15)` as the primary target. This covers the majority of the user base (~55%) and is the minimum host OS for Xcode 26 (15.6+). If user demand justifies it, a subsequent PR can lower to `.v14`.

Full updated `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "deep-finder",
    platforms: [.macOS(.v15)],  // Changed from .v26
    products: [
        .library(name: "DeepFinder", targets: ["DeepFinder"]),
        .executable(name: "deepfinder", targets: ["DeepFinderCLI"]),
        .executable(name: "deepfinder-daemon", targets: ["DeepFinderDaemon"]),
        .executable(name: "deepfinder-app", targets: ["DeepFinderApp"]),
    ],
    targets: [
        .target(
            name: "DeepFinder",
            path: "Sources",
            exclude: ["CLIEntry", "DaemonEntry", "AppEntry"],
            resources: [
                .process("AI/Prompts")
            ],
            linkerSettings: [
                .linkedLibrary("edit")
            ]
        ),
        .executableTarget(
            name: "DeepFinderCLI",
            dependencies: ["DeepFinder"],
            path: "Sources/CLIEntry"
        ),
        .executableTarget(
            name: "DeepFinderDaemon",
            dependencies: ["DeepFinder"],
            path: "Sources/DaemonEntry"
        ),
        .executableTarget(
            name: "DeepFinderApp",
            dependencies: ["DeepFinder"],
            path: "Sources/AppEntry"
        ),
        .testTarget(
            name: "DeepFinderTests",
            dependencies: ["DeepFinder"],
            path: "Tests"
        ),
    ]
)
```

### 7.2 Info.plist Changes

The `LSMinimumSystemVersion` key in `build/DeepFinder.app/Contents/Info.plist` (and the source `Info.plist` if it exists under `Resources/`) must be updated:

```xml
<!-- Current -->
<key>LSMinimumSystemVersion</key>
<string>26.0</string>

<!-- Target -->
<key>LSMinimumSystemVersion</key>
<string>15.0</string>
```

### 7.3 CI Matrix

```yaml
# .github/workflows/build.yml (additions)
jobs:
  build-and-test:
    strategy:
      matrix:
        runner:
          - macos-15     # macOS Sequoia 15.x (Github Actions)
          # - macos-26   # Add when GitHub Actions supports macOS 26 runners
        xcode:
          - "26.0"
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ matrix.xcode }}.app
      - name: Build (macOS 15 deployment target)
        run: swift build -c release
      - name: Test (macOS 15 deployment target)
        run: swift test

  # Separate job for macOS 14 deployment target verification
  verify-macos14-target:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Verify build compiles for macOS 14 target
        run: |
          # Temporarily change target, build, verify, then restore
          sed -i '' 's/.macOS(.v15)/.macOS(.v14)/' Package.swift
          swift build --target DeepFinder
          # If this passes, macOS 14 target is ABI-compatible
```

**Note**: macOS 14 deployment target verification can only be a **compile check** on macOS 15 runners, since GitHub Actions does not provide macOS 14 runners and you cannot run macOS 14 binaries on macOS 15 (they would run but you can't test the actual OS behavior). Full testing on macOS 14 requires a physical test machine or VM.

---

## 8. Testing Strategy

### 8.1 Unit Tests (Runtime-Agnostic)

All existing tests in `Tests/` should pass without modification on any macOS >= 14, because:
- The unit tests test search, index, persistence, daemon, and CLI logic
- None of the unit tests exercise GUI rendering or `.glassEffect()`
- The `@Observable` and `@Bindable` macros work on macOS 14+

**Verification commands**:
```bash
# On macOS 15.6+ host
swift test 2>&1 | tail -20
# Expected: All tests pass, no glassEffect-related failures
```

### 8.2 Snapshot Testing for Visual Degradation

To verify the visual fallback on macOS 14/15, use SwiftUI snapshot testing:

```swift
// Tests/GUITests/GlassBackedViewSnapshotTests.swift
import XCTest
import SwiftUI
@testable import DeepFinder

final class GlassBackedViewSnapshotTests: XCTestCase {

    /// Verify that GlassBackedView renders without crashing on non-macOS-26.
    func testFallbackRendersBasicContent() {
        let view = GlassBackedView(cornerRadius: 12, intensity: .regular) {
            Text("Test Content")
                .padding()
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        hostingView.layout()

        // Verify the view hierarchy is non-empty (rendering succeeded)
        XCTAssertGreaterThan(hostingView.subviews.count, 0)
    }

    /// Verify that all GlassIntensity variants render without crashing on fallback.
    func testAllIntensityVariantsRender() {
        for intensity in [GlassIntensity.regular, .clear, .identity] {
            let view = GlassBackedView(cornerRadius: 12, intensity: intensity) {
                Color.blue.frame(width: 100, height: 100)
            }
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
            hostingView.layout()
            XCTAssertFalse(hostingView.subviews.isEmpty, "Failed for intensity: \(intensity)")
        }
    }

    /// Verify GlassEffectContainer renders with glow border on fallback.
    func testGlassEffectContainerWithGlowRenders() {
        let container = GlassEffectContainer(
            intensity: .regular,
            cornerRadius: 24,
            borderWidth: 2,
            glowActive: true
        ) {
            Text("Hello")
                .padding()
        }
        let hostingView = NSHostingView(rootView: container)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hostingView.layout()
        XCTAssertGreaterThan(hostingView.subviews.count, 0)
    }
}
```

### 8.3 Manual Visual QA Checklist

| Test Case | macOS 15 Expected | macOS 14 Expected |
|---|---|---|
| Search panel open (⌃⌘K) | Frosted translucent background, no flicker | Frosted translucent background, no flicker |
| Search bar appearance | Material background, glow border on focus | Material background, glow border on focus |
| IntelligenceGlow rotation | Smooth 60fps animation | Smooth 60fps animation |
| Clear button appearance | `xmark.circle.fill`, secondary color | Identical |
| Settings window sections | `.quaternary` material sections | Identical |
| Speech overlay | Material background, waveform animation | Identical |
| File detail panel | Material background, correct layout | Identical |
| Onboarding cards | Material backgrounds | Identical |
| Action panel (Cmd+K) | Material background, action list | Identical |
| Toast notifications | Centered, animated dismiss | Identical |

### 8.4 Cross-OS Test Matrix

```bash
# On macOS 26 (Tahoe) -- verify native Glass still works
swift test
./verify_visual.sh  # custom script: open each view, screenshot, compare

# On macOS 15 (Sequoia) -- verify fallback material
swift test
./verify_visual.sh

# On macOS 14 (Sonoma) -- verify fallback material (compile-check on 15 host)
swift build --target DeepFinder  # with .macOS(.v14) in Package.swift
```

---

## 9. Migration Timeline

### Phase 1: Infrastructure (Target macOS 15) — 1 Day

1. Change `Package.swift` platforms: `.macOS(.v26)` → `.macOS(.v15)`
2. Update `LSMinimumSystemVersion` in Info.plist: `26.0` → `15.0`
3. Run `swift build` — expect compilation failures on `.glassEffect()` and `Glass` type references
4. Create PR: "Set deployment target to macOS 15 (Sequoia)"

### Phase 2: Guard `.glassEffect()` — 2 Days

1. Create `Sources/GUI/GlassBackedView.swift` (reusable guarded wrapper)
2. Update `GlassEffectContainer.swift` to use `GlassBackedView` internally
3. Guard direct `.glassEffect()` calls in:
   - `SearchBarView.swift:48`
   - `FileDetailView.swift:40`
   - `OnboardingView.swift:69`
   - `SpeechOverlayView.swift:215`
4. Run `swift build` — must compile clean with `.macOS(.v15)`
5. Run `swift test` — all tests must pass
6. Create PR: "Add macOS 15 fallback for .glassEffect()"

### Phase 3: Verify Visual Degradation — 1 Day

1. Run on macOS 15 host: manual QA checklist (Section 8.3)
2. Write snapshot tests (Section 8.2)
3. Run on macOS 26 host: verify native Glass still renders correctly
4. Take comparison screenshots for docs
5. Create PR: "Add snapshot tests for glass fallback behavior"

### Phase 4: Stretch — macOS 14 Target — 1 Day

1. Change `Package.swift` platforms: `.macOS(.v15)` → `.macOS(.v14)`
2. Verify compilation on macOS 15.6+ host targeting macOS 14
3. If using `.onKeyPress()` or `.onChange(of:initial:)` — verify available on macOS 14 (yes, macOS 14.0+)
4. Run manual QA on macOS 14 physical test machine or VM
5. Create PR: "Lower deployment target to macOS 14 (Sonoma)"

### Phase 5: CI Hardening — 1 Day

1. Add CI matrix with macOS 15 runner
2. Add macOS 14 target compile-check job
3. Verify Homebrew formula builds from source
4. Test notarization flow on macOS 15 host
5. Create PR: "Add CI matrix for multi-OS testing"

### Total Estimated Effort: 6 working days

---

## 10. Risk Register

| Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|
| `.ultraThinMaterial` looks significantly worse than Glass | Low | Low | Material has been Apple's standard since macOS 11; visual difference is subtle (static vs. dynamic translucency) |
| IntelligenceGlow performance issues on older hardware | Low | Low | Uses standard SwiftUI animation primitives; no Metal shaders |
| Xcode 26 drops support for macOS 14 deployment target | Very Low | Very Low | Apple's documented minimum is macOS 11; dropping macOS 14 would be unprecedented (Sonoma is only 2 years old) |
| Future SwiftUI API additions require macOS 15+ | Medium | Low | Any new API must be guarded with `#available`; this becomes standard practice |
| `SFSpeechRecognizer` behaves differently across OS versions | Low | Low | Speech framework has been stable since macOS 10.15 |
| Homebrew formula validation fails on macOS 14 | Low | Low | Homebrew builds from source; deployment target is irrelevant to the build formula |

---

## 11. References

- [Apple Xcode Support](https://developer.apple.com/support/xcode/) — deployment target ranges
- [SwiftUI `.glassEffect()` Documentation](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [Homebrew 5.0.0 Notarization Policy](https://workbrew.com/blog/homebrew-5-0-0)
- [WWDC 2026 Announcements](https://www.macobserver.com/news/everything-apple-announced-at-wwdc-2025/)
- [Liquid Glass Design System](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Swift 6.2 Back-Deployment](https://www.hackingwithswift.com/swift/5.8/function-back-deployment)
- [Project CLAUDE.md](../../CLAUDE.md) — architecture overview
- [Design Spec](../superpowers/specs/design/2026-05-26-deep-finder-design.md)
- [Package.swift](../../Package.swift) — current build configuration
