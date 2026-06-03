# DeepFinder vs. The Alternatives

How DeepFinder compares to every major file search tool on macOS — and one on Windows.

**Last updated**: 2026-06-03 | **Data verified**: 2026-06-03

---

## Positioning Statement

DeepFinder is a **file search engine** for macOS. It builds and maintains its own index — independent of Spotlight — so it finds every file, every time, in under a millisecond. It is to macOS what [Everything](https://www.voidtools.com/) is to Windows: a tool you open, type a few characters, and instantly see the file you want.

DeepFinder does not try to be a launcher, a clipboard manager, a snippet expander, or a workflow automation platform. Those are solved problems — [Alfred](https://www.alfredapp.com/) and [Raycast](https://www.raycast.com/) do them well, and we recommend using them alongside DeepFinder. DeepFinder focuses on one thing: **finding files, faster and more reliably than anything else on macOS**.

If you have ever typed a filename into Spotlight and gotten nothing back — or waited while it spun — DeepFinder is for you.

---

## Comparison Matrix

Feature-by-feature across the major tools people use to find files on macOS. Windows Everything is included because it is the conceptual benchmark.

|  | DeepFinder | Everything 1.5 | Alfred 5.7 | Raycast 2.0 | Spotlight (macOS 26) | HoudahSpot 6.8 |
|---|---|---|---|---|---|---|
| **Own index (independent of Spotlight)** | ✅ Daemon + in-memory | ✅ NTFS MFT | ❌ Spotlight-dependent | ⚠️ Partial (Rust indexer, still young) | ❌ (it *is* the index) | ❌ Spotlight-dependent |
| **Search speed** | ✅ <1ms | ✅ <1ms | ⚠️ ~100ms | ⚠️ ~200ms | ⚠️ 50-100ms | ⚠️ ~100ms |
| **Substring/pinyin/prefix search** | ✅ All three | ✅ All three | ⚠️ Fuzzy learning | ⚠️ Basic | ⚠️ Basic | ✅ Multi-criteria |
| **Boolean operators (AND/OR/NOT)** | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ Visual builder |
| **Regular expressions** | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ Post-filter |
| **Content search** | ✅ PDF, DOCX, XLSX, PPTX, text, source | ✅ Via content indexing (beta) | ❌ | ❌ | ⚠️ Unreliable | ⚠️ Text only |
| **AI semantic search** | ✅ Multi-model + local Vision/Speech | ❌ | ❌ (community workflows only) | ✅ Pro tier ($8-16/mo) | ✅ Siri/ChatGPT integration | ❌ |
| **Media metadata** | ✅ Image, audio, video, PDF | ⚠️ Sidecar `.metadata.efu` | ❌ | ❌ | ⚠️ Basic | ✅ EXIF |
| **CLI** | ✅ REPL + `--json` + `--0` | ✅ ES (command-line tool) | ❌ | ❌ | ❌ (`mdfind` is separate) | ❌ |
| **GUI** | ✅ Liquid Glass + global hotkey | ✅ Native Windows | ✅ Themed panel | ✅ Modern | ✅ Native | ✅ Window |
| **Global hotkey** | ✅ ⌃⌘K (customizable) | ✅ | ✅ ⌥Space | ✅ | ✅ ⌘Space | ❌ |
| **Privacy** | ✅ Local-first, cloud AI opt-in, zero telemetry | ✅ Fully local | ✅ Fully local | ⚠️ Pro sends to cloud | ✅ System-level | ✅ Fully local |
| **Price** | **Free / Open Source** | Free / Open Source¹ | Free + £34 Powerpack | Free + $8-16/mo Pro | Free (built-in) | $34 one-time |
| **License** | MIT | MIT-like¹ | Proprietary | Proprietary | Proprietary | Proprietary |
| **Platform** | macOS 26+ (Apple Silicon M4+) | Windows only | macOS 10.14+ (Intel + AS) | macOS 26+ (v2), Windows (beta) | macOS 26+ | macOS 10.14+ |
| **RAM (500K files)** | ~180-200 MB | ~30-50 MB | 30-50 MB | 80-120 MB | System process | ~100 MB |
| **Install size** | <15 MB | <5 MB | ~10 MB | ~100 MB | Built-in | ~30 MB |
| **External dependencies** | **None** (pure Swift + Apple frameworks) | None | None | Node.js + Rust runtime | None | None |
| **External volumes / network drives** | ✅ Indexed + auto-removed | ✅ | ⚠️ Depends on Spotlight | ⚠️ Depends on indexer | ⚠️ Often fails | ⚠️ Depends on Spotlight |
| **Duplicate detection** | ✅ | ✅ (dupe-max, dupe-count) | ❌ | ❌ | ❌ | ❌ |
| **Plugin / extension ecosystem** | ❌ | ✅ SDK3 + community tools | ✅ Workflows (large library) | ✅ Extensions Store (large) | ❌ | ✅ AppleScript |

**Legend**: ✅ Full support | ⚠️ Partial, limited, or unreliable | ❌ Not available

¹ Everything is freeware with source code available; license is not OSI-approved but is permissive in practice. See [voidtools.com](https://www.voidtools.com/).

---

## Deep Dive Comparisons

### DeepFinder vs. Everything

Everything is the gold standard for file search on any platform. It reads the NTFS Master File Table directly, giving it access to every file on disk without crawling the filesystem. The result is sub-millisecond queries, a tiny memory footprint (~30-50 MB), and rock-solid reliability. Everything 1.5 (now in beta after a five-year alpha) has added content indexing, pinyin search, dark mode, and an undo system — making it arguably the best file search tool in existence.

DeepFinder is built on the same architectural principle — own the index, don't delegate to the OS — but for macOS. Where Everything reads the NTFS MFT, DeepFinder combines an FSEvents stream with a full filesystem scan and holds the result in an in-memory Trie + FullSubstringMap. The query speed is comparable (sub-millisecond), but the memory cost is higher (~180-200 MB vs. 30-50 MB) because macOS has no MFT equivalent. DeepFinder also goes beyond Everything in several areas: AI semantic search (natural language queries, vision tagging, speech input), multi-format content search (PDF, Office documents, source code), and media metadata extraction (image EXIF, audio tags, video codec info). Everything is the better pure filename search engine; DeepFinder is a broader file intelligence platform.

The biggest practical difference is platform. If you are on Windows, use Everything — there is no reason to look elsewhere. If you are on macOS and want Everything-level reliability, DeepFinder is the closest thing available.

### DeepFinder vs. Alfred / Raycast

Alfred and Raycast are **launchers**, not file search engines. They are excellent at what they do — launch apps, run workflows, manage clipboards, expand snippets, control music — and we genuinely recommend them for those tasks. Many DeepFinder users run Alfred or Raycast alongside it.

The distinction matters because their file search is built on Spotlight. When you search for a file in Alfred or Raycast, you are searching Spotlight's index with a different UI. That means you inherit every Spotlight limitation: silently skipped directories, index corruption requiring `mdutil -E` rebuilds, files that appear in Finder but not in search results, and a query syntax limited to basic keyword matching. Alfred adds fuzzy learning on top, and Raycast 2.0 is building its own Rust-based file indexer to reduce Spotlight dependence — but as of mid-2026, neither matches the completeness or speed of a dedicated index.

Raycast 2.0's AI features (Quick AI with GPT-5 mini, AI dictation, AI chat) overlap conceptually with DeepFinder's AI semantic search, but they serve different purposes. Raycast AI is a general-purpose assistant in a command palette; DeepFinder AI is purpose-built for file discovery — it translates natural language into search syntax, tags images with Vision models, and transcribes speech to queries. Raycast AI is broader; DeepFinder AI is deeper for the specific domain of files.

**Bottom line**: Use Alfred or Raycast for launching and workflows. Use DeepFinder when you need to actually find a file.

### DeepFinder vs. Spotlight

Spotlight is built into macOS, requires no installation, and works well enough for simple app launching and basic file name searches. In macOS 26, Apple gave Spotlight its biggest overhaul in a decade: four dedicated modes (Apps, Files, Actions, Clipboard), a built-in clipboard history, Quick Keys for action shortcuts, and Siri/ChatGPT integration for natural language queries.

However, Spotlight's fundamental architecture has not changed. It remains a black-box index maintained by system processes (`mds`, `mdworker`) that users cannot inspect, debug, or reliably rebuild. When Spotlight works, it works. When it doesn't — corrupted index, silently skipped directories, inconsistent results — the user's only recourse is `sudo mdutil -E /` and a multi-hour rebuild with no progress indicator. This is not a theoretical problem; "Spotlight not finding files" is a perennial top result in Apple Support Communities.

DeepFinder's independent index eliminates this class of failure entirely. The daemon scans what you tell it to scan, indexes what it finds, and reports exactly what is in the index (`:stats` in the REPL). There is no black box. If a file is on disk and in an indexed location, DeepFinder will find it — every time.

Spotlight has also become notably more complex in macOS 26, absorbing features that used to live in separate apps (Launchpad, clipboard manager). For users who prefer tools that do one thing well, DeepFinder's focused scope is a feature, not a limitation.

### DeepFinder vs. HoudahSpot

HoudahSpot is a power user's search tool that layers a sophisticated query builder on top of Spotlight. It excels at complex, multi-criteria searches: "all PDF files modified this week, larger than 1 MB, containing the phrase 'quarterly report', in these three folders but not that subfolder." Its template system lets you save these searches for reuse. For users who need to construct and save detailed search criteria, HoudahSpot has no equal on macOS.

The tradeoff is that HoudahSpot is fundamentally a saved-search tool, not a real-time finder. You build a query, press Return, and wait for results — typically 100-300ms through Spotlight. There is no type-as-you-search instant feedback loop. The UI is window-based with traditional controls, not a keyboard-first overlay. And because it depends on Spotlight, it cannot find files that Spotlight has missed.

DeepFinder takes the opposite approach: real-time results on every keystroke, keyboard-first navigation, and an independent index that does not miss files. It is better for the "I know roughly what I'm looking for and want it now" workflow. HoudahSpot is better for the "I need to find every file matching these exact criteria across seven folders, and I want to save that search for next quarter" workflow. They are complementary; some power users will want both.

---

## When to Use What

A decision guide based on what you actually need to do.

**"I just want to find a file, fast."**
→ **DeepFinder**. Type a few characters, see results instantly. No configuration needed.

**"I want to launch apps and run automation workflows."**
→ **Alfred** or **Raycast**. This is what launchers do best. DeepFinder is not a launcher and does not try to be one.

**"I need to search inside files — PDFs, Word docs, source code."**
→ **DeepFinder** (multi-format content index) or **HoudahSpot** (text content via Spotlight). DeepFinder supports more formats; HoudahSpot offers more query criteria.

**"I want to find files using natural language."**
→ **DeepFinder** (free, local-first, multi-model AI) or **Raycast Pro** ($8/mo, cloud AI). DeepFinder also offers on-device Vision and Speech models for privacy-sensitive use.

**"I need complex Boolean searches with a visual query builder."**
→ **HoudahSpot**. Its template and criteria system is unmatched for this use case.

**"I need to find files Spotlight is missing — just this once."**
→ **EasyFind** or **Find Any File** (free, filesystem brute-force). DeepFinder is for daily use; these are for one-off deep scans.

**"I am scripting or automating file search in a pipeline."**
→ **DeepFinder** (`--json`, `--0`, HTTP API) or **`mdfind`** (Spotlight's CLI, built in). DeepFinder's output formats are designed for programmatic consumption.

**"I'm on Windows."**
→ **Everything**. It is the best file search tool on any platform, and it is free. DeepFinder is macOS-only.

**"I'm on an older Mac (pre-Apple Silicon, pre-macOS 26)."**
→ **Alfred**, **HoudahSpot**, or **EasyFind**. DeepFinder requires macOS 26+ on Apple Silicon M4+. This is a deliberate tradeoff to optimize for modern hardware without legacy compatibility overhead.

---

## Honest Limitations

Every tool has them. Here are DeepFinder's.

### What DeepFinder Does NOT Do Well

**Older macOS or Intel Macs.** DeepFinder requires macOS 26 (Tahoe) and Apple Silicon M4 or newer. If you are on an Intel Mac or an older macOS version, DeepFinder will not run. This is an intentional design decision — we optimize for modern hardware and Apple's latest frameworks — but it excludes a significant portion of the Mac installed base.

**RAM usage.** DeepFinder's in-memory index uses ~180-200 MB for 500K files. This is modest by modern standards (an M4 Mac has at least 16 GB unified memory), but it is 4-6x higher than Everything on Windows (~30-50 MB). The higher cost comes from macOS having no equivalent to the NTFS Master File Table — we must build the index from scratch rather than reading a pre-existing structure.

**Launcher features.** DeepFinder does not launch apps, manage clipboards, expand snippets, control music, or run automation workflows. If you want those features, use Alfred or Raycast. We deliberately stay focused on file search.

**Plugin ecosystem.** DeepFinder has no plugin API, no extension store, and no community workflow library. Alfred and Raycast have thousands of community extensions. Everything has an SDK. DeepFinder is extensible through its CLI (`--json`, `--0`) and HTTP API — you pipe results into other tools — but there is no in-app extension model.

**File operations.** DeepFinder can reveal files in Finder and open them, but it does not offer the rich file manipulation actions (batch rename with patterns, advanced copy/move with conflict resolution) that HoudahSpot and Everything provide. The undo system covers basic move/copy/rename.

**Apple Mail search.** HoudahSpot historically searched Apple Mail mailboxes. DeepFinder does not. (HoudahSpot itself lost this capability in macOS 14+ due to Apple removing the Mail plugin API.)

**Community size.** DeepFinder is a younger project than every tool on this page. Everything has been developed since 2004, Alfred since 2010, HoudahSpot since 2007. DeepFinder has a smaller user base, fewer tutorials, and less community knowledge. We are building that community, but you will find fewer "how to do X in DeepFinder" blog posts than for the established tools.

**Initial index time.** The first scan of a large disk takes 30-60 seconds. Spotlight builds its index in the background over hours. Everything reads the MFT in seconds. DeepFinder's initial scan is fast enough to not be a pain point, but it is not instant.

### What We Are Honest About Not Being

DeepFinder is not a launcher, not a workflow engine, not a clipboard manager, not a productivity suite. It is a file search engine. If you want one tool that does everything, Raycast is closer to that vision. If you want a tool that does file search exceptionally well and composes with other tools via CLI/API, DeepFinder is built for you.

---

## Performance Benchmarks

Measured on a MacBook Pro M4 Max (48 GB unified memory), 500K indexed files, warm cache. Methodology: each query run 100 times, median reported. Benchmark script available in the [DeepFinder repository](https://github.com/nadav-cheung/DeepFinder).

| Query | DeepFinder | Spotlight (mdfind) | Alfred 5.7 | Everything 1.5¹ |
|---|---|---|---|---|
| `report` (substring, 12K results) | **0.8ms** | 85ms | 95ms | **0.3ms** |
| `ext:pdf dm:today` (filtered, 45 results) | **0.4ms** | 120ms | 150ms | **0.2ms** |
| `*.swift` (wildcard, 8K results) | **0.6ms** | 95ms | 100ms | **0.2ms** |
| `regex:^report_\d{4}` (regex, 120 results) | **1.2ms** | ❌ | ❌ | **0.8ms** |
| `vacation photo` (NL → syntax, 85 results) | **280ms**² + **0.5ms** | 180ms (Siri) | ❌ | ❌ |
| Content: `"quarterly revenue"` in PDFs | **45ms**³ | ⚠️ 2-8s (unreliable) | ❌ | **380ms**⁴ |

¹ Everything benchmarks measured on Windows 11, i5-12400, NVMe SSD — different hardware, indicative only.
² AI translation time (DeepSeek API). Local models (Qwen via CoreML) add ~120ms.
³ Content search uses pre-built content index. First-time content indexing adds ~2 minutes per GB of text.
⁴ Everything 1.5 content indexing enabled, measured on 8 GB mixed-format document corpus.

> **Note**: Simple filename queries are sub-millisecond on both DeepFinder and Everything. The practical difference between 0.8ms and 0.3ms is imperceptible — both feel instant. Filtered queries (date, extension, size) are where Spotlight-dependent tools slow down because they must post-filter `mdfind` results.

---

## Pricing Comparison

What you actually pay for each tool, including free tiers and subscriptions.

| Tool | Free Tier | Paid Tier | Model |
|---|---|---|---|
| **DeepFinder** | Everything | — | Free / Open Source (MIT) |
| **Everything 1.5** | Everything | — | Freeware (source available) |
| **Alfred 5.7** | Core features (launch, search, calculator) | **£34** Powerpack (workflows, clipboard, snippets, themes) | One-time, lifetime |
| **Raycast 2.0** | Core features + 50 AI messages | **$8/mo** Pro (AI, sync, themes, unlimited clipboard); **+$8/mo** Advanced AI (best models, $16/mo total) | Subscription, annual discount (-20%) |
| **Spotlight (macOS 26)** | Everything | — | Free (built into macOS) |
| **HoudahSpot 6.8** | Free trial (limited) | **$34** single user | One-time, lifetime |

**DeepFinder's pricing model**: DeepFinder is free and open source (MIT). There is no paid tier, no subscription, no telemetry, and no plan to introduce them. AI features that use cloud models (DeepSeek, Qwen) require you to bring your own API key — we never proxy your requests or charge a markup. On-device AI features (Vision, Speech via Apple frameworks) are fully local and free.

---

## The "Everything for Mac" Gap

Windows users switching to Mac frequently ask: *"Is there an Everything for Mac?"*

The answer has traditionally been "not really." Spotlight is fast but unreliable. Alfred and Raycast delegate to Spotlight. HoudahSpot is powerful but not instant. EasyFind and Find Any File are thorough but slow.

DeepFinder is built to fill this gap. It is not a port of Everything — the architectures are necessarily different because macOS has no MFT — but it is built on the same philosophy: **own the index, trust no black box, be instant on every keystroke**.

| Everything feature | DeepFinder equivalent |
|---|---|
| Instant results on every keystroke | ✅ Sub-millisecond Trie + FullSubstringMap |
| Own index (reads NTFS MFT directly) | ✅ Own index (FSEvents + filesystem scan + in-memory) |
| Content search (beta) | ✅ Multi-format content search (PDF, Office, text, source) |
| Pinyin search | ✅ CFStringTokenizer + PinyinIndex Trie |
| Portable EXE, no install needed | ❌ Requires install (Homebrew or DMG) |
| ES command-line tool | ✅ REPL + `--json` + `--0` + HTTP API |
| Ctrl+Enter to open folder | ✅ ⌘Enter to reveal in Finder |
| Everything Server (network index) | ❌ (not planned; local-first design) |
| Windows only | ✅ macOS native, Apple Silicon optimized |
| ~30-50 MB RAM | ⚠️ ~180-200 MB (no MFT equivalent on macOS) |

**Coming from Windows Everything?** Start here: [60-Second Quick Start](tutorial/first-search.md)

---

*Don't see your favorite tool? Have a correction? Open an issue or PR on [GitHub](https://github.com/nadav-cheung/DeepFinder).*
