# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Everything Search — a macOS file search app rivaling Windows Everything. Menu bar app (LSUIElement=true), no Dock icon, invoked via global hotkey (⌥Space). Apple Silicon M4+ only, arm64, minimum macOS 26 (Tahoe). **Speed is the #1 priority — memory and CPU are not constraints.**

**Organization**: nadav.com.cn

**Status**: `v0.1.0` in progress. Project scaffolded (Package.swift, Sources/, Tests/). FileRecord data model implemented with tests. Full architecture spec at `docs/superpowers/specs/2026-05-26-everything-search-design.md`.

Zero external dependencies — pure Swift + Apple frameworks only (SwiftUI, Foundation, CoreServices, Carbon, SQLite3).

## Build & Test

Requires **swift-tools-version ≥ 6.2** (needed for `.macOS(.v26)` platform specifier).

```bash
swift build                              # Build
swift test                               # Run all tests
swift test --filter TrieTests            # Run single test suite
swift run                                # Run the app
```

## Version Roadmap

渐进式开发，每个版本独立可用。详细功能清单见 `docs/superpowers/specs/2026-05-26-everything-search-design.md` §功能路线图。

| Version | Milestone | Key Features |
|---------|-----------|-------------|
| `v0.1.0` | Index core | FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex |
| `v0.2.0` | File system | FSEventStream, FileScanner, FSEventWatcher, IndexPersistence |
| `v0.3.0` | Search | SearchProvider protocol, SearchCoordinator, benchmarks |
| `v0.4.0` | UI | SearchPanel, ResultsList, IntelligenceGlow, FileIconCache |
| `v0.5.0` | Integration | GlobalHotkey, StatusBar, AppDelegate, Settings |
| **`v1.0`** | **核心搜索** | 完整可用：文件名搜索 + FSEvents + 热键 + UI |
| `v1.1` | 高级语法 | 布尔/通配符/正则/路径限定/修饰符/搜索历史 |
| `v1.2` | 元数据过滤 | size/date/ext/type 过滤, 高级搜索面板 |
| `v1.3` | 搜索体验 | 书签/自定义过滤器/排序/Quick Look/右键菜单 |
| `v1.4` | 内容搜索 | content: 函数, 编码支持, 行号定位 |
| `v1.5` | 重复查找 | dupe/sizedupe/hashdupe/empty/childcount |
| `v2.0` | 扩展索引 | 外置卷/网络卷/离线文件列表/Spotlight 元数据/索引日志 |
| `v2.1` | 媒体元数据 | 图片尺寸/音频标签/视频信息/PDF 元数据 |
| `v2.2` | 服务集成 | HTTP 搜索/CLI/URL Scheme/Shortcuts/AppleScript |
| `v3.0` | AI 语义 | 语义搜索/智能建议/内容理解/智能分类 |

**Current**: `v0.1.0` in progress — FileRecord ✅, remaining: Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex

**Workflow**: Each version develops on its `dev/vX.Y` branch. When deliverables pass all tests and review, merge to `main` and tag `vX.Y.Z`. Next version branches from `main`.

**Version file**: `VERSION` at repo root — single line, e.g. `0.1.0-dev`. Bump on milestone completion.

## Development Workflow

**Spec-first**: All changes start in `docs/superpowers/specs/` before touching code. When a requirement changes:
1. Update the relevant spec file in `docs/superpowers/specs/`
2. Review the spec change for consistency with the rest of the spec
3. Then implement the code change to match the updated spec

Never modify code to introduce behavior that isn't reflected in the spec, and never leave a spec out of sync with the implementation.

**Code review process**: Every code review finding must have concrete, factual evidence (file path, line number, actual behavior). Each finding goes through a second-round confirmation before entering the fix list. No speculation without evidence.

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
