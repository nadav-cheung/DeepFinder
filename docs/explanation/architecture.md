# How DeepFinder Works

A high-level overview of DeepFinder's architecture — what happens when you type a query.

## The Big Picture

```
┌─────────────┐     IPC (Unix Socket)     ┌──────────────────┐
│  CLI / GUI  │ ◄──────────────────────► │  Daemon           │
│  (thin)     │                           │  (holds index)    │
└─────────────┘                           │                   │
                                          │  InMemoryIndex    │
                                          │  ├─ Trie          │
                                          │  ├─ FullSubstringMap
                                          │  ├─ TrigramIndex  │
                                          │  └─ PinyinIndex   │
                                          │                   │
                                          │  FileScanner      │
                                          │  FSEventWatcher   │
                                          │  IndexPersistence │
                                          └──────────────────┘
                                                  │
                                                  ▼
                                          ┌──────────────────┐
                                          │  SQLite WAL       │
                                          │  (~/.deep-finder/ │
                                          │   cache/index.db) │
                                          └──────────────────┘
```

## Why a Daemon?

DeepFinder follows the **Everything model**: a background daemon builds and maintains a complete file index in memory. All clients (CLI, GUI) communicate with the daemon over a Unix domain socket. This means:

- **Index is built once**, not per-query
- **Sub-millisecond queries** — the daemon searches in-memory data structures, not the filesystem
- **Multiple clients, one index** — CLI and GUI share the same daemon
- **Changes are live** — FSEvents notifies the daemon of file changes instantly

Without a daemon, every search would need to scan the filesystem (like EasyFind) or depend on Spotlight's index (like Alfred).

## Data Flow: A Single Query

Here's what happens when you type `deepfinder "report"`:

```
1. CLI parses "report" into SearchQuery
2. CLI connects to daemon via Unix socket (~/.deep-finder/session/ipc.sock)
3. CLI sends search request (4-byte length prefix + JSON)
4. Daemon receives request → SearchCoordinator
5. SearchCoordinator queries InMemoryIndex (actor):
   - Trie lookup → prefix matches
   - FullSubstringMap lookup → substring matches
   - PinyinIndex → Chinese pinyin matches (if applicable)
6. SearchProvider yields SearchResult values as an AsyncSequence
7. Results flow back through socket to CLI
8. CLI formats and displays results (ANSI or JSON)
```

Total time from keystroke to visible results: **<1ms** for the search + socket round-trip.

## Components

| Component | What It Does |
|-----------|-------------|
| **Daemon** | Long-running background process. Owns the index. Listens on Unix socket. |
| **InMemoryIndex** | Actor-isolated index. Trie, FullSubstringMap, TrigramIndex, PinyinIndex. |
| **Trie** | O(k) prefix matching. Unicode scalar granularity. |
| **FullSubstringMap** | All substrings → FileRecord.ID for names ≤64 chars. O(1) lookup. |
| **TrigramIndex** | Trigram → posting list for names >64 chars (rare fallback). |
| **PinyinIndex** | CFStringTokenizer → pinyin tokens for Chinese filename search. |
| **FileScanner** | Walks the filesystem, building initial index. |
| **FSEventWatcher** | Listens for filesystem changes, updates index incrementally. |
| **IndexPersistence** | SQLite WAL at `~/.deep-finder/cache/index.db`. Batch writes every 5s or 100 changes. |
| **SearchCoordinator** | Orchestrates search across providers. Cancellation, pagination, sorting. |
| **CLI** | Thin client. Connects via socket, formats output, exits. |
| **GUI** | NSPanel menu bar app. Same IPC protocol as CLI. Liquid Glass design, global hotkey, Intelligence Glow animation, Quick Look preview. |
| **AI** | On-device semantic search via NL embeddings. Cloud AI providers (DeepSeek, Qwen, Anthropic, Gemini) with privacy boundaries. Speech input, Vision tagging, cross-language search, match explanation. |
| **Media** | Metadata extraction for images (EXIF), audio (ID3), video (QuickTime), and PDF documents. Stored in MediaMetadataIndex. |
| **Services** | HTTP search service for remote queries, URL scheme handler (`deepfinder://`) for app integration, SearchIntent scripting bridge. |

## Why Not Just Use Spotlight?

Spotlight uses its own index (the `mds` daemon). The problem: **it's unreliable**.

- Spotlight index corruption is the #1 Mac file search complaint
- Index rebuilds (`mdutil -E`) can take hours
- Spotlight silently skips files without notifying the user
- macOS upgrades frequently break Spotlight indexing
- No index health visibility — users don't know what's missing

DeepFinder builds its own index from scratch, independent of Spotlight. This means:
- **100% file coverage** (with Full Disk Access)
- **Index health is visible** — `:stats` shows file count, index state, memory
- **Survives macOS upgrades** — no dependency on Apple's indexing internals

## Concurrency Model

DeepFinder uses Swift actors for safe concurrency:

- **InMemoryIndex** is an actor — all reads and writes are serialized through actor isolation
- **SearchCoordinator** is an actor — coordinates search across providers without `@MainActor`
- **FileScanner** and **FSEventWatcher** coordinate through the daemon
- **CLI and GUI** are separate processes — they never share memory with the daemon

## Privacy Model

DeepFinder is **local-first by design**:

| What | Where | Notes |
|------|-------|-------|
| File index | Local RAM + SQLite | Never leaves your machine |
| Search queries | Local | Processed in-daemon |
| Vision tagging | Apple Neural Engine | On-device only |
| Speech recognition | Apple SFSpeechRecognizer | On-device only |
| AI semantic search | Cloud (opt-in) | Only if you configure an API key |
| Telemetry | None | Zero data collection |

See [Privacy Model](privacy-model.md) for details on what is and isn't sent to cloud AI providers.

---

*For the full architecture specification, see [Main Design](../superpowers/specs/design/2026-05-26-deep-finder-design.md).*
