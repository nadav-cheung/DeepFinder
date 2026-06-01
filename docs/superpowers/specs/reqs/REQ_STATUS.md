# REQ Status Tracking Matrix

**Last updated**: 2026-05-31
**Total REQs**: 116 across 18 version modules

---

## Summary

| Status | Count | Modules |
|--------|-------|---------|
| Done | 105 | v0.1, v0.2, v0.3, v0.4, v0.5, v0.6, v0.7, v1.1, v1.2, v1.3, v1.4, v1.5, v2.0, v2.1, v2.2, v3.0 |
| Partial | 4 | v1.0 (missing Homebrew/man/completions) |
| Not Started | 7 | v3.1 (Local RAG) |
| **Total** | **116** | |

### By Version

| Version | REQs | Done | Partial | Not Started |
|---------|------|------|---------|-------------|
| v0.1 Index Core | 7 | 7 | 0 | 0 |
| v0.2 File System | 5 | 5 | 0 | 0 |
| v0.3 Search | 5 | 5 | 0 | 0 |
| v0.4 Daemon + IPC | 5 | 5 | 0 | 0 |
| v0.5 CLI Single-Shot | 4 | 4 | 0 | 0 |
| v0.6 Interactive REPL | 3 | 3 | 0 | 0 |
| v0.7 Daemon Management | 3 | 3 | 0 | 0 |
| v1.0 CLI Release | 4 | 0 | 4 | 0 |
| v1.1 Advanced Syntax | 7 | 7 | 0 | 0 |
| v1.2 Metadata Filter | 8 | 8 | 0 | 0 |
| v1.3 Search Experience | 7 | 7 | 0 | 0 |
| v1.4 Content Search | 4 | 4 | 0 | 0 |
| v1.5 Duplicate Finder | 6 | 6 | 0 | 0 |
| v2.0 GUI | 13 | 13 | 0 | 0 |
| v2.1 Media Metadata | 7 | 7 | 0 | 0 |
| v2.2 Service Integration | 5 | 5 | 0 | 0 |
| v3.0 AI Semantic | 16 | 16 | 0 | 0 |
| v3.1 Local RAG | 7 | 0 | 0 | 7 |

### By Priority

| Priority | Total | Done | Partial | Not Started |
|----------|-------|------|---------|-------------|
| P0 | 73 | 64 | 3 | 6 |
| P1 | 38 | 36 | 1 | 1 |
| P2 | 5 | 5 | 0 | 0 |

---

## v0.1 -- Index Core (7 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.1-01 | FileRecord data model | done | `Sources/Index/FileRecord.swift` | `Tests/IndexTests/FileRecordTests.swift` | Codable, Sendable, NFC-normalized |
| REQ-0.1-02 | Trie prefix index | done | `Sources/Index/Trie.swift` | `Tests/IndexTests/TrieTests.swift` | Unicode scalar granularity, O(k) lookup |
| REQ-0.1-03 | FullSubstringMap | done | `Sources/Index/FullSubstringMap.swift` | `Tests/IndexTests/FullSubstringMapTests.swift` | O(1) substring lookup for names <= 64 chars |
| REQ-0.1-04 | TrigramIndex fallback | done | `Sources/Index/TrigramIndex.swift` | `Tests/IndexTests/TrigramIndexTests.swift` | Fallback for names > 64 chars |
| REQ-0.1-05 | PinyinIndex | done | `Sources/Index/PinyinIndex.swift` | `Tests/IndexTests/PinyinIndexTests.swift` | CFStringTokenizer, full-pinyin + initials Trie |
| REQ-0.1-06 | InMemoryIndex actor | done | `Sources/Index/InMemoryIndex.swift` | `Tests/IndexTests/InMemoryIndexTests.swift` | Actor-isolated, snapshot read API, batch mutations |
| REQ-0.1-07 | Test fixtures | done | `Tests/IndexTests/*` (fixture code inline) | `Tests/IndexTests/*` | FileRecordGenerator, EdgeCaseFixtures, PerformanceFixtures |

---

## v0.2 -- File System (5 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.2-01 | FileSystemEventStream protocol | done | `Sources/FS/FileSystemEventStream.swift`, `Sources/FS/MockEventStream.swift`, `Sources/FS/FSEventStreamImpl.swift` | `Tests/FSTests/FileSystemEventStreamTests.swift` | Protocol + prod impl + mock |
| REQ-0.2-02 | FileScanner full scan | done | `Sources/FS/FileScanner.swift`, `Sources/FS/VolumeManager.swift` | `Tests/FSTests/FileScannerTests.swift`, `Tests/FSTests/VolumeManagerTests.swift` | TaskGroup per-volume parallel scan, configurable exclusions |
| REQ-0.2-03 | FSEventWatcher | done | `Sources/FS/FSEventWatcher.swift` | `Tests/FSTests/FSEventWatcherTests.swift` | Index state machine: stale->verifying->live |
| REQ-0.2-04 | IndexPersistence (SQLite WAL) | done | `Sources/Persist/IndexPersistence.swift` | `Tests/PersistTests/IndexPersistenceTests.swift` | Batch writes, schema versioning, integrity check |
| REQ-0.2-05 | Index recovery | done | `Sources/Persist/IndexRecovery.swift` | `Tests/PersistTests/IndexRecoveryTests.swift` | Auto-rebuild on corruption, WAL recovery |

---

## v0.3 -- Search (5 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.3-01 | SearchProvider protocol | done | `Sources/Search/SearchProvider.swift` | `Tests/SearchTests/SearchProviderTests.swift` | AsyncSequence, cancel(), prepare() |
| REQ-0.3-02 | SearchQuery / SearchResult | done | `Sources/Search/SearchTypes.swift` | `Tests/SearchTests/SearchTypesTests.swift` | NFC + lowercase, MatchType enum, scoring |
| REQ-0.3-03 | SearchCoordinator actor | done | `Sources/Search/SearchCoordinator.swift` | `Tests/SearchTests/SearchCoordinatorTests.swift` | Multi-provider merge, dedup, auto-cancel stale queries |
| REQ-0.3-04 | Sort strategy | done | `Sources/Search/SearchSorter.swift` | `Tests/SearchTests/SearchSorterTests.swift` | MatchType > name length > frequency > date > depth |
| REQ-0.3-05 | Performance benchmarks | done | `Tests/SearchTests/SearchBenchmarks.swift` | `Tests/SearchTests/SearchBenchmarks.swift` | XCTMetric measure blocks |

---

## v0.4 -- Daemon + IPC (5 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.4-01 | DaemonMain | done | `Sources/Daemon/DaemonMain.swift` | `Tests/DaemonTests/DaemonMainTests.swift` | SIGTERM handler, PID file, singleton detection |
| REQ-0.4-02 | IPCServer | done | `Sources/Daemon/IPCServer.swift` | `Tests/DaemonTests/IPCServerTests.swift` | Unix socket, 4-byte length prefix + JSON |
| REQ-0.4-03 | IPCProtocol | done | `Sources/Daemon/IPCProtocol.swift` | `Tests/DaemonTests/IPCProtocolTests.swift` | Codable enums, protocol version, error types |
| REQ-0.4-04 | Daemon lifecycle | done | `Sources/Daemon/LaunchAgent.swift`, `Sources/Daemon/DaemonMain.swift` | `Tests/DaemonTests/LifecycleTests.swift` | LaunchAgent, auto-spawn, crash reconnect |
| REQ-0.4-05 | ConfigStore | done | `Sources/Daemon/ConfigStore.swift` | `Tests/DaemonTests/ConfigStoreTests.swift` | Atomic writes, schema versioning, IPC exposure |

---

## v0.5 -- CLI Single-Shot (4 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.5-01 | CLIMain single-shot | done | `Sources/CLI/CLIMain.swift`, `Sources/CLI/SingleShot.swift` | `Tests/CLITests/CLIMainTests.swift` | --json, --0, --sort, --limit, --reverse, --verbose |
| REQ-0.5-02 | TerminalFormatter | done | `Sources/CLI/TerminalFormatter.swift` | `Tests/CLITests/TerminalFormatterTests.swift` | ANSI highlighting, isatty() detection, path shortening |
| REQ-0.5-03 | IPCClient (CLI side) | done | `Sources/Daemon/IPCClient.swift`, `Sources/CLI/IPCClientProtocol.swift` | `Tests/CLITests/IntegrationTests.swift` | Connect, timeout, auto-spawn daemon |
| REQ-0.5-04 | CLI arg parser | done | `Sources/CLI/ArgParser.swift` | `Tests/CLITests/ArgParserTests.swift` | Manual CommandLine.arguments, subcommand routing |

---

## v0.6 -- Interactive REPL (3 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.6-01 | REPL interactive loop | done | `Sources/CLI/REPL.swift` | `Tests/CLITests/REPLTests.swift` | Darwin.readline, Ctrl+C/Ctrl+D, Tab completion |
| REQ-0.6-02 | REPL commands | done | `Sources/CLI/REPLCommands.swift` | `Tests/CLITests/REPLTests.swift` | :help, :quit, :stats, :open, :reveal, :daemon |
| REQ-0.6-03 | REPL history & navigation | done | `Sources/CLI/REPLHistory.swift` | `Tests/CLITests/REPLHistoryTests.swift` | Persistence to ~/.deep-finder/history, dedup |

---

## v0.7 -- Daemon Management (3 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-0.7-01 | daemon subcommands | done | `Sources/CLI/DaemonCommands.swift` | `Tests/CLITests/DaemonCommandsTests.swift` | start, stop, restart, status |
| REQ-0.7-02 | config subcommands | done | `Sources/CLI/ConfigCommands.swift` | `Tests/CLITests/ConfigCommandsTests.swift` | get, set, list, reset |
| REQ-0.7-03 | install subcommands | done | `Sources/CLI/InstallCommands.swift` | `Tests/CLITests/InstallCommandsTests.swift` | install/uninstall LaunchAgent plist |

---

## v1.0 -- CLI Release (4 REQs, partial)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.0-01 | CLI integration tests | done | -- | `Tests/CLITests/IntegrationTests.swift` | End-to-end single-shot, exit codes, pipe mode |
| REQ-1.0-02 | Release packaging | partial | -- | -- | Homebrew formula NOT created, man page NOT created, shell completions NOT created |
| REQ-1.0-03 | Fuzzy correction | done | `Sources/CLI/FuzzyCorrection.swift` | `Tests/CLITests/FuzzyCorrectionTests.swift` | Edit distance <= 2, suggestions to stderr |
| REQ-1.0-04 | ANSI highlighting (enhanced) | done | `Sources/CLI/TerminalFormatter.swift` | `Tests/CLITests/TerminalFormatterTests.swift` | Multi-match highlight, pinyin highlight, pipe detection |

> **Blockers for v1.0 release**: Homebrew formula (`deepfinder.rb`), man page (`deepfinder.1`), and shell completions (bash/zsh/fish) are not yet created.

---

## v1.1 -- Advanced Search Syntax (7 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.1-01 | QueryParser -- boolean expressions | done | `Sources/Search/QueryTerm.swift` | `Tests/SearchTests/QueryParserTests.swift` | AND/OR/NOT, grouping <>, phrases "", precedence |
| REQ-1.1-02 | Wildcard matching (* and ?) | done | `Sources/Search/PatternMatcher.swift` | `Tests/SearchTests/PatternMatcherTests.swift` | *.pdf optimization, prefix* optimization |
| REQ-1.1-03 | Regex support (regex: prefix) | done | `Sources/Search/PatternMatcher.swift` | `Tests/SearchTests/PatternMatcherTests.swift` | Swift Regex/ICU, cached compilation |
| REQ-1.1-04 | Path qualifiers (/, parent:, path:) | done | `Sources/Search/QueryTerm.swift` | `Tests/SearchTests/QueryParserTests.swift` | ~ expansion, NFC normalization |
| REQ-1.1-05 | Search modifiers (case:, file:, folder:, ext:) | done | `Sources/Search/QueryTerm.swift`, `Sources/Search/SearchFilter.swift` | `Tests/SearchTests/QueryParserTests.swift`, `Tests/SearchTests/SearchFilterTests.swift` | Local vs global scope rules |
| REQ-1.1-06 | SearchQuery enhanced model (QueryAST) | done | `Sources/Search/SearchTypes.swift`, `Sources/Search/QueryTerm.swift` | `Tests/SearchTests/SearchTypesTests.swift` | AST: term/wildcard/regex/and/or/not/phrase |
| REQ-1.1-07 | REPL search history persistence | done | `Sources/CLI/REPLHistory.swift` | `Tests/CLITests/REPLHistoryTests.swift` | Timestamps, result counts, :history command |

---

## v1.2 -- Metadata Filter (8 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.2-01 | Size filter (size:>1mb, size:100kb..10mb) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-02 | Date filter (dm:today, dc:thisweek) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-03 | Extension filter (ext:pdf;doc;xlsx) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-04 | File type macros (audio:, video:, pic:, doc:) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-05 | File/folder filter (file:, folder:) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-06 | Path depth filter (depth:3) | done | `Sources/Search/SearchFilter.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchFilterTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline wired to SearchCoordinator.search() |
| REQ-1.2-07 | FilterExpression model | done | `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/FilterPipelineTests.swift` | Codable model; integrated into SearchCoordinator |
| REQ-1.2-08 | Filter integration with SearchCoordinator | done | `Sources/Search/SearchCoordinator.swift`, `Sources/Search/FilterPipeline.swift` | `Tests/SearchTests/SearchCoordinatorTests.swift`, `Tests/SearchTests/FilterPipelineTests.swift` | FilterPipeline.apply() called from SearchCoordinator.search() at line 129-130 |

> v1.2 complete: `FilterPipeline` wired into `SearchCoordinator.search()`, filter parsing integrated into QueryParser pipeline, IPC `filterExpression` field present, REPL Tab completion for filter prefixes.

---

## v1.3 -- Search Experience (7 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.3-01 | Bookmarks save & restore | done | `Sources/Search/SearchBookmark.swift` | `Tests/SearchTests/SearchBookmarkTests.swift` | :bm save/list/delete/clear, CLI --bookmark |
| REQ-1.3-02 | Custom filter macros | done | `Sources/Search/SearchFilter.swift` | `Tests/SearchTests/SearchFilterTests.swift` | :filter save/list/delete, :name expansion |
| REQ-1.3-03 | Multi-dimensional result sorting | done | `Sources/Search/SearchSorter.swift` | `Tests/SearchTests/SearchSorterTests.swift`, `Tests/SearchTests/NaturalSortTests.swift` | 6 sort keys, natural sort, :sort command |
| REQ-1.3-04 | Sort preference persistence | done | `Sources/Daemon/ConfigStore.swift` | `Tests/DaemonTests/ConfigStoreTests.swift` | config.json sort field, CLI flag override |
| REQ-1.3-05 | Query autocomplete | done | `Sources/Search/AutocompleteProvider.swift` | `Tests/SearchTests/AutocompleteTests.swift` | Tab completion: commands, filters, filenames |
| REQ-1.3-06 | Bookmark & filter IPC protocol | done | `Sources/Daemon/IPCProtocol.swift` | `Tests/DaemonTests/IPCProtocolTests.swift` | IPCBookmarkRequest/Response, IPCFilterRequest/Response |
| REQ-1.3-07 | Search suggestions (empty query) | done | `Sources/CLI/REPL.swift` (suggestions panel) | `Tests/CLITests/REPLTests.swift` | Recent searches, syntax tips |

---

## v1.4 -- Content Search (4 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.4-01 | Content search provider (content:) | done | `Sources/Search/ContentSearchProvider.swift`, `Sources/Search/ContentScanner.swift` | `Tests/SearchTests/ContentSearchTests.swift` | Streaming 64KB blocks, TaskGroup parallel, 64MB file limit |
| REQ-1.4-02 | Multi-encoding support | done | `Sources/Search/ContentScanner.swift` | `Tests/SearchTests/ContentSearchTests.swift` | UTF-8, UTF-16 LE/BE, BOM detection |
| REQ-1.4-03 | Line number display | done | `Sources/Search/ContentSearchProvider.swift`, `Sources/CLI/TerminalFormatter.swift` | `Tests/SearchTests/ContentSearchTests.swift` | ContentMatch model, line:column output |
| REQ-1.4-04 | Content search performance & limits | done | `Sources/Search/ContentScanner.swift` | `Tests/SearchTests/ContentSearchTests.swift` | 512MB total I/O cap, 8 concurrent, 10k candidate limit |

---

## v1.5 -- Duplicate Finder (6 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-1.5-01 | Name duplicate (dupe:) | done | `Sources/Search/DuplicateFinder.swift` | `Tests/SearchTests/DuplicateFinderTests.swift` | Group by NFC+lowercased name |
| REQ-1.5-02 | Size duplicate (sizedupe:) | done | `Sources/Search/DuplicateFinder.swift` | `Tests/SearchTests/DuplicateFinderTests.swift` | Group by FileRecord.size, descending |
| REQ-1.5-03 | Hash duplicate (hashdupe:) | done | `Sources/Search/FileHasher.swift`, `Sources/Search/DuplicateFinder.swift` | `Tests/SearchTests/DuplicateFinderTests.swift` | Two-phase: size group -> SHA-256, prefix hash optimization |
| REQ-1.5-04 | Empty files & directories (empty:) | done | `Sources/Search/DuplicateFinder.swift` | `Tests/SearchTests/DuplicateFinderTests.swift` | Zero-byte files, empty dirs from index |
| REQ-1.5-05 | Filename length filter (len:) | done | `Sources/Search/SearchFilter.swift` | `Tests/SearchTests/SearchFilterTests.swift` | Unicode scalar count, comparison operators |
| REQ-1.5-06 | DuplicateResult model & IPC | done | `Sources/Search/DuplicateFinder.swift`, `Sources/Daemon/IPCProtocol.swift` | `Tests/SearchTests/DuplicateFinderTests.swift` | DuplicateResult/Group Codable, IPC messages |

---

## v2.0 -- GUI + Extended Index (13 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-2.0-01 | SearchPanelView (NSPanel) | done | `Sources/GUI/SearchPanelView.swift` | `Tests/GUITests/SearchPanelTests.swift` | Liquid Glass, .floating level, Esc to close |
| REQ-2.0-02 | SearchBarView | done | `Sources/GUI/SearchBarView.swift` | `Tests/GUITests/SearchBarTests.swift` | Instant search, CJK IME aware, clear button |
| REQ-2.0-03 | ResultsListView | done | `Sources/GUI/ResultsListView.swift`, `Sources/GUI/SearchViewModel.swift` | `Tests/GUITests/ResultsListTests.swift` | LazyVStack, pagination, keyboard nav |
| REQ-2.0-04 | ResultRowView | done | `Sources/GUI/ResultRowView.swift` | `Tests/GUITests/ResultRowTests.swift` | File icon, highlighted name, path, size, date |
| REQ-2.0-05 | IntelligenceGlow | done | `Sources/GUI/IntelligenceGlow.swift`, `Sources/GUI/GlassEffectContainer.swift` | `Tests/GUITests/IntelligenceGlowTests.swift` | AngularGradient, 1.8s rotation, reduceMotion |
| REQ-2.0-06 | FileIconCache | done | `Sources/GUI/ResultRowView.swift` (inline) | `Tests/GUITests/ResultRowTests.swift` | NSCache per extension, 16x16 icons |
| REQ-2.0-07 | GlobalHotkey (Control+Cmd+K) | done | `Sources/GUI/GlobalHotkey.swift`, `Sources/GUI/HotkeyPermissionHelper.swift` | `Tests/GUITests/GlobalHotkeyTests.swift` | RegisterEventHotKey + CGEventTap fallback |
| REQ-2.0-08 | StatusBarController | done | `Sources/GUI/StatusBarController.swift` | `Tests/GUITests/StatusBarControllerTests.swift` | Menu bar icon, click/right-click menu |
| REQ-2.0-09 | AppDelegate + GUI startup | done | `Sources/GUI/AppDelegate.swift` | `Tests/GUITests/AppDelegateTests.swift` | LSUIElement, Login Item, auto-connect daemon |
| REQ-2.0-10 | SettingsView | done | `Sources/GUI/SettingsView.swift`, `Sources/GUI/SettingsWindow.swift` | `Tests/GUITests/SettingsTests.swift` | Exclusions, hotkey config, auto-start toggle |
| REQ-2.0-11 | Quick Look preview | done | `Sources/GUI/QuickLookPreview.swift` | `Tests/GUITests/QuickLookPreviewTests.swift` | QLPreviewPanel, Space toggle |
| REQ-2.0-12 | Context menu | done | `Sources/GUI/ResultContextMenu.swift` | `Tests/GUITests/ResultContextMenuTests.swift` | Open, Reveal in Finder, Copy Path, Get Info |
| REQ-2.0-13 | Drag support | done | `Sources/GUI/ResultDragView.swift` | `Tests/GUITests/ResultDragViewTests.swift` | NSDraggingSource, file name badge |

---

## v2.1 -- Media Metadata (7 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-2.1-01 | MetadataExtractor protocol | done | `Sources/Media/MetadataExtractor.swift`, `Sources/Media/ExtractedMetadata.swift` | `Tests/MediaTests/MetadataExtractorRegistryTests.swift`, `Tests/MediaTests/ExtractedMetadataTests.swift` | Protocol + registry, Sendable |
| REQ-2.1-02 | ImageMetadataExtractor | done | `Sources/Media/ImageMetadataExtractor.swift` | `Tests/MediaTests/ImageMetadataExtractorTests.swift` | CGImageSource, width/height/dpi/colorSpace |
| REQ-2.1-03 | AudioMetadataExtractor | done | `Sources/Media/AudioMetadataExtractor.swift` | `Tests/MediaTests/AudioMetadataExtractorTests.swift` | AVFoundation, title/artist/album/duration |
| REQ-2.1-04 | VideoMetadataExtractor | done | `Sources/Media/VideoMetadataExtractor.swift` | `Tests/MediaTests/VideoMetadataExtractorTests.swift` | AVFoundation, width/height/duration/fps/codec |
| REQ-2.1-05 | PDFMetadataExtractor | done | `Sources/Media/PDFMetadataExtractor.swift` | `Tests/MediaTests/PDFMetadataExtractorTests.swift` | PDFKit, title/author/pages/encrypted |
| REQ-2.1-06 | MediaMetadataIndex | done | `Sources/Media/MediaMetadataIndex.swift` | `Tests/MediaTests/MediaMetadataIndexTests.swift` | Actor, async extraction, SQLite persistence |
| REQ-2.1-07 | Metadata search filters | done | `Sources/Search/SearchFilter.swift` | `Tests/MediaTests/MetadataFilterTests.swift` | width:/height:/duration:/artist: etc. |

---

## v2.2 -- Service Integration (5 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-2.2-01 | HTTPSearchService | done | `Sources/Services/HTTPSearchService.swift` | `Tests/ServicesTests/HTTPSearchServiceTests.swift` | Network.framework, localhost:7654, CORS |
| REQ-2.2-02 | URL Scheme (deepfinder://) | done | `Sources/Services/URLSchemeHandler.swift` | `Tests/ServicesTests/URLSchemeHandlerTests.swift` | deepfinder://search?q=keyword |
| REQ-2.2-03 | AppIntents (Shortcuts) | done | `Sources/Services/SearchIntent.swift` | `Tests/ServicesTests/SearchIntentTests.swift` | SearchFilesIntent, GetFileInfoIntent |
| REQ-2.2-04 | AppleScript support | done | `Sources/Services/SearchScriptCommand.swift` | `Tests/ServicesTests/SearchScriptCommandTests.swift` | NSScriptCommand, sdef dictionary |
| REQ-2.2-05 | CLI --serve mode | done | `Sources/CLI/ServeMode.swift` | `Tests/ServicesTests/ServeModeTests.swift` | Daemon + HTTP without GUI |

---

## v3.0 -- AI Semantic Search (16 REQs, done)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-3.0-01 | AIModelProvider protocol | done | `Sources/AI/AIModelProvider.swift` | `Tests/AITests/AIModelProviderTests.swift` | Sendable, capabilities, complete(), translate() |
| REQ-3.0-02 | Privacy boundary | done | `Sources/AI/FileMetadataSummary.swift`, `Sources/AI/AIContext.swift` | `Tests/AITests/FileMetadataSummaryTests.swift` | Path anonymization, no file content in AIContext |
| REQ-3.0-03 | DeepSeek integration | done | `Sources/AI/DeepSeekProvider.swift`, `Sources/AI/HTTPClient.swift` | `Tests/AITests/DeepSeekProviderTests.swift` | SSE streaming, Keychain API key, 30s timeout |
| REQ-3.0-04 | Qwen integration | done | `Sources/AI/QwenProvider.swift` | `Tests/AITests/QwenProviderTests.swift` | Same interface as DeepSeek, Keychain API key |
| REQ-3.0-05 | Natural language search | done | `Sources/AI/NLSearchTranslator.swift` | `Tests/AITests/NLSearchTranslatorTests.swift` | NL -> search syntax, editable result |
| REQ-3.0-06 | Result summarization | done | `Sources/AI/ResultSummarizer.swift` | `Tests/AITests/ResultSummarizerTests.swift` | One-sentence summary, 5-min cache |
| REQ-3.0-07 | Search advisor | done | `Sources/AI/SearchAdvisor.swift` | `Tests/AITests/SearchAdvisorTests.swift` | Tab-acceptable suggestions, stderr in single-shot |
| REQ-3.0-08 | Semantic grouping | done | `Sources/AI/SemanticGrouper.swift` | `Tests/AITests/SemanticGrouperTests.swift` | LLM classification, collapsible groups |
| REQ-3.0-09 | Match explainer | done | `Sources/AI/MatchExplainer.swift` | `Tests/AITests/MatchExplainerTests.swift` | Local rule-based, :explain N command |
| REQ-3.0-10 | LocalVision (image tagging) | done | `Sources/AI/LocalVisionProvider.swift`, `Sources/AI/VisionTaggingCoordinator.swift` | `Tests/AITests/LocalVisionProviderTests.swift`, `Tests/AITests/VisionTaggingCoordinatorTests.swift` | VNClassifyImageRequest, background indexing |
| REQ-3.0-11 | Image similarity search | done | `Sources/AI/ImageSimilaritySearch.swift` | `Tests/AITests/ImageSimilarityTests.swift` | Vision feature vectors, cosine similarity |
| REQ-3.0-12 | LocalSpeech (voice input) | done | `Sources/AI/LocalSpeechProvider.swift`, `Sources/AI/SpeechAuthorization.swift` | `Tests/AITests/LocalSpeechProviderTests.swift`, `Tests/AITests/SpeechAuthorizationTests.swift` | Speech framework, 1.5s pause trigger |
| REQ-3.0-13 | Cross-language search | done | `Sources/AI/CrossLanguageSearch.swift` | `Tests/AITests/CrossLanguageSearchTests.swift` | Cloud translation, local cache, pinyin fallback |
| REQ-3.0-14 | Natural language operations | done | `Sources/AI/NLOperations.swift` | `Tests/AITests/NLOperationsTests.swift` | Move/copy/rename with undo, user confirmation |
| REQ-3.0-15 | Privacy control panel | done | `Sources/AI/AIConfig.swift` | `Tests/AITests/AIConfigTests.swift` | ai.enabled, ai.model, ai.send_metadata, data_preview |
| REQ-3.0-16 | Clipboard search | done | `Sources/AI/ClipboardSearch.swift` | `Tests/AITests/ClipboardSearchTests.swift` | --clipboard flag, :paste command |

---

## v3.1 -- Local RAG (7 REQs, not started)

| REQ ID | Description | Status | Source Files | Test Files | Notes |
|--------|-------------|--------|-------------|------------|-------|
| REQ-3.1-01 | File content chunking | not-started | -- | -- | 256 tokens/chunk, 64 overlap, txt/md/pdf/docx/code |
| REQ-3.1-02 | Local embedding engine | not-started | -- | -- | paraphrase-multilingual-MiniLM-L12-v2 CoreML, ~470MB |
| REQ-3.1-03 | Vector index storage | not-started | -- | -- | SQLite vec extension or hnswlib, 384-dim vectors |
| REQ-3.1-04 | Incremental embedding update | not-started | -- | -- | FSEvents-driven, add/remove/update chunks |
| REQ-3.1-05 | Semantic search | not-started | -- | -- | Query embedding -> cosine similarity Top-K |
| REQ-3.1-06 | Local small model generation | not-started | -- | -- | Llama 3.2 1B/3B via MLX, 150-250 tok/s |
| REQ-3.1-07 | RAG Q&A | not-started | -- | -- | Auto-detect questions, streaming answer with file citations |

---

## Change Log

| Date | Change |
|------|--------|
| 2026-05-31 | Initial REQ status matrix created. 116 REQs across 18 modules. |
| 2026-06-01 | v1.2 REQs (01-08) corrected: FilterPipeline IS wired to SearchCoordinator (lines 129-130). All 8 v1.2 REQs moved from partial to done. Total done: 97→105. |
