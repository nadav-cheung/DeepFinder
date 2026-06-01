# DeepFinder

```
  ____                 _____  __         _
 / __ \ ___   ___ ___ / __\ \/ /  ___ __| | ___  _ __
/ / _ `/ -_) / -_|_-_| _| |\  /  / -_| _` |/ -_)| '__|
\ \__/\ \__/ \___/___|_| |_|/__\ \___\__/_|\___/ |_|
 \___/
```

A blazing-fast file search engine for macOS, inspired by [Everything](https://www.voidtools.com/) on Windows.

Sub-millisecond queries against a full in-memory index. Background daemon architecture. CLI + Spotlight-like GUI. Privacy-first AI features. Zero external dependencies.

## Features

### Search
- **Instant filename search** -- O(1) substring lookup via custom in-memory index structures
- **Chinese pinyin search** -- find files by typing pinyin initials or full pinyin (e.g. "jdbg" finds "季度報告.pdf")
- **Advanced query syntax** -- boolean operators (`|`, `!`), wildcards (`*.pdf`), regex, path qualifiers
- **Filters** -- `ext:pdf`, `size:>10mb`, `dm:today`, `file:`, `folder:`, metadata filters
- **Duplicate detection** -- find duplicates by name, size, or content hash
- **Content search** -- search inside files with line-level matching

### Interface
- **CLI** -- single-shot (`deepfinder "query"`) and interactive REPL with readline, tab completion, and persistent history
- **GUI** -- Spotlight-style floating panel with Liquid Glass, Apple Intelligence glow, global hotkey (`Ctrl+Cmd+K`)
- **HTTP API** -- localhost JSON endpoint for integrations (`GET /search?q=...`)
- **URL scheme** -- `deepfinder://search?q=...` for automation and browser integration
- **AppleScript** -- scriptable search commands for workflow automation

### Engine
- **Background daemon** -- holds the full index in memory, CLI/GUI are thin IPC clients (~1ms round-trip)
- **Real-time updates** -- FSEvents stream keeps the index live as files change
- **Volume support** -- indexes external and network volumes, cleans up on unmount
- **Media metadata** -- extracts and indexes image dimensions, audio tags, video info, PDF metadata
- **Persistent index** -- SQLite WAL storage survives restarts, rebuilds in-memory structures in <1s

### AI (Privacy-First)
- **Natural language search** -- type "find big videos from last week" and get structured results
- **On-device Vision** -- image analysis runs locally via Apple Vision framework, zero data leaves your Mac
- **On-device Speech** -- voice-to-search via Apple Speech framework
- **Optional cloud AI** -- DeepSeek and Qwen providers for advanced NLP (disabled by default, opt-in only)
- **Metadata-only context** -- cloud providers receive only file names, sizes, and types -- never file contents

## Requirements

- **macOS 26 (Tahoe)** or later
- **Apple Silicon M4** or later
- **Full Disk Access** permission (required for indexing all directories)
- Xcode 26+ with Swift 6.2+ toolchain

## Quick Start

### Build

```bash
git clone https://github.com/nadav/deep-finder.git
cd deep-finder
swift build
```

### Install

```bash
# Build and symlink to /usr/local/bin
make install

# Or manually:
swift build -c release
cp .build/release/DeepFinder /usr/local/bin/deepfinder
```

### First Run

```bash
# Search for a file (auto-starts daemon on first query)
deepfinder "report"

# Get JSON output for scripting
deepfinder --json "*.pdf"

# Start daemon explicitly
deepfinder daemon start

# Install as LaunchAgent (auto-start on login)
deepfinder install launch-agent
```

### CLI Examples

```bash
# Basic search
deepfinder "report"

# Filter by extension, size, and date
deepfinder "ext:pdf size:>1mb dm:thismonth"

# Boolean operators
deepfinder "report !draft"

# Wildcards
deepfinder "*.pdf"

# Regex
deepfinder "regex:^report_\\d{4}"

# Path qualifier (files in Projects directories)
deepfinder "Projects\\ report"

# Zero-separated output for xargs
deepfinder --0 "*.swift" | xargs -0 wc -l

# Daemon management
deepfinder daemon start
deepfinder daemon stop
deepfinder daemon status

# Configuration
deepfinder config get
deepfinder config set maxResults 500
```

### Interactive REPL

```bash
$ deepfinder
DeepFinder v3.0.0
> report           # search
> :stats           # show index statistics
> :open 3          # open result #3 in default app
> :reveal 3        # reveal result #3 in Finder
> :help            # show all commands
> :quit            # exit
```

### GUI

Launch the app or press `Ctrl+Cmd+K` from anywhere to open the search panel. The GUI connects to the same background daemon as the CLI.

## Architecture

```
┌─────────┐  ┌─────────┐  ┌─────────────────┐
│   CLI   │  │   GUI   │  │  HTTP / Scripts  │
└────┬────┘  └────┬────┘  └────────┬────────┘
     │            │                │
     └────────────┼────────────────┘
                  │ IPC (Unix Socket)
           ┌──────┴──────┐
           │   Daemon    │
           │  ┌────────┐ │
           │  │ Search  │ │  SearchCoordinator -> Providers
           │  └────────┘ │
           │  ┌────────┐ │
           │  │  Index  │ │  InMemoryIndex (Trie + SubstringMap + Trigram + Pinyin)
           │  └────────┘ │
           │  ┌────────┐ │
           │  │   FS   │ │  FSEventWatcher + FileScanner + VolumeManager
           │  └────────┘ │
           │  ┌────────┐ │
           │  │ Persist │ │  IndexPersistence (SQLite WAL)
           │  └────────┘ │
           └─────────────┘
```

**Data flow:** CLI/GUI sends query over Unix socket -> Daemon's SearchCoordinator dispatches to providers -> InMemoryIndex returns matches -> results flow back.

**Index structures:**
- **Trie**: O(k) prefix matching on Unicode scalars
- **FullSubstringMap**: all substrings pre-computed for names <= 64 chars, O(1) lookup
- **TrigramIndex**: trigram posting lists for long filenames (> 64 chars)
- **PinyinIndex**: Chinese character to pinyin mapping via CFStringTokenizer

All structures are value types inside an actor -- zero internal locking overhead.

## Project Structure

```
Sources/
  Index/          # FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex
  Search/         # SearchProvider, SearchCoordinator, QueryParser, SearchFilter, PatternMatcher
  FS/             # FileScanner, FSEventWatcher, VolumeManager
  Persist/        # IndexPersistence (SQLite WAL), IndexRecovery
  Daemon/         # DaemonMain, IPCServer, IPCClient, IPCProtocol, ConfigStore, LaunchAgent
  CLI/            # CLIMain, REPL, SingleShot, TerminalFormatter, ArgParser
  GUI/            # SearchPanelView, SearchViewModel, IntelligenceGlow, GlobalHotkey, Settings
  Media/          # MetadataExtractor, ImageMetadataExtractor, AudioMetadataExtractor, etc.
  Services/       # HTTPSearchService, URLSchemeHandler, SearchScriptCommand
  AI/             # AIModelProvider, NLSearchTranslator, LocalVisionProvider, etc.
Tests/
  DeepFinderTests/  # 435+ tests covering all modules
```

## AI Features

DeepFinder's AI features are designed with a privacy-first philosophy:

| Feature | Runs Where | Data Sent |
|---------|-----------|-----------|
| Natural language search translation | Cloud (opt-in) | Query text only |
| Result summarization | Cloud (opt-in) | File names, sizes, types |
| Query suggestions | Cloud (opt-in) | Query text only |
| Image similarity | On-device (Vision) | Nothing leaves your Mac |
| Voice search | On-device (Speech) | Nothing leaves your Mac |
| Cross-language search | Cloud (opt-in) | Query text only |

**All cloud features are disabled by default.** Users must explicitly configure an API key and enable AI in settings. When enabled, only file metadata (name, size, extension, dates) is ever sent to cloud providers -- never file contents.

## Development

### Setup

```bash
# Build
swift build

# Run all tests (435+)
swift test

# Run specific test suite
swift test --filter TrieTests

# Run with verbose output
swift test --verbose
```

### Test-Driven Development

This project follows strict TDD. Every new component requires:

1. Write a failing test defining expected behavior
2. Implement the minimum code to pass
3. Refactor while keeping tests green

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, TDD workflow, and PR process.

## License

MIT License. See [LICENSE](LICENSE) for details.
