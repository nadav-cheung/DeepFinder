# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Everything Search — a macOS file search app rivaling Windows Everything. Menu bar app (LSUIElement=true), no Dock icon, invoked via global hotkey (⌥Space). Apple Silicon M4+ only, arm64, minimum macOS 26 (Tahoe). **Speed is the #1 priority — memory and CPU are not constraints.**

**Organization**: nadav.com.cn

**Status**: Pre-implementation. The codebase currently contains design specs only — no `Package.swift` or source code exists yet. The full architecture spec is at `docs/superpowers/specs/2026-05-26-everything-search-design.md`.

Zero external dependencies — pure Swift + Apple frameworks only (SwiftUI, Foundation, CoreServices, Carbon, SQLite3).

## Build & Test

Requires **swift-tools-version ≥ 6.2** (needed for `.macOS(.v26)` platform specifier).

```bash
swift build                              # Build
swift test                               # Run all tests
swift test --filter TrieTests            # Run single test suite
swift run                                # Run the app
```

## Planned Source Layout

```
Sources/
├── App/           # AppDelegate, StatusBarController
├── UI/            # SearchPanel/, Glow/, Settings/
├── Search/        # SearchCoordinator, SearchProvider protocol, SearchQuery, SearchResult
├── Index/         # InMemoryIndex (actor), IndexingEngine (actor), FileScanner, FSEventWatcher,
│                  # FileSystemEventStream (protocol), Trie, FullSubstringMap, TrigramIndex,
│                  # PinyinIndex, FileRecord, IndexPersistence (SQLite)
├── Hotkey/        # GlobalHotkey
└── Utils/         # FileIconCache, PathUtils

Tests/
├── IndexTests/    # Unit + performance tests for all index structures
├── SearchTests/   # Coordinator and provider contract tests
├── UITests/       # SearchPanel UI tests
├── HotkeyTests/   # Global hotkey tests
└── Fixtures/      # Shared test data generators
```

## Version Roadmap

| Version | Milestone | Deliverables | Branch |
|---------|-----------|-------------|--------|
| `v0.1.0` | Index core | FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex, fixtures, tests | `dev/v0.1` |
| `v0.2.0` | File system | FileSystemEventStream protocol, FileScanner, FSEventWatcher, IndexPersistence, index recovery | `dev/v0.2` |
| `v0.3.0` | Search | SearchProvider protocol, SearchCoordinator, performance benchmarks | `dev/v0.3` |
| `v0.4.0` | UI | SearchPanel, SearchBar, ResultsList, IntelligenceGlow, FileIconCache | `dev/v0.4` |
| `v0.5.0` | Integration | GlobalHotkey, StatusBar, AppDelegate, Settings | `dev/v0.5` |
| `v1.0.0` | Release | QuickLook, context menus, drag-and-drop, UI tests, polish | `dev/v1.0` |

**Current**: pre-`v0.1.0` (no source code yet)

**Workflow**: Each version develops on its `dev/vX.Y` branch. When deliverables pass all tests and review, merge to `main` and tag `vX.Y.Z`. Next version branches from `main`.

**Version file**: `VERSION` at repo root — single line, e.g. `0.1.0-dev`. Bump on milestone completion.

## Development Workflow

**Spec-first**: All changes start in `docs/superpowers/specs/` before touching code. When a requirement changes:
1. Update the relevant spec file in `docs/superpowers/specs/`
2. Review the spec change for consistency with the rest of the spec
3. Then implement the code change to match the updated spec

Never modify code to introduce behavior that isn't reflected in the spec, and never leave a spec out of sync with the implementation.

## Gotchas

- **Accessibility permission**: Global hotkey (RegisterEventHotKey / CGEventTap) requires Accessibility in System Settings → Privacy & Security. First launch guides user through this.
- **Full Disk Access**: FSEvents can't monitor all directories without Full Disk Access. Without it, ~/Documents, ~/Desktop, ~/Downloads silently skipped.
- **LSUIElement app**: No Dock icon — debug via Xcode attach-to-process or CLI.
- **Not sandboxable**: Needs Full Disk Access + Accessibility. Cannot go on Mac App Store. Distributed via GitHub Releases + Homebrew Cask.

## Architecture

**Data flow:** Hotkey/MenuBar → SearchPanel (NSPanel) → SearchCoordinator (no debounce for in-memory) → SearchProvider (AsyncSequence) → InMemoryIndex (actor) → results

**Dependency direction (one-way, no cycles):**
```
App → UI → Search → Index
  └→ Hotkey
```

Index layer has zero UI dependencies and can be tested in isolation.

**Concurrency model:**
- `InMemoryIndex`: actor — all read/write via actor isolation
- `IndexingEngine`: actor — coordinates FileScanner + FSEventWatcher
- `SearchCoordinator`: @MainActor — UI layer

**Key design decisions:**
- **SearchProvider protocol**: Returns `AsyncSequence<SearchResult, Never>`. MVP's in-memory index yields all results at once, but interface supports future streaming (AI, content search). `cancel(queryID:)` for cancellation.
- **InMemoryIndex (actor)**: Speed over memory (M4+ unified memory). Index structures:
  - Trie: O(k) prefix matching, Unicode scalar granularity
  - FullSubstringMap: all substrings → FileRecord.ID for names ≤64 chars, O(1) lookup
  - TrigramIndex: trigram → posting list for names >64 chars (rare fallback)
  - PinyinIndex: CFStringTokenizer → pinyin tokens in a Trie for Chinese filename search
- **Unicode**: All filenames NFC-normalized on ingestion (`precomposedStringWithCanonicalMapping`). Queries normalized the same way.
- **Persistence**: SQLite WAL at `~/.everything-search/index.db` (permissions 600). Stores FileRecord[], rebuilds index structures in memory on startup (<1s on M4). Batch writes every 5s or 100 changes.
- **FSEvents**: Abstracted behind `FileSystemEventStream` protocol. Production wraps FSEventStreamCreate, tests use MockEventStream.
- **Index state machine**: stale → verifying → live. UI displays state to user.

**Apple Intelligence glow**: AngularGradient (teal/violet/coral/amber) rotating ~1.8s, 4 layers, 60fps on M4+. Static border for reduceMotion. Paused when panel hidden.

**UI material**: macOS 26 Liquid Glass (`.glassEffect()`) for the search panel and controls. `GlassEffectContainer` for unified rendering. Apple Intelligence glow overlays on top.

**Search behavior**: Case-insensitive by default (preserves original case for display). NFC normalized. Paginated results (100 per page, "load more" button). No debounce for in-memory queries. External and network volumes indexed (removed on unmount).

## Reference

Full architecture spec: `docs/superpowers/specs/2026-05-26-everything-search-design.md`
