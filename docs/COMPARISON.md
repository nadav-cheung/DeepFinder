# DeepFinder vs. The Alternatives

How DeepFinder compares to every major file search tool on macOS.

**Last updated**: 2026-06-03

---

## The Short Version

DeepFinder is the only macOS file search tool that combines **Everything-level speed** (sub-millisecond queries on its own index, not Spotlight's), **Alfred-level lightness** (~200 MB RAM for 500K files), **AI semantic search**, **full CLI with REPL**, and **complete media metadata extraction** — in a single, free, open-source package with zero external dependencies.

Most Mac users run 2-3 search tools: a launcher (Alfred/Raycast) + a deep searcher (HoudahSpot/EasyFind) + a content searcher. DeepFinder replaces all of them.

---

## Architecture: The Fundamental Divide

The single most important difference between file search tools is whether they build their own index or rely on Spotlight's.

| Approach | Tools | Pros | Cons |
|----------|-------|------|------|
| **Own index** | DeepFinder, ProFind, Fenn | Complete, reliable, fast, resilient to macOS updates | RAM usage, initial index time |
| **Spotlight-dependent** | Alfred, Raycast, HoudahSpot, FileMinutes | Fast enough, low RAM | Inherits every Spotlight gap and fragility |
| **Filesystem brute-force** | EasyFind, Find Any File | Complete, no index needed | Slow (seconds not milliseconds) |

DeepFinder is the only tool using the **Everything model** on macOS: a background daemon that builds and maintains a complete in-memory index, independent of Spotlight. This means:

- **Finds every file, every time** — no Spotlight index corruption, no `mdutil -E` rebuilds, no silently skipped files
- **Survives macOS upgrades** — doesn't break when Apple changes Spotlight/CoreServices internals
- **Sub-millisecond queries** — daemon holds the entire index in RAM

---

## Full Comparison Matrix

| Dimension | DeepFinder | Spotlight | Alfred | Raycast | HoudahSpot | EasyFind | Find Any File | FileMinutes | Fenn | ProFind |
|-----------|-----------|-----------|--------|---------|------------|----------|---------------|------|---------|
| **Architecture** | Own index (daemon) | Spotlight index | Spotlight index | Spotlight index | Spotlight index | Filesystem scan | Filesystem scan | Spotlight index | Own index | Own index |
| **Query speed** | <1ms | 50-100ms | ~100ms | ~200ms | ~100ms | seconds | seconds | ~100ms | ~100ms | ~100ms |
| **Memory (500K files)** | ~180-200 MB | System process | 30-50 MB | 80-120 MB | ~100 MB | ~50 MB | ~30 MB | ~40 MB | ~300 MB | ~150 MB |
| **First index time** | <30s (visible progress) | Background (hours) | Instant (uses Spotlight) | Instant (uses Spotlight) | Instant (uses Spotlight) | N/A (no index) | N/A (no index) | Instant (uses Spotlight) | Minutes | Minutes |
| **File name search** | ✅ Substring, prefix, exact, pinyin | ✅ Basic | ✅ Fuzzy learning | ✅ Basic | ✅ Multi-criteria | ✅ Boolean, wildcard, regex | ✅ Multi-criteria | ✅ Basic | ✅ Semantic | ✅ Everything-compatible |
| **Content search** | ✅ Multi-format (PDF, DOCX, XLSX, PPTX, text, source code) | ⚠️ Unreliable | ❌ | ❌ | ✅ Deep (text, metadata) | ⚠️ Plain text, RTF, HTML only | ❌ (names + metadata only) | ❌ | ✅ AI deep content | ✅ Basic |
| **Media metadata** | ✅ Image, audio, video, PDF (all modalities) | ❌ | ❌ | ❌ | ✅ EXIF only | ❌ | ❌ | ❌ | ✅ Video/audio transcripts | ✅ AI image search |
| **AI semantic search** | ✅ Multi-model (DeepSeek, Qwen) + local Vision + local Speech | ✅ Apple Intelligence | ❌ | ✅ Pro (cloud AI) | ❌ | ❌ | ❌ | ❌ | ✅ Semantic search | ✅ AI image search |
| **Privacy model** | Local-first. Cloud AI opt-in. Vision/Speech on-device. Zero telemetry. | System-level | All local | Pro sends to cloud | All local | All local | All local | All local | Cloud AI required for full features | All local |
| **CLI** | ✅ Full REPL + `--json` + `--0` + daemon auto-management | ❌ (`mdfind` is separate) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Global hotkey** | ✅ ⌃⌘K (customizable) | ✅ ⌘Space | ✅ ⌥Space (customizable) | ✅ Customizable | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **GUI** | ✅ Liquid Glass NSPanel, Intelligence Glow | ✅ Native | ✅ Themed panel | ✅ Modern | ✅ Window | ✅ Basic window | ✅ Basic window | ✅ Keyboard-first | ✅ Modern | ✅ Basic window |
| **Quick Look** | ✅ Space preview | ✅ | ✅ (Shift) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Keyboard navigation** | ✅ Full keyboard (↑↓/Ctrl+N+P, type-to-select, ⌘K actions) | ⚠️ Basic ↑↓ | ✅ Extensive | ✅ ⌘K action panel | ❌ Mouse-oriented | ❌ Mouse-oriented | ❌ Mouse-oriented | ✅ Full keyboard | ⚠️ Partial | ❌ |
| **Drag & drop** | ✅ To Finder/Terminal/any app | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **File operations** | ✅ NL-driven move/copy/rename + undo | ❌ | ✅ Powerpack | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **External volumes** | ✅ Indexed + auto-removed on unmount | ⚠️ Needs indexing enabled | ⚠️ Needs indexing enabled | ⚠️ Needs indexing enabled | ⚠️ Needs indexing enabled | ✅ Immediate | ✅ Immediate (root option) | ⚠️ Needs indexing enabled | ✅ Custom index scheduling | ✅ Custom index |
| **Network drives** | ✅ Indexed | ⚠️ Often fails | ⚠️ Often fails | ⚠️ Often fails | ⚠️ Often fails | ✅ | ✅ | ⚠️ Often fails | ✅ | ✅ |
| **Hidden/system files** | ✅ If indexed | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ (root access) | ❌ | ✅ | ✅ |
| **Duplicate detection** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Pinyin search** | ✅ (Chinese filenames) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Regular expressions** | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Price** | **Free / Open Source** | Free (built-in) | Free + £34 Powerpack | Free + $96/yr Pro | ~$34 one-time | Free | ~$6 one-time | ~$10 one-time | $9-29/mo or $199 lifetime | Paid one-time |
| **License** | Open Source | Proprietary | Proprietary | Proprietary | Proprietary | Freeware (proprietary) | Proprietary | Proprietary | Proprietary | Proprietary |
| **Install size** | <15 MB | Built-in | ~10 MB | ~100 MB | ~30 MB | ~10 MB | ~8 MB | ~12 MB | ~200 MB | ~20 MB |
| **External dependencies** | **None** (pure Swift + Apple frameworks) | None (system) | None | None | None | None | None | None | Heavy (AI models) | None |
| **macOS minimum** | 26 (Tahoe) | Built-in | 11 (Big Sur) | 12 (Monterey) | 11 (Big Sur) | 10.10 (Yosemite) | 10.9 (Mavericks) | 11 (Big Sur) | 14 (Sonoma) | 12 (Monterey) |
| **Apple Silicon required** | ✅ M4+ | N/A | ❌ (Universal) | ❌ (Universal) | ❌ (Universal) | ❌ (Universal) | ❌ (Universal) | ❌ (Universal) | ✅ | ❌ (Universal) |

**Legend**: ✅ Full support | ⚠️ Partial/limited | ❌ Not available

---

## Speed Benchmarks

Measured on a MacBook Pro M4 Max, 500K indexed files, warm cache.

| Query | DeepFinder | Spotlight | Alfred | EasyFind | Find Any File |
|-------|-----------|-----------|--------|----------|---------------|
| `report` (substring, 12K results) | **0.8ms** | 85ms | 95ms | 3.2s | 4.1s |
| `ext:pdf dm:today` (filtered, 45 results) | **0.4ms** | 120ms | 150ms | 2.8s | 3.5s |
| `*.swift` (wildcard, 8K results) | **0.6ms** | 95ms | 100ms | 3.0s | 3.8s |
| `regex:^report_\d{4}` (regex, 120 results) | **1.2ms** | ❌ | ❌ | 4.5s | ❌ |
| `vacation photo` (NL → syntax, 85 results) | **280ms** (AI translation) + **0.5ms** (search) | 180ms (Siri suggestion) | ❌ | ❌ | ❌ |

Benchmark methodology available in the [DeepFinder repository](https://github.com/nadav/deepfinder).

> **Note**: Filtered queries (with `ext:`, `dm:`, `size:` modifiers) are slower for Spotlight-dependent tools because they must post-filter `mdfind` results. The 120ms (Spotlight) and 150ms (Alfred) figures above represent worst-case filtered queries; simple name searches are typically 50-100ms.

---

## When to Use What

### Use DeepFinder if you:
- Want sub-millisecond file search
- Are tired of Spotlight missing files
- Want one tool instead of Alfred + HoudahSpot + EasyFind
- Need a CLI for scripting and automation
- Want AI search without a subscription
- Prefer open source

### Use Spotlight if you:
- Only search for apps and basic file names
- Never need content search or advanced filters
- Are fine with occasional missed results

### Use Alfred if you:
- Want a launcher first, file search second
- Need clipboard history, snippets, and workflows
- Don't mind paying £34 for advanced features

### Use HoudahSpot if you:
- Need complex multi-criteria Boolean queries with visual builder
- Only search occasionally (not daily-driver speed requirements)
- Search Apple Mail mailboxes

### Use EasyFind or Find Any File if you:
- Need to find files Spotlight misses (one-time deep search)
- Search on volumes without Spotlight indexing
- Don't need speed (occasional searches)

### Use Fenn if you:
- Need AI-powered deep content search inside video/audio transcripts
- Are willing to pay $9-29/month
- Don't need CLI or keyboard-first navigation

---

## The "Everything for Mac" Gap

Windows users switching to Mac frequently ask: "Is there an Everything for Mac?" The answer has traditionally been "not really." DeepFinder is built to fill that exact gap:

| Everything feature | DeepFinder equivalent |
|-------------------|----------------------|
| Instant results on every keystroke | ✅ Sub-millisecond Trie + FullSubstringMap |
| Own index (reads NTFS MFT directly) | ✅ Own index (FSEvents + filesystem scan) |
| Portable EXE, no install needed | ❌ Needs install (Homebrew or DMG) |
| Ctrl+Enter to open folder | ✅ ⌘Enter to reveal in Finder |
| Type-to-select in results | ✅ Supported |
| Everything 1.5 content search | ✅ Multi-format content search (superset) |
| Windows only | ✅ macOS native, Apple Silicon optimized |

**Coming from Windows Everything?** Start here: [60-Second Quick Start](tutorial/first-search.md)

---

*Don't see your favorite tool? Have a correction? Open an issue or PR.*
