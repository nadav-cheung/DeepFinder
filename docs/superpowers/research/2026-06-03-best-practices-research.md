# Search UI Best Practices — Research Report

**Date**: 2026-06-03
**Status**: Applied to v3.2 Search UI Design
**Sources**: Everything (voidtools), Raycast, macOS Spotlight, Alfred — UI/UX analysis + HIG review + community patterns

---

## Research Scope

This research informed the v3.2 Search UI Refinement design. We studied four reference applications and macOS HIG to identify concrete, actionable patterns that improve search UI speed, keyboard efficiency, and visual polish.

---

## Domain 1: Result List Interaction Patterns

### 1. Adaptive Panel Height

**Finding**: Raycast dynamically sizes its panel based on result count and screen height. Spotlight uses a fixed height that wastes space on large displays.

**Recommendation**: `min(screenH - searchBoxHeight - margins, 800pt)`. On a 15" MacBook (900pt effective height), this yields ≥15 visible rows at 40pt row height. On larger displays, the 800pt cap prevents wasteful stretching.

**Adopted as**: REQ-3.2-07 modification — adaptive height with screen-aware cap.

### 2. Emacs Keybindings + Type-to-Select

**Finding**: Everything supports type-to-select (press a letter, jump to first file starting with that letter). Raycast and many terminals support Ctrl+N/Ctrl+P as ↓/↑ aliases (Emacs convention). These are deeply ingrained muscle memory for developers.

**Recommendation**: Ctrl+N/Ctrl+P as aliases for ↓/↑. Type-to-select on printable character keys (no modifier), with same-letter cycling for repeated presses.

**Adopted as**: REQ-3.2-08 modification — added Ctrl+N/P aliases and type-to-select with cycling.

### 3. Scroll Easing for Keyboard Navigation

**Finding**: When holding ↓ to scroll through results, `.easeInOut` creates a "rubber-band" feel — the scroll accelerates then decelerates, lagging behind the user's key repeat rate. `.easeOut` decelerates into position, matching the natural expectation that the viewport "catches up" to the selection.

**Recommendation**: Use `.easeOut(0.15s)` for scroll-to-selection animation. The deceleration curve feels more responsive than symmetric easeInOut.

**Adopted as**: REQ-3.2-09 modification — changed scroll animation from `.easeInOut` to `.easeOut`.

### 4. Trust LazyVStack — No Manual Windowing

**Finding**: macOS 26 (Tahoe) LazyVStack has bidirectional lazy loading with built-in cell recycling. Manual windowing (e.g., "render ±5 rows around viewport") fights the framework's optimizations and adds complexity for no gain. Apple's WWDC sessions explicitly recommend against manual windowing with LazyVStack.

**Recommendation**: Use `.equatable()` on row views for fast diffing, pre-compute expensive work (like AttributedString highlights) on a background thread, and use fixed row heights. Let LazyVStack handle virtualization.

**Adopted as**: REQ-3.2-14 modification — removed manual windowing plan, added `.equatable()` + background AttributedString.

### 5. Raycast History Pattern

**Finding**: Raycast shows search history when the search box is empty. Pressing ↑ in an empty search box enters the history list. This pattern is discoverable (the empty box is a natural "what now?" state) and avoids a dedicated history UI element.

**Recommendation**: Empty search box + ↑ enters history. History shares the same list area as results — no overlapping panels or modals.

**Adopted as**: REQ-3.2-02 modification — history dropdown with ↑ access, shared list area.

### 6. Liquid Glass — Navigation Layer Only

**Finding**: Apple WWDC25 HIG guidance: `.glassEffect()` is for navigation chrome (sidebars, toolbars, panels) only. Applying it to content rows creates visual noise and reduces readability. The glass material is designed for structural UI elements, not data display.

**Recommendation**: Apply glass effect to the search panel background only. Result rows use standard list styling with subtle hover/selection effects.

**Adopted as**: REQ-3.2-21 modification — glass on panel only, never on result rows.

### 7. Action Panel Polish

**Finding**: Raycast's action panel (⌘K) is the gold standard for discoverability. Key patterns: shortcut hints on the right side of each action row, unavailable actions hidden (not grayed), keyboard focus trapped within the panel, fuzzy search for quick action discovery.

**Recommendation**: ⌘K action panel with fuzzy search, keyboard trap, hidden unavailable actions, monospaced shortcut hints.

**Adopted as**: REQ-3.2-31 modification — action panel polish following Raycast patterns.

### 8. Sticky Category Headers with Auto-Collapse

**Finding**: When grouping results by type (Applications, Documents, Images, etc.), long category lists push relevant results below the fold. Spotlight's category chips are an alternative, but sticky headers with smart collapsing are more space-efficient.

**Recommendation**: Sticky category headers during scroll. "Other" category auto-collapses when it contains more than 5 items (these are typically low-relevance).

**Adopted as**: REQ-3.2-32 modification — sticky headers + "Other" auto-collapse at >5 items.

---

## Domain 2: Reference Application Analysis

### Everything (voidtools) — Windows

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Query latency | ★★★★★ | < 1ms via NTFS MFT direct read |
| UI responsiveness | ★★★★☆ | Instant, but Win32-era aesthetics |
| Keyboard navigation | ★★★★☆ | Type-to-select, Enter/Ctrl+Enter |
| Discoverability | ★★☆☆☆ | Power features hidden, no onboarding |
| Visual polish | ★★☆☆☆ | Win 7 era, no animations |
| Memory | ★★★★★ | 50-150 MB for 1M+ files |

**Key takeaway**: Speed forgives all UI sins. Everything's raw speed is its brand.

### Raycast — macOS

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Query latency | ★★★★☆ | ~200ms, extensions add latency |
| UI responsiveness | ★★★★★ | Fluid animations, polished |
| Keyboard navigation | ★★★★★ | ⌘K action panel is gold standard |
| Discoverability | ★★★★★ | Extensions store, action panel |
| Visual polish | ★★★★★ | Excellent, consistent design language |
| Memory | ★★★☆☆ | 80-120 MB, heavier than competitors |

**Key takeaway**: ⌘K action panel + keyboard-first navigation + polished UI = developer love.

### Spotlight — macOS

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Query latency | ★★★★☆ | 50-100ms, system-level integration |
| UI responsiveness | ★★★★☆ | Good, but index lag creates gaps |
| Keyboard navigation | ★★★☆☆ | Basic ↑↓, no advanced nav |
| Discoverability | ★★☆☆☆ | Hidden features, no hints |
| Visual polish | ★★★★★ | Native Liquid Glass, Browse Mode |
| Reliability | ★★☆☆☆ | Index misses files, no health indicator |

**Key takeaway**: Reliability is Spotlight's Achilles' heel — DeepFinder's #1 competitive advantage.

### Alfred — macOS

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Query latency | ★★★★★ | ~100ms, very fast |
| UI responsiveness | ★★★★☆ | Fast, minimal animations |
| Keyboard navigation | ★★★★☆ | Good, customizable |
| Discoverability | ★★★☆☆ | Powerpack features hidden |
| Visual polish | ★★★☆☆ | Functional, not beautiful |
| Memory | ★★★★★ | 30-50 MB, very light |

**Key takeaway**: 100ms startup is the user-perceptible threshold. Alfred's speed + lightweight footprint set the bar.

---

## Methodology

- **Source 1**: Direct usage of Everything 1.5, Raycast (free), Spotlight (macOS 26), Alfred 5
- **Source 2**: macOS Human Interface Guidelines (HIG) — WWDC25 sessions on Liquid Glass, LazyVStack
- **Source 3**: Community patterns — Hacker News discussions, Reddit r/macapps, developer forums
- **Validation**: Cross-referenced findings across multiple apps; discarded platform-specific patterns that don't apply to macOS

## Disclaimers

- Research focused on patterns applicable to a file-search tool. General launcher patterns (calculator, snippets, clipboard) were excluded.
- Windows-specific patterns (registry-based hotkeys, MFT reading) excluded as non-applicable.
- AI features not covered — those belong to v3.0 AI research, not v3.2 UI refinement.
