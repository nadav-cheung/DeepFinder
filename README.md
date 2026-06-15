<p align="center">
<pre>
  ____                 _____  __         _
 / __ \ ___   ___ ___ / __\ \/ /  ___ __| | ___  _ __
/ / _ `/ -_) / -_|_-_| _| |\  /  / -_| _` |/ -_)| '__|
\ \__/\ \__/ \___/___|_| |_|/__\ \___\__/_|\___/ |_|
 \___/                                                </pre>
</p>

# DeepFinder

A blazing-fast file search engine for macOS, inspired by [Everything](https://www.voidtools.com/) on Windows.

Sub-millisecond queries against a full in-memory index. A background-daemon architecture with thin CLI and Spotlight-style GUI clients. Privacy-first AI features. Zero external dependencies.

[![CI](https://github.com/nadav-cheung/DeepFinder/actions/workflows/ci.yml/badge.svg)](https://github.com/nadav-cheung/DeepFinder/actions/workflows/ci.yml)
[![Release](https://github.com/nadav-cheung/DeepFinder/actions/workflows/release.yml/badge.svg)](https://github.com/nadav-cheung/DeepFinder/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-26%2B%20(Tahoe)-000000.svg)](https://www.apple.com/macos)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M4%2B-purple.svg)](https://developer.apple.com/apple-silicon)
[![Version](https://img.shields.io/badge/version-3.2.0-brightgreen.svg)](CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-1%2C450%2B-success.svg)](Tests/)

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Search Syntax](#search-syntax)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [AI Features](#ai-features)
- [Development](#development)
- [Documentation](#documentation)
- [Community](#community)
- [Acknowledgements](#acknowledgements)
- [Contributing](#contributing)
- [License](#license)

## Features

### Search
- **Instant filename search** — O(1) substring lookup via custom in-memory index structures (Trie + FullSubstringMap + Trigram + Pinyin)
- **Chinese pinyin search** — find files by pinyin initials or full pinyin (e.g. `jdbg` finds `季度報告.pdf`)
- **Advanced query syntax** — boolean operators (`|`, `!`), wildcards (`*.pdf`), regex, path qualifiers
- **Filters** — `ext:pdf`, `size:>10mb`, `dm:today`, `file:`, `folder:`, media filters (`artist:`, `width:>`, `duration:<`)
- **Duplicate detection** — find duplicates by name, size, or content hash (SHA-256)
- **Content search** — `content:term` finds files whose contents contain a string (text files only, auto-detected UTF-8/UTF-16)

### Interface
- **CLI** — single-shot (`deepfinder "query"`) and interactive REPL with readline, tab completion, and persistent history
- **GUI** — Spotlight-style floating panel with Liquid Glass, Apple Intelligence glow, global hotkey (`⌃⌘K`)
- **HTTP API** — localhost JSON endpoint for integrations (`GET /search?q=...`)
- **URL scheme** — `deepfinder://search?q=...` for automation and browser integration
- **AppleScript & Shortcuts** — scriptable search commands for workflow automation

### Engine
- **Background daemon** — holds the full index in memory; CLI/GUI are thin IPC clients (~1ms round-trip)
- **Real-time updates** — FSEvents keeps the index live as files change
- **Volume support** — indexes external and network volumes, cleans up on unmount
- **Media metadata** — extracts and indexes image dimensions, audio tags, video info, PDF metadata
- **Persistent index** — SQLite WAL storage survives restarts; rebuilds in-memory structures in <1s on M4+

### AI (Privacy-First)
- **Natural language search** — type "find big videos from last week" and get structured results
- **On-device Vision** — image analysis runs locally via Apple Vision; zero data leaves your Mac
- **On-device Speech** — voice-to-search via Apple Speech
- **Optional cloud AI** — DeepSeek, Qwen, Anthropic, and Gemini providers (disabled by default, opt-in only)
- **Metadata-only context** — cloud providers receive only file names, sizes, and types — never file contents

## Requirements

- **macOS 26 (Tahoe)** or later
- **Apple Silicon M4** or later
- **Full Disk Access** permission (required for indexing all directories)
- Xcode 26+ with Swift 6.2+ toolchain (for building from source)

## Installation

### From source

```bash
git clone https://github.com/nadav-cheung/DeepFinder.git
cd DeepFinder
swift build -c release

# Install the CLI and daemon to /usr/local/bin
cp .build/release/deepfinder       /usr/local/bin/deepfinder
cp .build/release/deepfinder-daemon /usr/local/bin/deepfinder-daemon
```

### From a release

Download the prebuilt binaries and checksums from the [latest release](https://github.com/nadav-cheung/DeepFinder/releases/latest), then verify:

```bash
shasum -a 256 -c deepfinder.zip.sha256
```

## Quick Start

```bash
# Search for a file (auto-starts the daemon on first query)
deepfinder "report"

# Get JSON output for scripting
deepfinder --json "*.pdf"

# Start the daemon explicitly
deepfinder daemon start

# Install as a LaunchAgent (auto-start on login)
deepfinder install launch-agent
```

### Interactive REPL

```bash
$ deepfinder
DeepFinder v3.2.0
> report           # search
> :stats           # show index statistics
> :open 3          # open result #3 in default app
> :reveal 3        # reveal result #3 in Finder
> :help            # show all commands
> :quit            # exit
```

### GUI

Launch the app or press `⌃⌘K` from anywhere to open the search panel. The GUI connects to the same background daemon as the CLI. See [docs/how-to/](docs/how-to/) for usage details and screenshots.

## Search Syntax

```bash
# Basic search
deepfinder "report"

# Filter by extension, size, and date
deepfinder "ext:pdf size:>1mb dm:thismonth"

# Boolean operators (AND=space, OR=|, NOT=!)
deepfinder "report !draft"

# Wildcards and regex
deepfinder "*.pdf"
deepfinder "regex:^report_\\d{4}"

# Path qualifier (files under Projects directories)
deepfinder "Projects\\ report"

# Duplicates by content hash
deepfinder "hashdupe:"

# Zero-separated output for xargs
deepfinder --0 "*.swift" | xargs -0 wc -l

# Daemon & config management
deepfinder daemon start
deepfinder daemon status
deepfinder config get
deepfinder config set maxResults 500
```

See [docs/reference/](docs/reference/) for the complete syntax reference.

## Architecture

```
┌─────────┐  ┌─────────┐  ┌─────────────────┐
│   CLI   │  │   GUI   │  │  HTTP / Scripts  │
└────┬────┘  └────┬────┘  └────────┬────────┘
     │            │                │
     └────────────┼────────────────┘
                  │ IPC (Unix domain socket, 4-byte length prefix + JSON)
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

**Data flow:** CLI/GUI sends a query over the Unix socket → the daemon's `SearchCoordinator` dispatches to providers → `InMemoryIndex` returns matches → results flow back to the client.

**Index structures** (all value types inside an actor — zero internal locking):
- **Trie** — O(k) prefix matching on Unicode scalars
- **FullSubstringMap** — all substrings pre-computed for names ≤ 64 chars, O(1) lookup
- **TrigramIndex** — trigram posting lists for long filenames (> 64 chars)
- **PinyinIndex** — Chinese-character to pinyin mapping via `CFStringTokenizer`

## Project Structure

DeepFinder is modularized into ten Swift Package Manager library targets with a one-way dependency graph (`Entry → CLI/GUI/Services → Daemon → Search/Index`, no cycles). The Index layer has zero UI/CLI dependencies and is testable in isolation.

```
Sources/
  Index/      # FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex (actor)
  Search/     # SearchCoordinator (actor), SearchProvider, QueryTerm, SearchFilter, FilterPipeline, PatternMatcher, DuplicateFinder
  FS/         # FileScanner, FSEventWatcher, VolumeManager
  Persist/    # IndexPersistence (SQLite WAL), IndexRecovery, SchemaMigrator, PathEncryption, SecretsStore
  Daemon/     # DaemonMain, IPCServer/Client/Protocol/Framing, ConfigStore, LaunchAgent
  CLI/        # CLIMain, ArgParser, SingleShot, REPL, TerminalFormatter, CLIOutputWriter
  GUI/        # SearchPanelView, SearchViewModel, IntelligenceGlow, GlobalHotkey, Settings
  Media/      # MetadataExtractor registry + Image/Audio/Video/PDF extractors
  Services/   # HTTPSearchService, URLSchemeHandler, SearchIntent, SearchScriptCommand
  AI/         # AIModelProvider, NLSearchTranslator, LocalVision/SpeechProvider, cloud providers, VectorStore
  *Entry/     # Thin executable wrappers for CLI, daemon, and GUI app
Tests/
  IndexTests/ SearchTests/ FSTests/ PersistTests/ DaemonTests/ CLITests/ GUITests/ AITests/ MediaTests/ ServicesTests/
```

## AI Features

DeepFinder's AI features are designed with a privacy-first philosophy. **All cloud features are disabled by default** — users must explicitly configure an API key and enable AI in settings. When enabled, only file metadata (name, size, extension, dates) is ever sent to cloud providers — never file contents. Usernames are sanitized to `~` before any metadata leaves the device.

| Feature | Runs Where | Data Sent |
|---------|-----------|-----------|
| Natural-language search translation | Cloud (opt-in) | Query text only |
| Result summarization | Cloud (opt-in) | File names, sizes, types |
| Query suggestions | Cloud (opt-in) | Query text only |
| Image similarity | On-device (Vision) | Nothing leaves your Mac |
| Voice search | On-device (Speech) | Nothing leaves your Mac |
| Cross-language search | Cloud (opt-in) | Query text only |

## Development

### Setup

```bash
swift build                      # Build all targets

# Run the full suite. Uses the batched runner (scripts/run-tests.sh) because
# the Swift Testing framework crashes when too many @MainActor suites run in a
# single process; every suite passes individually.
./scripts/run-tests.sh
./scripts/run-tests.sh --quick   # Skip daemon/CLI integration suites

# Run a specific suite
swift test --filter TrieTests
```

### Linting & formatting

```bash
swiftlint                        # Style/convention rules (.swiftlint.yml)
swift-format lint -r Sources/    # Apple's formatter (.swift-format)
```

This project follows strict **test-driven development**. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow, code style, and pull-request process.

## Documentation

User and reference documentation follows the [Diátaxis](https://diataxis.fr/) framework:

- [**Tutorials**](docs/tutorial/) — learn DeepFinder step by step
- [**How-to guides**](docs/how-to/) — accomplish specific tasks
- [**Reference**](docs/reference/) — search syntax, CLI, and API
- [**Explanation**](docs/explanation/) — architecture and design decisions
- [**ADR**](docs/adr/) — architecture decision records
- [Full changelog](CHANGELOG.md) · [Comparison with alternatives](docs/COMPARISON.md) · [Release process](docs/RELEASE.md)

## Community

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Governance](GOVERNANCE.md)
- [Support](SUPPORT.md)
- [Roadmap](ROADMAP.md)

## Acknowledgements

- [Everything (voidtools)](https://www.voidtools.com/) — the original sub-second Windows file search that inspired this project.
- [Raycast](https://www.raycast.com/) and [Alfred](https://www.alfredapp.com/) — keyboard-first launcher UX patterns.
- [Diátaxis](https://diataxis.fr/) — documentation structure framework.
- Apple [Vision](https://developer.apple.com/documentation/vision), [Speech](https://developer.apple.com/documentation/speech), and [PDFKit](https://developer.apple.com/documentation/pdfkit) frameworks for on-device intelligence.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, the TDD workflow, and the pull-request process. The project uses only Swift stdlib and Apple frameworks — please do not add third-party package dependencies.

## License

MIT License. See [LICENSE](LICENSE) for details.
