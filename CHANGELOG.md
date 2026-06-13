# Changelog

All notable changes to DeepFinder will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.2.0] — 2026-06-04

Search UI refinement — 36 deliverable REQs across three phases, GUI-only
(no daemon or IPC changes). Full reference: `docs/superpowers/specs/reqs/v3.2-search-ui.md`.

### Added

#### Phase 1 — Core Speed (keyboard-first navigation)
- REQ-3.2-04: Spinner shown only for AI queries; hidden for local queries (<50ms).
- REQ-3.2-07: Adaptive panel height (`min(screenH - box - margins, 800pt)`).
- REQ-3.2-08: ↑/↓ selection with Ctrl+N/P Emacs aliases and type-to-select.
- REQ-3.2-09: ScrollViewReader auto-scroll with `.easeOut(0.15s)`.
- REQ-3.2-10: ⌥↑/⌥↓ page navigation (~20 rows).
- REQ-3.2-12: Background-thread AttributedString highlight computation.
- REQ-3.2-14: LazyVStack + `.equatable()` virtualization (≥55 FPS at 10k results).
- REQ-3.2-17: Selection animation skipping on rapid key presses.
- REQ-3.2-19: Panel open (spring 0.25s) / close (easeOut 0.2s) animations.
- REQ-3.2-24: Enter opens file and auto-closes panel.
- REQ-3.2-25: ⌘Enter reveals file in Finder (panel stays open).
- REQ-3.2-26: Space / ⌘Y Quick Look preview synced with selection.
- REQ-3.2-27: ⌘C copy path with inline toast confirmation.
- REQ-3.2-30: Context-aware Esc (Quick Look → detail → clear text → close).
- REQ-3.2-36: CJK IME stability (no search during marked-text composition).

#### Phase 2 — Richness
- REQ-3.2-01: Rotating dynamic placeholder.
- REQ-3.2-02: Search history dropdown (↑ on empty query, last 100, JSON-persisted).
- REQ-3.2-05: Clear-button opacity animation.
- REQ-3.2-13: Result-count footer with pagination.
- REQ-3.2-18: Staggered fade-in + slide-down result animation.
- REQ-3.2-31: ⌘K action panel with fuzzy operation search.
- REQ-3.2-32: UTI grouping with sticky, collapsible headers.
- REQ-3.2-34: Friendly zero-results state with suggested next steps.
- REQ-3.2-37: Fixed bottom action bar with shortcut hints (absorbs REQ-3.2-06).

#### Phase 3 — Polish
- REQ-3.2-03: Voice-input button in search bar.
- REQ-3.2-11: ⌘↑/⌘↓ jump between type groups.
- REQ-3.2-15: 20×20pt file icons with directory child-count badges.
- REQ-3.2-16: PathShortener middle-truncation with full-path tooltip.
- REQ-3.2-20: Search-field focus border glow.
- REQ-3.2-21: IntelligenceGlow 4-layer upgrade (8-color palette, ≥55 FPS).
- REQ-3.2-22: Empty-state breathing scale animation.
- REQ-3.2-23: 0.15s hover effect (independent of keyboard selection).
- REQ-3.2-28: ⌘I file detail side panel (300pt).
- REQ-3.2-29: Tab path autocomplete into search field.
- REQ-3.2-33: Access-history weighted sorting (frequency × 0.4 + recency × 0.6).
- REQ-3.2-35: Clickable filter chips with two-way syntax sync.
- REQ-3.2-06: Merged into REQ-3.2-37 (ID retained for numbering continuity).

### Changed
- Trust LazyVStack built-in recycling over manual virtualization (`.equatable()` + fixed 40pt row height + background highlight).
- `.glassEffect()` restricted to navigation chrome per WWDC25 guidance; result rows use standard list styling.

## [3.1.0] — Deferred

Local RAG (retrieval-augmented generation) — **not released**. The 7 REQs
(REQ-3.1-01 … 07: content chunking, on-device CoreML embeddings, vector index,
semantic retrieval, local generation) require human decisions on CoreML model
selection, training/quantization, and embedding architecture, and are
therefore deferred. Version number skipped on the release line; the search-UI
work shipped directly as v3.2.0. Reference: `docs/superpowers/specs/reqs/v3.1-rag.md`.

## [3.0.0] — 2026-05-30

### Added

- REQ-3.0-01: OpenAICompatibleProvider shared base eliminating code duplication between DeepSeek and Qwen providers.
- REQ-3.0-02: NLSearchTranslator converting natural language queries to search syntax with graceful fallback.
- REQ-3.0-03: LocalVisionProvider using Vision framework for on-device image analysis (scene/object tags).
- REQ-3.0-04: ImageSimilaritySearch with feature vector extraction for visual similarity matching.
- REQ-3.0-05: ResultSummarizer generating AI-powered summaries from search result metadata.
- REQ-3.0-06: SearchAdvisor providing query optimization suggestions based on result patterns.
- REQ-3.0-07: SemanticGrouper clustering search results into meaningful categories.
- REQ-3.0-08: CrossLanguageSearch translating queries across languages for broader matching.
- REQ-3.0-09: MatchExplainer showing why each result matched (exact name, semantic, partial).
- REQ-3.0-10: LocalSpeechProvider using on-device Speech framework for voice search.
- REQ-3.0-11: ClipboardSearch automatically detecting and searching clipboard content.
- REQ-3.0-12: NLOperations framework for natural language file operations.
- REQ-3.0-13: VisionTaggingCoordinator for background image analysis and local tagging.
- REQ-3.0-14: AI-powered file operation execution with undo support.
- REQ-3.0-15: Privacy boundary enforcement — FileMetadataSummary, AIContext, AIConfig with AI OFF by default.
- REQ-3.0-16: Path sanitization (username → ~) for metadata sent to cloud AI providers.
- `Sources/AI/` module with 17 files covering 16 REQs.

### Changed

- Refactored DeepSeekProvider + QwenProvider into shared OpenAICompatibleProvider base (90%+ code reduction).

### Fixed

- CRITICAL: Actor isolation violation in HTTPSearchService — capture handlers by value before NWListener closure.
- CRITICAL: HTTP request buffering — accumulate TCP segments until full header (\r\n\r\n) received.
- IMPORTANT: LocalSpeechProvider strong reference leak in recognition callback causing SFSpeechRecognitionTask leaks.
- IMPORTANT: Cache eviction (TTL + size cap) added to ResultSummarizer and CrossLanguageSearch for long-running daemon stability.

## [2.2.0] — 2026-05-30

### Added

- REQ-2.2-01: HTTP search service via NWListener for headless web-based search.
- REQ-2.2-02: URL Scheme handler (`deepfinder://search?q=keyword`) for deep linking.
- REQ-2.2-03: Apple Shortcuts integration via AppIntents (SearchIntent).
- REQ-2.2-04: AppleScript scripting support (SearchScriptCommand).
- CLI `--serve` mode for running HTTP search server.
- `Sources/Services/` module with 4 files.

## [2.1.0] — 2026-05-30

### Added

- REQ-2.1-01: Image dimension metadata extraction (width, height, DPI via EXIF).
- REQ-2.1-02: Audio tag extraction (artist, album, title, duration via ID3/AAC).
- REQ-2.1-03: Video metadata extraction (duration, resolution, codec via AVFoundation).
- REQ-2.1-04: PDF metadata extraction (author, title, page count via PDFKit).
- REQ-2.1-05: MediaMetadataIndex actor for querying extracted metadata.
- REQ-2.1-06: Extended FileRecord with optional metadata, SearchFilter with media filter cases.
- REQ-2.1-07: FilterPipeline with metadata key parsing (e.g., `artist:`, `width:>`, `duration:<`).
- IndexPersistence schema v2 with `metadata_json` column.
- `Sources/Media/` module with 7 files (ExtractedMetadata, MetadataExtractor protocol/registry, extractors).

## [2.0.0] — 2026-05-30

### Added

- REQ-2.0-01: NSPanel floating search window with Liquid Glass material (`.glassEffect(.regular)`).
- REQ-2.0-02: Apple Intelligence glow — AngularGradient (teal/violet/coral/amber) rotating ~1.8s at 60fps.
- REQ-2.0-03: Global hotkey (default ⌃⌘K) via Carbon RegisterEventHotKey with CGEventTap fallback.
- REQ-2.0-04: Menu Bar App (LSUIElement=true, no Dock icon).
- REQ-2.0-05: Quick Look preview (Space key) for search results.
- REQ-2.0-06: Right-click context menu (Reveal in Finder, Copy Path, drag-and-drop).
- REQ-2.0-07: Hotkey conflict detection with retry backoff.
- REQ-2.0-08: Daemon auto-spawn on GUI launch.
- REQ-2.0-09: AppDelegate with LSUIElement and daemon lifecycle management.
- REQ-2.0-10: External volume indexing (USB, Thunderbolt) with index retention on unmount.
- REQ-2.0-11: Network volume indexing (SMB, AFP, NFS).
- REQ-2.0-12: Accessibility permission request flow and GUI overlay.

## [1.5.0] — 2026-05-30

### Added

- REQ-1.5-01: Name-based duplicate detection (`dupe:` filter).
- REQ-1.5-02: Size-based duplicate detection (`sizedupe:` filter).
- REQ-1.5-03: Content hash duplicate detection (`hashdupe:` filter, SHA-256).
- REQ-1.5-04: Empty directory detection (`empty:` filter).
- REQ-1.5-05: Filename length filter (`len:>N` and `len:<N`).

## [1.4.0] — 2026-05-30

### Added

- REQ-1.4-01: Full-text content search across file contents (`content:` function).
- REQ-1.4-02: Automatic encoding detection (UTF-8, UTF-16, UTF-16BE).
- REQ-1.4-03: File type limited content search (`ext:swift;py;md content:TODO`).
- REQ-1.4-04: Line number display in content search results.
- REQ-1.4-05: Streaming file read to avoid memory pressure on large files.

## [1.3.0] — 2026-05-30

### Added

- REQ-1.3-01: Search bookmarks — save search query + sort + filters for one-click recall.
- REQ-1.3-02: Custom filter presets with shortcut macros.
- REQ-1.3-03: Multi-field result sorting (name, size, date, extension, path).
- REQ-1.3-04: Natural sort (numeric-aware sorting for versioned filenames).
- REQ-1.3-05: Sort preference persistence across sessions.
- REQ-1.3-06: Local autocomplete based on search history and popular files.

## [1.2.0] — 2026-05-30

### Added

- REQ-1.2-01: File size filter (`size:>1mb`, `size:100kb..10mb` with kb/mb/gb unit support and range syntax).
- REQ-1.2-02: Date filter for modification, creation, and access dates (`dm:today`, `dc:thisweek`, range support).
- REQ-1.2-03: Extension filter (`ext:pdf;doc;xlsx` with semicolon-separated multi-extension).
- REQ-1.2-04: Predefined type macros (`audio:`, `video:`, `pic:`, `doc:`).
- REQ-1.2-05: File/folder type filtering (`file:`, `folder:`).
- REQ-1.2-06: Path depth filter (`depth:N`).

## [1.1.0] — 2026-05-30

### Added

- REQ-1.1-01: Boolean operators — AND (space), OR (`|`), NOT (`!`).
- REQ-1.1-02: Wildcard matching — `*` (any characters), `?` (single character).
- REQ-1.1-03: Regular expression search (`regex:` prefix).
- REQ-1.1-04: Path-qualified search (`Documents\ report`, `parent:~/Documents`).
- REQ-1.1-05: Search modifiers (`case:`, `file:`, `folder:`, `ext:`, `path:`).
- REQ-1.1-06: Persistent search history (last 1000 queries via readline history).

## [1.0.0] — 2026-05-30

### Added

- Complete CLI release: daemon + REPL + single-shot modes all available.
- REQ-1.0-01: Integration tests across all components.
- REQ-1.0-02: Homebrew formula for distribution.
- REQ-1.0-03: Man page (`deepfinder.1`).
- REQ-1.0-04: Shell completions for bash, zsh, and fish.
- REQ-1.0-05: Fuzzy correction for typo-tolerant search.

## [0.7.0] — 2026-05-30

### Added

- REQ-0.7-01: Daemon management subcommands (`daemon start|stop|restart|run|status`).
- REQ-0.7-02: LaunchAgent installation (`daemon install|uninstall`).
- REQ-0.7-03: Configuration management (`config get|set|list`) backed by `~/.deep-finder/config.json`.
- REQ-0.7-04: Daemon auto-start on first CLI query with socket polling (up to 5s timeout).
- REQ-0.7-05: Stale socket cleanup via PID file verification before bind.
- REQ-0.7-06: Man page and shell completions infrastructure.

## [0.6.0] — 2026-05-30

### Added

- REQ-0.6-01: Interactive REPL mode via Darwin readline (libedit).
- REQ-0.6-02: REPL commands — `:help`, `:quit`, `:stats`, `:config`, `:daemon`, `:refresh`.
- REQ-0.6-03: File interaction commands — `:open N`, `:reveal N`, `:copy-path N`, `:info N`.
- REQ-0.6-04: Paginated results with `:more` command.
- REQ-0.6-05: Persistent history (up to 1000 entries) in `~/.deep-finder/history`.
- REQ-0.6-06: Tab completion for REPL commands and file paths.
- REQ-0.6-07: Signal handling — Ctrl+C interrupts query, Ctrl+D exits REPL.

## [0.5.0] — 2026-05-30

### Added

- REQ-0.5-01: Single-shot CLI mode (`deepfinder "query"` → results → exit).
- REQ-0.5-02: Manual argument parser (CommandLine.arguments, zero external deps).
- REQ-0.5-03: Terminal output formatter with ANSI 16-color support.
- REQ-0.5-04: Format flags — `--json` (structured output), `--0`/`--null` (null-delimited, pipe-safe).
- REQ-0.5-05: Query flags — `--limit N`, `--offset N`, `--sort name|size|date|ext`.
- REQ-0.5-06: Result type filter — `--type file|folder`.
- REQ-0.5-07: Color control — `--color=auto|always|never` with `isatty()` auto-detection and `NO_COLOR`/`FORCE_COLOR` support.
- REQ-0.5-08: Match highlighting in terminal output.
- REQ-0.5-09: IPC client connecting to daemon Unix socket (4-byte length prefix + JSON protocol).
- REQ-0.5-10: Standardized exit codes (0=success, 1=no results, 2=daemon error, 3=query error).

## [0.4.0] — 2026-05-30

### Added

- REQ-0.4-01: Daemon process entry point (DaemonMain) with full startup sequence.
- REQ-0.4-02: Unix domain socket IPC server at `~/.deep-finder/ipc.sock`.
- REQ-0.4-03: Length-prefix JSON protocol — 4-byte big-endian UInt32 header + UTF-8 JSON body.
- REQ-0.4-04: IPC message types — query, status, configGet, configSet, indexRebuild, daemonStop.
- REQ-0.4-05: Concurrent client handling via DispatchSourceRead for each connection.
- REQ-0.4-06: PID file management at `~/.deep-finder/daemon.pid`.
- REQ-0.4-07: LaunchAgent plist generation for login auto-start.
- REQ-0.4-08: Graceful shutdown — SIGTERM handler flushing SQLite, saving FSEvents cursor, removing socket and PID.
- REQ-0.4-09: SIGPIPE suppression to prevent broken pipe crashes.

## [0.3.0] — 2026-05-30

### Added

- REQ-0.3-01: SearchProvider protocol with AsyncSequence-based streaming results.
- REQ-0.3-02: SearchCoordinator (plain actor, NOT @MainActor) dispatching to providers and merging results.
- REQ-0.3-03: SearchQuery and SearchResult types with match types (exact, prefix, substring, pinyin).
- REQ-0.3-04: Multi-factor result scoring — match type, name length, usage frequency, modification time, path depth.
- REQ-0.3-05: Paginated results (default 100 per page) with cursor support.
- REQ-0.3-06: Query cancellation via `cancel(queryID:)`.
- REQ-0.3-07: Performance benchmarks for prefix, substring, and pinyin queries on 1M-record datasets.

## [0.2.0] — 2026-05-30

### Added

- REQ-0.2-01: FileSystemEventStream protocol abstracting FSEvents with production (FSEventStreamImpl) and mock implementations.
- REQ-0.2-02: FileScanner for full-volume enumeration via FileManager.enumerator with TaskGroup parallelism.
- REQ-0.2-03: FSEventWatcher for real-time incremental index updates (create, delete, rename, modify events).
- REQ-0.2-04: IndexPersistence using SQLite WAL mode for durable FileRecord storage.
- REQ-0.2-05: Index recovery — SQLite validation on load, corrupt detection, automatic full rebuild fallback.
- REQ-0.2-06: Index state machine (stale → verifying → live, with error recovery).
- REQ-0.2-07: Configurable skip paths — `/System`, `/Library`, `.Trash`, `.git`, `node_modules`, `.Spotlight-V100`.
- REQ-0.2-08: Privacy exclusions — `~/Library/Caches`, `~/Library/Cookies`, `~/Library/Keychains`.
- REQ-0.2-09: Batch persistence strategy — write every 5s or every 100 changes.
- REQ-0.2-10: Schema version management via `PRAGMA user_version` with transactional migration.

### Fixed

- FSEventStreamImpl deinit data race (queue.sync in deinit).
- WAL/SHM file deletion under active SQLite connection (close-before-delete).
- Missing `/System` and `/Library` in default skip paths.
- `sinceEventID` not passed through to FSEventStreamCreate.
- Full rebuild using single-record transactions (batched to 100 per transaction).
- `execSQL` discarding SQLite error messages before capture.

## [0.1.0] — 2026-05-30

### Added

- REQ-0.1-01: FileRecord data model with Codable + Sendable conformance (id, name, path, size, dates, extension).
- REQ-0.1-02: Trie data structure for O(k) prefix matching with Unicode scalar granularity.
- REQ-0.1-03: FullSubstringMap for O(1) arbitrary substring lookup on filenames up to 64 characters.
- REQ-0.1-04: TrigramIndex fallback for filenames exceeding 64 characters (trigram → posting list → intersection).
- REQ-0.1-05: PinyinIndex for Chinese filename search via CFStringTokenizer + CFStringTransform (full pinyin and initial abbreviations).
- REQ-0.1-06: InMemoryIndex actor unifying all index structures with thread-safe reads and writes.
- REQ-0.1-07: NFC normalization on all filenames (`precomposedStringWithCanonicalMapping`).
- REQ-0.1-08: Case-insensitive search by default with original case preserved for display.
- REQ-0.1-09: Test fixtures and edge case generators.
