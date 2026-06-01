# DeepFinder Brand Assets

Brand identity and asset specifications for DeepFinder. All assets should be reproducible from this document.

---

## 1. Logo Concept

### Primary Mark

A magnifying glass merged with a "D" letterform.

- The glass lens forms the bowl of the "D", while the handle extends from the right side of the vertical stem, tilting downward at approximately 45 degrees.
- The "D" stem is a bold sans-serif vertical bar (matching SF Pro weight Heavy or Black).
- The lens interior contains a subtle radial highlight (top-left quadrant) to convey glass reflection.
- The handle is rectangular with rounded outer corners and a slight taper toward the grip, meeting the lens at a tangent.

### Design Principles

- **Recognizable at small sizes.** The silhouette must be unambiguous at 16x16pt (menu bar). The magnifying-glass silhouette is universally understood for search.
- **Balanced proportions.** The lens should be visually centered, not geometrically centered -- optical compensation for the handle weight.
- **Monochrome-friendly.** The mark must work in solid black, solid white, and system accent color without losing legibility.

### Layout Variants

| Variant | Usage |
|---------|-------|
| Mark only (icon) | App icon, menu bar, favicon, touch-bar |
| Mark + "DeepFinder" wordmark (horizontal) | GitHub header, website nav, about dialog |
| Mark + wordmark (stacked) | Vertical banners, merch |

### Wordmark

"DeepFinder" in SF Pro Display, Heavy weight, with tightened tracking (-1%). The "D" and "F" capitals should align at the top; the descender of "p" creates natural rhythm.

---

## 2. Color Palette

Derived from the IntelligenceGlow `AngularGradient` defined in `Sources/GUI/IntelligenceGlow.swift`.

### Primary Gradient Colors

| Color | Hex | RGB | Role |
|-------|-----|-----|------|
| Teal | `#00C9A7` | `0, 201, 167` | Primary brand color, gradient start |
| Violet | `#845EC2` | `132, 94, 194` | Secondary, gradient midpoint |
| Coral | `#FF6F91` | `255, 111, 145` | Accent, gradient midpoint |
| Amber | `#FFC75F` | `255, 199, 95` | Warm accent, gradient end |

### Derived Palette

| Color | Hex | RGB | Usage |
|-------|-----|-----|-------|
| Dark Teal | `#008B73` | `0, 139, 115` | Dark mode app icon background |
| Light Teal | `#4DFFD6` | `77, 255, 214` | Light mode icon highlight |
| Deep Violet | `#6B4FA0` | `107, 79, 160` | Dark UI accents, pressed states |
| Dark Background | `#1C1C1E` | `28, 28, 30` | macOS system dark background |
| Light Background | `#F5F5F7` | `245, 245, 247` | macOS system light background |
| Glass Translucent | `rgba(255,255,255,0.12)` | — | Liquid Glass surfaces (dark mode) |
| Glass Translucent Light | `rgba(0,0,0,0.06)` | — | Liquid Glass surfaces (light mode) |

### Gradient Specifications

**App Icon Gradient (diagonal, top-left to bottom-right):**
```
Angle: 135 degrees
Colors: teal (#00C9A7) -> violet (#845EC2) -> coral (#FF6F91) -> amber (#FFC75F)
```

**Intelligence Glow Border (angular, rotating):**
```
Type: AngularGradient (conic)
Colors: teal -> violet -> coral -> amber -> teal (seamless loop)
Rotation: 1 full revolution per 1.8 seconds
Opacity pulse: 0.6 -> 1.0 -> 0.6 over 3 seconds (easeInOut)
```

**Wordmark Gradient (horizontal):**
```
Angle: 0 degrees
Colors: teal (#00C9A7) -> violet (#845EC2)
```

---

## 3. Typography

### Primary: SF Pro

Apple's system typeface for macOS. Use SF Pro for all UI and marketing.

| Usage | Font | Weight | Size | Tracking |
|-------|------|--------|------|----------|
| Wordmark | SF Pro Display | Heavy | logo-specific | -1% |
| App name (UI) | SF Pro Text | Semibold | 17pt | 0% |
| Headings (docs) | SF Pro Display | Bold | 28pt | -0.5% |
| Body (docs) | SF Pro Text | Regular | 15pt | 0% |
| Code (docs) | SF Mono | Regular | 13pt | 0% |
| Terminal output | SF Mono | Regular | 13pt | 0% |

### Fallback

When SF Pro is not available (web, non-Apple platforms):
- **Sans-serif**: Inter (primary fallback), system-ui (secondary fallback)
- **Monospace**: SF Mono -> JetBrains Mono -> ui-monospace

### Typography Rules

- Never italicize the wordmark.
- Always capitalize the "D" and "F" in "DeepFinder" -- CamelCase is the official spelling.
- The CLI command is lowercase: `deepfinder`.
- The slug is hyphenated: `deep-finder`.

---

## 4. App Icon

### macOS 26 Style

DeepFinder's app icon follows the macOS 26 (Tahoe) design language: a rounded rectangle with continuous corners, a slightly raised appearance with a subtle shadow, and a gradient fill.

**Shape:** Rounded rectangle with continuous corner radius (smooth, not circular arc). macOS 26 uses the "squircle" corner profile -- approximately 22.37% of the icon's edge length.

**Sizes (points):**
| Context | Size | Format |
|---------|------|--------|
| App Store (required) | 1024x1024 | PNG (no alpha flattening needed by App Store Connect) |
| Finder / Dock | 512x512, 256x256, 128x128, 64x64, 32x32, 16x16 | ICNS |
| Menu bar | 16x16, 16x16@2x, 16x16@3x | PDF (template) or PNG |
| Notifications | 32x32, 32x32@2x | PNG |

**Layout (1024pt grid):**
- **Background:** dark teal-to-violet diagonal gradient (135 degrees, #008B73 to #6B4FA0), or a single system color for light-mode variant.
- **Mark:** centered within the rounded rect, occupying approximately 55-60% of the icon width. The magnifying-glass "D" mark is rendered in white with 90% opacity, with a subtle teal glow (shadow offset 0, blur 8, color teal at 40%).
- **Shadow:** `y=2pt, blur=6pt, opacity=25% black` -- the standard macOS app-icon depth cue.
- **Inner highlight:** a soft radial gradient (white at 8% opacity, center top-third) gives the glass-surface illusion without breaking the flat-icon aesthetic.

**Dark vs. Light:**
- One icon asset set (dark background) is sufficient for macOS. The system handles tinting for light mode.
- Alternative: provide a light-background variant with the mark in dark colors for light-mode Dock.

**Do Not:**
- Add text to the app icon.
- Use a circular mask (that is iOS, not macOS).
- Use 3D extrusion or skeuomorphic textures.
- Put the mark too close to the edges -- maintain at least 15% padding on all sides.

### macOS 26 "Liquid Glass" Treatment

macOS 26 icons can optionally use a subtle glass-material overlay. For DeepFinder:
- Apply a semi-transparent white gradient (top half, 0% to 4% opacity) as a specular highlight layer.
- The mark should sit above the glass layer.

---

## 5. Menu Bar Icon

### Design

A simple magnifying glass glyph, rendered as a template image (PDF) so the system automatically applies the correct color for light/dark mode and menu bar translucency.

**Specification:**
- **Format:** PDF vector, 1-color, template rendering mode.
- **Artboard:** 16x16pt (provide 16x16, 32x32@2x, 48x48@3x as raster fallbacks).
- **Glyph:** A circle (lens) with a stroke weight of 1.5pt and a stem (handle) extending from the lower-right quadrant at 45 degrees. The handle is 1.5pt stroke, 4pt long, with a rounded cap.
- **Circle diameter:** approximately 9pt.
- **Padding:** 1.5pt on all sides within the 16pt artboard.

### Visual Reference

```
     ┌──────────────┐
     │              │
     │    ╭──╮      │
     │    │  │╲     │
     │    ╰──╯ ╲    │
     │          ╲   │
     │           │  │
     │              │
     └──────────────┘
   (template image, system-colored)
```

### Behavior

- The menu bar icon should always be visible (no hide-menu-bar-icon preference).
- Left-click opens the search panel (GUI mode).
- Right-click shows a context menu: Open Search / Settings / Quit.

---

## 6. GitHub Social Preview Image

### Image Concept

A 1280x640 (2:1 ratio) PNG image for GitHub's Open Graph / social card.

**Composition (left to right):**
- **Left half (640x640):** The app icon mark (magnifying-glass "D") centered on a dark background (`#1C1C1E` or the teal-to-violet gradient), scaled to fill approximately 70% of the left half.
- **Right half (640x640):** White or light-background area (`#F5F5F7`) containing:
  - "DeepFinder" wordmark in SF Pro Heavy, dark teal color, 72pt
  - Subtitle: "Blazing-fast file search for macOS" in SF Pro Regular, dark gray, 28pt
  - Small badge-style tagline: "v3.0 -- CLI + GUI + AI" in SF Pro Semibold, 18pt, teal color

**Overall background:** Solid `#1C1C1E` with the right-half content area as a lighter card (`#2C2C2E`) inset by 40pt on all sides.

**Border:** None. GitHub renders social cards with its own rounded corners.

### Alternative (Text-Only)

For simpler maintenance, a code-generated card using HTML/CSS rendered through Puppeteer or a similar headless browser. The HTML template should be checked into the repo as `docs/social-preview.html`.

---

## 7. ASCII Art (Terminal / README)

### Terminal Banner

Used by the interactive REPL at startup and for `deepfinder --version --verbose`. Render in the gradient colors using ANSI 24-bit truecolor escape codes when output is a TTY. Fall back to plain text when piped.

**ANSI version (TTY, 24-bit color):**

```
  ____                 _____  __         _
 / __ \ ___   ___ ___ / __\ \/ /  ___ __| | ___  _ __
/ / _ `/ -_) / -_|_-_| _| |\  /  / -_| _` |/ -_)| '__|
\ \__/\ \__/ \___/___|_| |_|/__\ \___\__/_|\___/ |_|
 \___/
```

**Plain-text version (piped, script-friendly):**

```
  ____                 _____  __         _
 / __ \ ___   ___ ___ / __\ \/ /  ___ __| | ___  _ __
/ / _ `/ -_) / -_|_-_| _| |\  /  / -_| _` |/ -_)| '__|
\ \__/\ \__/ \___/___|_| |_|/__\ \___\__/_|\___/ |_|
 \___/
```

### Mini Banner

For compact contexts (help footer, man page header):

```
  ╭──╮
  │  │╲  DeepFinder
  ╰──╯ ╲
        ╲
```

### CLI Startup Banner

When the REPL starts, show:
1. The full ASCII art banner (above)
2. Version line: "v3.0.0 -- Instant file search for macOS"
3. Index statistics: "{N} files indexed in {T}s"
4. The prompt: "> "

### README Placement

The README should include the full ASCII banner immediately below the `# DeepFinder` heading, before the description paragraph.

---

## 8. Asset Checklist

| Asset | Format | Location | Status |
|-------|--------|----------|--------|
| App icon (1024pt) | PNG | `Assets/AppIcon.appiconset/` | TODO |
| App icon (ICNS) | ICNS | `Assets/AppIcon.icns` | TODO |
| Menu bar icon | PDF (template) | `Assets/MenuBarIcon.pdf` | TODO |
| GitHub social preview | PNG (1280x640) | `docs/social-preview.png` | TODO |
| Social preview HTML template | HTML | `docs/social-preview.html` | TODO |
| ASCII banner (ANSI) | N/A (code-generated) | `Sources/CLI/TerminalFormatter.swift` | TODO |
| Wordmark SVG | SVG | `docs/wordmark.svg` | TODO |
| Favicon | ICO/PNG | `docs/favicon.ico` | TODO |

---

## 9. Usage Guidelines

### Do
- Use the full-color logo on dark backgrounds.
- Use the monochrome (white) mark on dark solid fills.
- Use the monochrome (black) mark on light solid fills.
- Maintain clear space around the logo equal to the height of the "D" lens.
- Use SF Pro for all typography, or fall back to Inter on web.

### Don't
- Stretch, skew, or rotate the logo.
- Change the logo colors outside the defined palette.
- Add drop shadows, glows, or effects beyond what is specified.
- Place the logo on busy photographic backgrounds.
- Use the wordmark in all-caps or all-lowercase.
- Combine the mark with other icons or emoji.
- Create derivative logos or sub-brands without explicit permission.

---

## 10. References

- **IntelligenceGlow colors:** `Sources/GUI/IntelligenceGlow.swift` -- canonical source for the teal/violet/coral/amber gradient.
- **Product name:** `PRODUCT.toml` -- single source of truth for product name, slug, command, and identifier.
- **Apple HIG (macOS):** [App Icon Design](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- **Apple HIG (Menu Bar):** [Menu Bar Extras](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
