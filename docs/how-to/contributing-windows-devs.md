# Contributing to DeepFinder: A Guide for Windows Developers

## Welcome. You are exactly who we need.

If you have built tools against NTFS, parsed the MFT, queried the USN journal, written Everything filters, or spent years learning how Windows manages files at the kernel level — you already understand file search at a depth most macOS developers never reach. DeepFinder exists because macOS has no equivalent to Everything, and we are building it. Your expertise in what makes Everything great is the single most valuable perspective we can bring to this project.

DeepFinder is a macOS file search app built from scratch in Swift. It aims to be "Everything for Mac" — instant, complete, and relentlessly fast. We are not building a Spotlight wrapper or an Alfred plugin. We are building an independent index that finds every file, every time, with sub-millisecond query latency.

**What Windows developers bring to this project:**

- **Search syntax expertise.** Everything's query grammar is the gold standard. You know what power users expect from boolean operators, path qualifiers, regex integration, and macro systems. DeepFinder needs that vocabulary.
- **Index performance intuition.** You understand why a direct MFT scan beats `FindFirstFile` by orders of magnitude. That instinct for "what level of the stack should I be reading from" translates directly to macOS optimization decisions — even if the APIs are different.
- **Power-user mindset.** You know the difference between a tool that finds files and a tool that becomes muscle memory. Everything users don't want a search box — they want a reflex. DeepFinder must meet that bar.
- **Cross-platform perspective.** You can spot when macOS is missing something Windows does well, and when macOS has an advantage Everything never had.

This guide maps your Windows knowledge onto DeepFinder's architecture, gives you a Swift crash course, and shows you where to start.

---

## Conceptual Mapping: Everything → DeepFinder

The two systems solve the same problem on different platforms. The underlying concepts are parallel — only the terminology and APIs differ.

| Windows / Everything | macOS / DeepFinder | Notes |
|---|---|---|
| **NTFS MFT** (Master File Table) | **FSEvents + manual scan** | macOS has no MFT equivalent. DeepFinder does a full `FileManager.default.enumerator` scan on first launch, then stays current via FSEvents. The MFT is a single on-disk database; DeepFinder's "database" is a SQLite-backed cache rebuilt in memory on startup. |
| **USN Journal** (`$Extend\$UsnJrnl`) | **FSEvents event stream** | Both are persistent, per-volume change logs. USN Journal is pull-based (you enumerate records); FSEvents is push-based (callback with batched events). USN Journal survives reboots; FSEvents event IDs also persist across reboots. |
| **Everything.ini** | `~/.deep-finder/settings.json` | Configuration. Everything uses INI format; DeepFinder uses JSON. Both are human-editable, daemon-read on startup. |
| **Everything.db** | `~/.deep-finder/cache/index.db` | The persistent cache. Everything.db uses a custom binary format with BZIP compression. DeepFinder uses SQLite WAL mode, stores `FileRecord[]` rows, and rebuilds in-memory index structures at startup. |
| **ES.exe** (CLI) | `deepfinder` CLI | Single-shot command-line search. ES.exe outputs to stdout; DeepFinder supports both single-shot (`deepfinder "query"`) and interactive REPL (`deepfinder` with no args). |
| **Everything SDK** | IPC protocol (Unix domain socket) | Everything's SDK uses Windows messages or named pipes. DeepFinder uses a Unix domain socket at `~/.deep-finder/session/ipc.sock` with a 4-byte length prefix + JSON body. Both let external programs query the running index. |
| **ETW** (Event Tracing for Windows) | **OSLog + signpost** | Diagnostic tracing. ETW provides kernel-level event providers; macOS uses `os_log` and `os_signpost` for performance instrumentation. |
| **`FindFirstFile` / `FindNextFile`** | `FileManager.default.enumerator` | Recursive directory traversal. Both are the "slow path" — used for initial scan, not for live queries. DeepFinder's live queries hit the in-memory index only. |
| **`ReadDirectoryChangesW`** | `FSEventStreamCreate` | Real-time file system notification. Windows gives per-file detail; FSEvents gives per-directory batching with coalescing. DeepFinder wraps FSEvents in `FSEventWatcher` inside `Sources/FS/`. |
| **`CreateFile` on `\\.\X:`** | N/A (macOS has no raw volume access API at user level) | Everything reads the MFT directly from the raw volume. macOS does not expose raw volume I/O to user-space applications. DeepFinder works entirely through `FileManager`, `getattrlist`, and FSEvents. |
| **Admin privileges for MFT access** | **Full Disk Access** entitlement | Everything needs admin or a service for system volumes. DeepFinder needs Full Disk Access (System Settings > Privacy) to monitor `~/Documents`, `~/Desktop`, `~/Downloads`. Neither app is sandboxable. |
| **Drive letters** (`C:`, `D:`) | **Mount points** (`/Volumes/...`) | Windows uses drive letters; macOS uses a unified filesystem tree. External volumes mount under `/Volumes/`. DeepFinder indexes all mounted volumes and removes entries on unmount. |
| **`HANDLE` / `CreateFile` / `ReadFile`** | `FileHandle` / `FileManager` / `getattrlist` | Low-level file I/O. Everything uses Win32 handles with `FILE_FLAG_NO_BUFFERING` for raw MFT reads. DeepFinder uses Foundation's `FileHandle` for content scanning and `getattrlist` for bulk metadata retrieval. |
| **`DeviceIoControl` + `FSCTL_*`** | `fcntl` / `getattrlist` / `FSGetCatalogInfo` | I/O control codes for file system queries. Windows' `FSCTL_ENUM_USN_DATA` enumerates journal records; macOS uses POSIX-style `fcntl` and Carbon `getattrlist` for bulk attribute queries. |

### Key Architectural Difference

Everything's architecture is: **MFT → in-memory database → query**. The MFT is the ground truth; the USN journal is the delta. The database is a direct copy of MFT records.

DeepFinder's architecture is: **manual scan → SQLite cache → in-memory index → query**. Without MFT access, the initial scan must walk the directory tree. After that, FSEvents keeps the in-memory index synchronized. The SQLite cache is a persistence layer, not the query engine — all queries hit in-memory structures (Trie, FullSubstringMap, TrigramIndex, PinyinIndex) inside an actor-protected `InMemoryIndex`.

This means DeepFinder's startup path is more expensive than Everything's (must rebuild indexes from SQLite), but runtime query performance is comparable — sub-millisecond for in-memory structures.

---

## Swift for C++ / C# Developers: A 10-Minute Crash Course

DeepFinder is written entirely in Swift. If you write C++ or C#, you will pick up Swift quickly — the concepts are familiar, but the syntax and safety model differ.

### The Big Picture

| Concept | C++ | C# | Swift |
|---|---|---|---|
| Memory management | Manual (`new`/`delete`), smart pointers | Garbage collector | **ARC** (Automatic Reference Counting) — deterministic, no GC pauses |
| Null safety | `nullptr`, no compile-time enforcement | `null`, nullable reference types (C# 8+) | **Optionals** — `nil` is a distinct type, compiler-enforced |
| Interfaces | Abstract classes, concepts (C++20) | `interface` | **Protocols** — similar to C# interfaces but more powerful (can apply to value types) |
| Concurrency | `std::thread`, `std::mutex` | `lock`, `Task`, `async`/`await` | **Actors** — compiler-enforced isolation; no manual locks |
| Value types | `struct` (same as class, but value semantics) | `struct` (value type) | `struct` (value type, preferred over classes for most data) |
| Reference types | `class` (heap-allocated) | `class` (heap-allocated) | `class` (heap-allocated, reference-counted via ARC) |
| Generics | Templates (compile-time monomorphization) | Generics (runtime via reification) | Generics (compile-time specialization, protocol constraints) |
| Error handling | Exceptions, `std::expected` (C++23), error codes | Exceptions | `throws` / `try` / `catch` — explicit error propagation, no stack unwinding cost |
| Build system | CMake, MSBuild, Make | MSBuild, `dotnet build` | **SwiftPM** — declarative, no build scripts required |
| IDE | Visual Studio, VS Code | Visual Studio, Rider, VS Code | **Xcode** (full-featured) or **VS Code** with sourcekit-lsp |

### Syntax in 30 Seconds

```swift
// Variables: `let` is immutable, `var` is mutable
let immutable = "cannot change"
var mutable = "can change"

// Optionals: nil must be handled explicitly
var maybeString: String? = nil             // Optional<String>
if let unwrapped = maybeString {           // "if let" unwraps safely
    print(unwrapped)
}
let defaulted = maybeString ?? "fallback"  // nil-coalescing (??)

// Functions
func search(query: String, limit: Int = 100) -> [String] {
    return ["result1", "result2"]
}

// Structs (value types — preferred for data)
struct FileRecord {
    let id: UInt32
    var path: String
    var size: UInt64
}

// Classes (reference types — use when identity matters)
class SearchCoordinator {
    func execute(query: String) async throws -> [SearchResult] {
        // async/await like C#
    }
}

// Protocols (like C# interfaces, but work with structs too)
protocol SearchProvider {
    func search(query: String) -> [SearchResult]
}

// Actors — thread-safe by compiler guarantee, no locks needed
actor InMemoryIndex {
    private var trie = Trie()
    func insert(_ record: FileRecord) { ... }
    func search(_ query: String) -> [FileRecord] { ... }
}

// Extensions — add methods to any type, even system types
extension String {
    var isImageFileName: Bool { hasSuffix(".png") || hasSuffix(".jpg") }
}
```

### Key Differences from C++/C#

**1. ARC, not GC.** Swift uses Automatic Reference Counting — the compiler inserts retain/release calls. There are no GC pauses. Strong reference cycles are broken with `weak` references. This is more like `std::shared_ptr` than C# GC — but the compiler manages it for you.

**2. Optionals, not null.** In Swift, `nil` is a distinct type (`Optional<T>`). The compiler forces you to handle the nil case before accessing the value. This eliminates null-pointer crashes at compile time. Use `if let`, `guard let`, or `??` (nil-coalescing operator).

**3. Protocols, not interfaces.** Swift protocols are like C# interfaces but can be adopted by structs (value types), enums, and classes. They support default implementations (protocol extensions) and associated types (generic protocols). DeepFinder uses protocols extensively — `SearchProvider`, `FileSystemEventStream`, `EmbeddingProvider`.

**4. Actors, not locks.** Swift actors are a language-level concurrency feature. The compiler guarantees that only one task accesses an actor's state at a time — no `std::mutex`, no `lock` statements, no deadlocks (in actor-isolated code). DeepFinder's `InMemoryIndex` is an actor; all reads and writes are serialized by the Swift runtime.

**5. Value types by default.** Swift encourages structs (value types) over classes (reference types). Structs are copied on assignment, which eliminates shared-mutable-state bugs. DeepFinder's `Trie`, `FullSubstringMap`, and `TrigramIndex` are all structs — they are used inside the `InMemoryIndex` actor, so no internal synchronization is needed.

**6. No header files.** Swift has no `.h` / `.cpp` split. One `.swift` file contains both interface and implementation. Access control (`public`, `internal`, `private`) replaces header visibility.

### SwiftPM: The Build System

DeepFinder uses Swift Package Manager (SwiftPM), not MSBuild or CMake. The entire build configuration is in `Package.swift` at the repo root:

```swift
// Package.swift (simplified)
let package = Package(
    name: "DeepFinder",
    platforms: [.macOS(.v26)],  // macOS 26 (Tahoe) minimum
    targets: [
        .target(name: "DeepFinder", path: "Sources/"),
        .executableTarget(name: "DeepFinderCLI", dependencies: ["DeepFinder"], path: "Sources/CLIEntry/"),
        .executableTarget(name: "DeepFinderDaemon", dependencies: ["DeepFinder"], path: "Sources/DaemonEntry/"),
        .testTarget(name: "DeepFinderTests", dependencies: ["DeepFinder"], path: "Tests/"),
    ]
)
```

Common commands:

```bash
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter TrieTests            # Run single test suite
swift run deepfinder "query"             # CLI single-shot
swift run deepfinder                     # CLI interactive REPL
```

There is no `.sln`, no `.vcxproj`, no `.csproj`. SwiftPM discovers source files automatically — no need to list them in a project file. Dependencies are declared in `Package.swift` as URLs + version ranges. DeepFinder currently has **zero external dependencies** — pure Swift + Apple frameworks only.

### Xcode vs VS Code

- **Xcode** is the "Visual Studio" of the Apple world — full-featured, heavy, required for GUI debugging (SwiftUI previews, Instruments profiling). Download from the Mac App Store.
- **VS Code** with the Swift extension (sourcekit-lsp) works well for editing, building, and testing. DeepFinder developers use both — Xcode for GUI work and Instruments, VS Code for CLI/index work.

---

## File System Programming: Windows → macOS

This section maps the APIs you know onto their macOS equivalents.

### Directory Traversal

**Windows (C++):**
```cpp
WIN32_FIND_DATAW fd;
HANDLE hFind = FindFirstFileW(L"C:\\Users\\*", &fd);
do {
    // fd.cFileName, fd.nFileSizeLow, fd.ftLastWriteTime
} while (FindNextFileW(hFind, &fd));
FindClose(hFind);
```

**macOS (Swift):**
```swift
let enumerator = FileManager.default.enumerator(
    at: URL(fileURLWithPath: "/Users/"),
    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
    options: [.skipsHiddenFiles, .skipsPackageDescendants]
)
while let url = enumerator?.nextObject() as? URL {
    let resources = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    // resources.fileSize, resources.contentModificationDate
}
```

Key difference: `FileManager.enumerator` returns `URL` objects that lazily resolve metadata. It is slower than Everything's MFT scan (because it walks the directory tree) but faster than `FindFirstFile` on large directories (because it batches I/O internally).

### File Metadata

**Windows:** Everything reads `$STANDARD_INFORMATION` directly from MFT records to get timestamps without per-file API calls. Size comes from `$FILE_NAME` or `$DATA` attributes.

**macOS:** DeepFinder uses `URL.resourceValues(forKeys:)` for small-scale metadata and `getattrlist` for bulk queries. There is no MFT equivalent — every metadata query is a filesystem call. This is why DeepFinder's initial scan is slower than Everything's, but the in-memory index makes subsequent queries instantaneous.

### Unicode Handling

This is a critical difference that affects every string comparison.

| Aspect | Windows / NTFS | macOS / APFS |
|---|---|---|
| Filename encoding | **UTF-16LE** (NTFS stores filenames as UTF-16 in `$FILE_NAME` attribute) | **UTF-8** (APFS/HFS+ store filenames as UTF-8) |
| Normalization | **No normalization** (NTFS is byte-for-byte; two files named "café" with different Unicode representations can coexist) | **NFC-normalized** (HFS+ enforces NFD; APFS is normalization-insensitive at the filesystem level; `FileManager` returns NFC) |
| Case sensitivity | Case-insensitive (NTFS default), case-sensitive (per-directory flag) | Case-insensitive (APFS default), case-sensitive (optional APFS volume format) |
| Path separator | Backslash (`\`) | Forward slash (`/`) |
| Volume identifier | Drive letters (`C:`, `D:`) | Mount points (`/`, `/Volumes/ExternalDrive`) |

DeepFinder normalizes all filenames to NFC (`precomposedStringWithCanonicalMapping`) on ingestion and query. This prevents the "same filename, different Unicode representation" problem. Everything avoids this problem because NTFS stores whatever bytes the creating application wrote — but Everything's MFT reader must handle both representations.

### FSEvents Deep Dive

FSEvents is macOS's equivalent of the USN Journal — but with a very different API shape.

**USN Journal (Windows):**
- Pull-based: you call `DeviceIoControl(hVolume, FSCTL_ENUM_USN_DATA, ...)` with a start USN and get back records.
- Survives reboots: the journal is a persistent NTFS file.
- Per-file: each record names exactly one file and describes exactly what changed.

**FSEvents (macOS):**
- Push-based: you create an `FSEventStreamRef` with a callback, schedule it on a run loop, and receive batched events.
- Survives reboots: event IDs are persistent across reboots.
- Per-directory: by default, you only get "something changed in this directory." You must diff stat/content yourself, or enable `kFSEventStreamCreateFlagFileEvents` for per-file granularity.
- Coalescing: events within ~1 second are batched together.

DeepFinder's `FSEventWatcher` (at `Sources/FS/FSEventWatcher.swift`) wraps FSEvents with:
- Exponential backoff retry on stream failure
- Graceful degradation to polling (30s interval) after repeated failures
- File-level event granularity via `kFSEventStreamCreateFlagFileEvents`
- Volume mount/unmount detection

The abstraction is `FileSystemEventStream` protocol, which allows `MockEventStream` for testing.

### Index Structures: What Replaces the MFT Copy

Everything's in-memory database is essentially a sorted copy of MFT records. DeepFinder cannot copy a single on-disk structure, so it builds multiple specialized indexes:

| DeepFinder Structure | Purpose | Everything Analogy |
|---|---|---|
| **Trie** (`Sources/Index/Trie.swift`) | O(k) prefix matching at Unicode scalar granularity | Everything's sorted file list + binary search — but Trie gives prefix results in O(k) where k = query length |
| **FullSubstringMap** (`Sources/Index/FullSubstringMap.swift`) | All substrings → FileRecord.ID for filenames ≤ 64 chars. O(1) lookup. | Everything's "match anywhere in filename" — but precomputed rather than scanned |
| **TrigramIndex** (`Sources/Index/TrigramIndex.swift`) | Trigram → posting list for filenames > 64 chars (rare fallback). Intersection + verification. | Nothing direct in Everything — Everything scans MFT records linearly with SIMD-accelerated string matching |
| **PinyinIndex** (`Sources/Index/PinyinIndex.swift`) | Chinese filename search via pinyin tokens in a Trie. No Everything equivalent. | N/A — Everything is English/latin-centric |
| **SQLite cache** (`Sources/Persist/IndexPersistence.swift`) | Persistent `FileRecord[]` storage in WAL mode. Rebuilt into in-memory structures on startup. | `Everything.db` — but Everything.db IS the queryable database; DeepFinder's SQLite is a cache that is re-indexed into memory |

The architecture is:

```
Startup:  SQLite cache → deserialize FileRecord[] → build Trie, FullSubstringMap, TrigramIndex, PinyinIndex
Runtime:  SearchQuery → InMemoryIndex.search() → intersect index results → rank → return
Change:   FSEvent → FSEventWatcher → InMemoryIndex.insert/remove → persist batch to SQLite (every 5s or 100 changes)
```

---

## Where Your Everything Experience is Most Valuable

You don't need to know Swift fluently to make a massive impact. Here is where Windows search expertise translates directly.

### 1. Search Syntax Design

Everything's query grammar is the best in the business. DeepFinder's search syntax (in `Sources/Search/`) needs the same level of polish:

- **Boolean operators:** Everything supports `AND`, `OR`, `NOT` with grouping and implicit AND. DeepFinder has these but the precedence rules and edge cases need refinement.
- **Path qualifiers:** Everything's `\path\to\ file:` syntax. DeepFinder uses `path:` and `name:` qualifiers.
- **Size/date filters:** Everything's `size:>1mb datemodified:lastweek`. DeepFinder supports these but the date expression parser is simpler.
- **Macros and saved searches:** Everything's bookmark system and preprocessor macros (`#define:`) are features DeepFinder could adopt.
- **Regex integration:** Everything's `regex:` prefix vs. DeepFinder's `r:` prefix — similar, but error messages and performance characteristics differ.

If you have opinions on how search syntax *should* work from years of Everything usage, open an issue or dive into `Sources/Search/SearchQuery.swift`.

### 2. Index Performance Optimization

Everything's speed comes from reading the MFT directly — bypassing the file system API entirely. DeepFinder cannot do that, but the performance mindset transfers:

- **Batch metadata retrieval:** Everything reads MFT records sequentially. DeepFinder should batch filesystem calls — `getattrlist` with bulk requests, `FileManager.enumerator` with pre-fetched property keys.
- **Memory layout:** Everything packs MFT data tightly. DeepFinder's `FileRecord` is a struct; cache-line alignment and array-of-structs vs struct-of-arrays decisions matter at millions of entries.
- **Startup time:** Everything's startup is instant (MFT is always there). DeepFinder's startup involves SQLite → in-memory rebuild, which takes < 1s on M4 hardware but could degrade with very large file sets. Profile this.
- **Change batching:** Everything writes to `Everything.db` periodically. DeepFinder batches SQLite writes every 5s or 100 changes (see `Sources/Persist/IndexPersistence.swift`). The batch thresholds were chosen empirically — better tuning may be possible.

### 3. Power-User Features

Everything's power users depend on features that DeepFinder either lacks or has in early form:

- **Bookmark searches:** Everything's bookmarks sidebar. DeepFinder has a bookmark system (`:bookmark` in REPL) but no GUI sidebar equivalent yet.
- **Filters:** Everything's filter bar (Audio, Video, Document, etc.). DeepFinder has content type filtering but could use one-click filter presets.
- **Result sorting by multiple columns:** Everything's column-header click sorting. DeepFinder supports sorting but the multi-column interaction pattern is Everything's UX.
- **Export:** Everything exports to CSV/TSV. DeepFinder has `--json` output; CSV is a natural addition.
- **ETP/FTP server:** Everything's HTTP/ETP server for remote search. DeepFinder has no remote search yet — but the IPC protocol is designed for it.

### 4. Content Search Patterns

Everything's content search (`content:`) uses the system index (Windows Search) as a fallback. DeepFinder has its own content scanner (`Sources/Search/ContentScanner.swift`) that reads files directly — but it is slower than a pre-built content index. Ideas from your Windows experience:

- **Text extraction caching:** Store extracted text alongside `FileRecord` in SQLite to avoid re-reading unchanged files.
- **Incremental content indexing:** Use FSEvents to know which files changed, only re-extract those.
- **File type plugins:** Everything supports IFilter plugins for content extraction. DeepFinder could benefit from a similar plugin system for custom file formats.

### 5. The Everything SDK → IPC Protocol Bridge

If you have built tools that talk to Everything via its SDK, you understand what a good search API looks like. DeepFinder's IPC protocol (at `Sources/Daemon/IPCProtocol.swift`) is JSON-over-Unix-socket. A Windows developer who understands the Everything SDK's query/rpc model could:

- Design a CLI `--everything-compat` mode that accepts Everything-style query strings
- Build an Everything SDK emulation layer so Windows tools ported to macOS "just work"
- Write client libraries in other languages (Python, Rust, Go) against the IPC protocol

---

## Getting Started

### Prerequisites

- **macOS 26 (Tahoe) or later** — DeepFinder targets Apple Silicon (arm64) only
- **Xcode 16+** (from Mac App Store) or **Swift 6.2 toolchain** (from swift.org)
- **Full Disk Access** granted to your terminal emulator (for daemon testing)
- **Git** (pre-installed on macOS)

### Clone, Build, Run

```bash
git clone https://github.com/nadav-cheung/DeepFinder.git
cd DeepFinder
swift build          # First build — downloads nothing (zero external deps)
swift test           # Run all tests (~700 tests)
swift run deepfinder # Launch interactive REPL (auto-starts daemon)
```

Windows-specific notes:
- If you are on a Windows machine, you cannot build DeepFinder natively. Swift on Windows exists but does not support Apple frameworks (Foundation, CoreServices, Carbon, AppKit). You need a Mac — physical or cloud (MacStadium, AWS EC2 M1/M2 instances, GitHub Actions macOS runners).
- If you are on a Mac but new to it: the Terminal app is at `/Applications/Utilities/Terminal.app`. iTerm2 is a popular alternative. macOS uses `zsh` as the default shell (not PowerShell or cmd.exe).
- Line endings: macOS uses LF (`\n`), not CRLF (`\r\n`). Configure your editor to use LF. Git will handle this automatically if `core.autocrlf` is set to `input`.

### Directory Layout (for navigation)

```
Sources/
  Index/       # FileRecord, Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex
  Search/      # SearchProvider, SearchCoordinator, SearchQuery, SearchResult, ContentScanner
  FS/          # FSEventWatcher, FileScanner, VolumeManager, FileSystemEventStream protocol
  Persist/     # IndexPersistence (SQLite WAL), IndexRecovery
  Daemon/      # DaemonMain, IPCServer, IPCProtocol, IPCClient, ConfigStore
  CLI/         # CLIMain, ArgParser, REPL, TerminalFormatter
  GUI/         # SearchPanel, SearchBar, ResultsList, GlobalHotkey, Liquid Glass effects
  AI/          # NLSearchTranslator, VectorStore, EmbeddingProvider, AI providers
  Media/       # Image/Audio/Video/PDF metadata extraction
  Services/    # HTTPSearchService, URL scheme handling
Tests/
  IndexTests/ SearchTests/ FSTests/ PersistTests/ DaemonTests/ CLITests/ GUITests/ AITests/
```

### Find a Good First Issue

1. Look at GitHub Issues labeled `good first issue` or `help wanted`.
2. Search syntax improvements are the highest-impact entry point for Windows developers. Start with `Sources/Search/SearchQuery.swift` and look for divergence from Everything's behavior.
3. Content search performance optimization — if you understand Windows Search / IFilter patterns, look at `Sources/Search/ContentScanner.swift`.
4. CLI/REPL enhancements — Everything's ES.exe is a mature CLI. DeepFinder's REPL (`Sources/CLI/REPL.swift`) could benefit from tab-completion improvements, history search, and output customization.
5. Tests — DeepFinder practices TDD (test-driven development). Writing tests for existing behavior (and finding edge cases) is a great way to learn the codebase while adding value.

### Project Conventions

- **TDD required.** Write a failing test before writing implementation code. Tests live in `Tests/` and mirror the `Sources/` structure.
- **Swift style:** Follow the [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/). The project uses 4-space indentation, no tabs.
- **No external dependencies.** DeepFinder uses only Apple frameworks — Foundation, CoreServices, Carbon, SQLite3, AppKit, SwiftUI. Do not add third-party packages.
- **Documentation:** All significant types and functions have doc comments. Architecture decisions are documented in `docs/superpowers/specs/`.
- **Commit style:** Small, focused commits. One logical change per commit. The repo uses conventional commits (`feat:`, `fix:`, `docs:`, etc.).

### Join the Community

- **GitHub Discussions**: questions, feature ideas, architecture proposals
- **Issues**: bug reports, feature requests, good-first-issue listings
- **Pull Requests**: all contributions welcome, TDD expected, review by domain maintainers

---

## Further Reading

| Document | Location | What It Covers |
|---|---|---|
| Design Specification | `docs/superpowers/specs/design/2026-05-26-deep-finder-design.md` | Full architecture, data flow, concurrency model |
| REQ Index | `docs/superpowers/specs/reqs/00-overview.md` | All requirements by version with status tracking |
| User Guide | `docs/index.md` | End-user documentation index |
| CLAUDE.md | `CLAUDE.md` (repo root) | Project conventions, build commands, team roles |
| VERSION | `VERSION` (repo root) | Current version (e.g., `3.0.0`) |

---

*Everything is a trademark of voidtools. DeepFinder is not affiliated with voidtools.*

*This guide was written by the DeepFinder team, drawing on the Everything architecture documentation at voidtools.com/forum and voidtools.com/support, NTFS technical references at Microsoft Learn, and the FSEvents documentation at Apple Developer.*
