# AI Pipeline Integration Plan

**Date**: 2026-06-03
**Status**: Plan (implementation pending)
**Author**: AI Integration Architect
**Dependencies**: Sources/AI/ (32 files, v3.0.0 complete), Sources/Search/, Sources/Daemon/DaemonMain.swift

---

## 1. Current State

### 1.1 What Is Built (100% Complete)

32 source files in `Sources/AI/`:

| Component | File | Status |
|-----------|------|--------|
| `NLSearchTranslator` | `NLSearchTranslator.swift` | NL query -> structured SearchQuery syntax |
| `NLEmbeddingProvider` | `NLEmbeddingProvider.swift` | On-device 512-dim embeddings (NLContextualEmbedding) |
| `EmbeddingProvider` (protocol) | `EmbeddingProvider.swift` | Protocol: `embed(text:)`, `embedBatch(texts:)`, `name`, `dimensions` |
| `VectorStore` (protocol) | `VectorStore.swift` | Protocol: `insert(id:vector:)`, `search(query:topK:)`, `delete(id:)`, `count()` |
| `CloudEmbeddingProvider` | `CloudEmbeddingProvider.swift` | Cloud embedding via OpenAI-compatible APIs |
| `AIModelProvider` (protocol) | `AIModelProvider.swift` | Protocol + `AICapability` enum (7 capabilities) |
| `ProviderRegistry` | `ProviderRegistry.swift` | 11 providers (Qwen, Zhipu, DeepSeek, OpenAI, Moonshot, MiniMax, Custom, Anthropic, Gemini, Apple) |
| `AnthropicProvider` | `AnthropicProvider.swift` | Claude Messages API |
| `DeepSeekProvider` | `DeepSeekProvider.swift` | DeepSeek API (typealias + factory) |
| `QwenProvider` | `QwenProvider.swift` | Qwen API (typealias + factory) |
| `GeminiProvider` | `GeminiProvider.swift` | Google Gemini API |
| `AIConfig` | `AIConfig.swift` | Config keys, defaults, API key management |
| `AIContext` | `AIContext.swift` | Privacy boundary type for AI consumption |
| `FileMetadataSummary` | `FileMetadataSummary.swift` | Path-anonymized file metadata |
| `PromptLoader` | `PromptLoader.swift` | Load prompt templates from disk |
| `Prompt templates` | `Prompts/` | Templates for NL translation, summarization, etc. |
| `HTTPClient` | `HTTPClient.swift` | Minimal URLSession-based HTTP client |
| `KeychainStore` | `KeychainStore.swift` | Secure API key storage |
| `VisionTaggingCoordinator` | `VisionTaggingCoordinator.swift` | On-device image tagging via Vision framework |
| `LocalVisionProvider` | `LocalVisionProvider.swift` | On-device image analysis |
| `LocalSpeechProvider` | `LocalSpeechProvider.swift` | On-device speech recognition |
| `MatchExplainer` | `MatchExplainer.swift` | Explain why a result matched |
| `ResultSummarizer` | `ResultSummarizer.swift` | AI summary of search results |
| `SearchAdvisor` | `SearchAdvisor.swift` | Query suggestion/refinement |
| `SemanticGrouper` | `SemanticGrouper.swift` | Group results by semantic meaning |
| `CrossLanguageSearch` | `CrossLanguageSearch.swift` | Cross-language filename search |
| `ClipboardSearch` | `ClipboardSearch.swift` | Search for clipboard content |
| `ImageSimilaritySearch` | `ImageSimilaritySearch.swift` | Visually similar images via embeddings |
| `NLOperations` | `NLOperations.swift` | Safe natural-language file operation parsing |
| `SpeechAuthorization` | `SpeechAuthorization.swift` | Speech recognition permission management |
| `SecretsStore` | `SecretsStore.swift` | Secure storage for API keys |

### 1.2 What Is Wired (0%)

Current `DaemonMain.run()` (line 399-403):

```swift
// 5. Create SearchCoordinator
let fileProvider = FileIndexProvider(index: index)
await fileProvider.prepare()
let coordinator = SearchCoordinator(providers: [fileProvider])
self.coordinator = coordinator
```

**Zero AI providers are registered.** The SearchCoordinator only has `FileIndexProvider` and `ContentSearchProvider` (the latter also apparently not registered in the daemon startup). There is no `AISearchProvider`. The VectorStore protocol has no concrete implementation. Embeddings are never computed for indexed files. NL translation is never invoked in the search pipeline.

### 1.3 Architecture Diagram: Current vs Target

```
CURRENT (v3.0.0)                        TARGET (v3.1)
========================                ========================

User Query                               User Query
    |                                        |
    v                                        v
IPCServer.receive()                    NLSearchTranslator.translate()
    |                                   (NL -> structured syntax)
    v                                        |
SearchCoordinator.search()                   v
    |                                   SearchCoordinator.search()
    v                                        |
FileIndexProvider ──────┐                    ├── FileIndexProvider (keyword)
  (keyword only)         |                   ├── ContentSearchProvider
                         |                   └── AISearchProvider (semantic) ← NEW
                         v                        |
              deduplicate ── sort ── results      ├── NLSearchTranslator
                                                   ├── NLEmbeddingProvider
                                                   └── VectorStore (concrete)
                                                        |
                                              deduplicate ── fusion ── sort ── results
```

---

## 2. Target Architecture

### 2.1 Search Pipeline with AI

```
User Query (string)
    │
    ├── NL Detection: does query look like natural language?
    │   (e.g., "find photos from last month" vs "*.jpg dm:lastmonth")
    │
    ├── [YES, AI enabled] ──> NLSearchTranslator.translate()
    │   "find photos from last month" ──> "ext:jpg;png;heic dm:lastmonth"
    │
    └── [NO or AI disabled] ──> use raw query as-is
    │
    v
SearchCoordinator.search(query, filters)
    │
    ├── FileIndexProvider.search(query)     ──> keyword results (ranked by match type)
    ├── ContentSearchProvider.search(query) ──> content results
    └── AISearchProvider.search(query)      ──> semantic results (ranked by cosine similarity)
    │
    v
Deduplicate by FileRecord.id (existing logic: keep highest-priority match)
    │
    v
Fusion: merge scores for files appearing in multiple provider results
    │
    v
FilterPipeline.apply(filters)
    │
    v
SearchSorter.sort(by: .relevance)
    │
    v
Results (capped at resultLimit)
```

### 2.2 New MatchType for Semantic Results

Add a new `MatchType` case:

```swift
enum MatchType: Int, Codable, Comparable, Sendable {
    case exact = 0
    case prefix = 1
    case pinyin = 2
    case substring = 3
    case semantic = 4   // ← NEW: vector similarity match
}
```

Semantic matches have lowest MatchType priority (highest rawValue), meaning keyword matches (exact, prefix, substring) always outrank semantic matches within deduplication. This is intentional — semantic search is complementary, not a replacement for keyword precision.

---

## 3. AISearchProvider Design

### 3.1 Conforms to SearchProvider Protocol

```swift
/// Semantic search provider bridging NL query -> embedding -> VectorStore -> results.
///
/// Searches are by filename semantics: the embedding of the filename is compared
/// to the embedding of the user query via cosine similarity.
///
/// Gracefully degrades: returns empty results when AI is disabled or embedding fails.
actor AISearchProvider: SearchProvider {
    let providerID = "ai-semantic"

    private let vectorStore: any VectorStore
    private let embeddingProvider: any EmbeddingProvider
    private let index: InMemoryIndex          // for FileRecord lookup
    private let nlTranslator: NLSearchTranslator?  // optional NL -> syntax

    init(
        vectorStore: any VectorStore,
        embeddingProvider: any EmbeddingProvider,
        index: InMemoryIndex,
        nlTranslator: NLSearchTranslator?
    )

    func search(query: SearchQuery) async -> SearchResultSequence {
        // 1. Compute query embedding
        // 2. Search VectorStore for top-K similar vectors
        // 3. Look up FileRecords from InMemoryIndex by UInt64 ID
        // 4. Return SearchResults with .semantic match type, score = cosine similarity
    }

    func cancel(queryID: String) async { /* no-op for now */ }
    func prepare() async { /* VectorStore is already loaded */ }
}
```

### 3.2 Bridging NLSearchTranslator + VectorStore

The `AISearchProvider` does NOT call `NLSearchTranslator.translate()` itself. Translation happens BEFORE the SearchCoordinator is called — at the IPCServer or CLI layer:

```
IPCServer.receive(.query) ──> if NLP detected ──> translate ──> SearchCoordinator.search(translatedQuery)
```

The `AISearchProvider.search()` receives the already-translated structured query (or raw query if translation was skipped). It:

1. Embeds the query text via `embeddingProvider.embed(text: query.rawQuery)`
2. Calls `vectorStore.search(query: embedding, topK: 200)` for top-200 similar vectors
3. Maps each `(id: UInt64, score: Float)` -> `FileRecord` via `index.record(byID:)` (needs new lookup method)
4. Returns `SearchResult(record:, providerID: "ai-semantic", score: Double(cosineScore), matchType: .semantic)`

### 3.3 Hybrid Search: Keyword + Semantic

The hybrid approach is **parallel retrieval with RRF fusion** (not sequential filtering):

```
                    Query
                      |
          +-----------+-----------+
          |                       |
    FileIndexProvider      AISearchProvider
    (keyword: Trie,        (semantic: embedding
     SubstringMap)          -> VectorStore)
          |                       |
    keywordResults          semanticResults
    (score: 0.5-1.0)        (score: 0.0-1.0)
          |                       |
          +-----------+-----------+
                      |
              RRF Score Fusion
        (Reciprocal Rank Fusion)
                      |
              Merged & Sorted
```

### 3.4 Result Fusion Strategy

Use **Reciprocal Rank Fusion (RRF)** — the industry standard. It is scale-invariant (no score normalization needed between keyword scores [0.5-1.0] and cosine similarity scores [0.0-1.0]).

**Formula:**

```
RRF_score(d) = Σ (1 / (k + rank_i(d)))  across all providers

where:
  k = 60 (standard smoothing constant)
  rank_i(d) = position of document d in provider i's result list (1-indexed)
```

**Why RRF over alternatives:**

| Method | Issue |
|--------|-------|
| CombSUM | Requires score normalization — BM25-style scores (0.5-1.0) vs cosine (0.0-1.0) have incompatible distributions |
| CombMNZ | Same normalization problem + favors items in multiple lists (which is desirable but rarer with disjoint providers) |
| Weighted linear combination | Requires per-query tuning of α; overengineered for v1 |
| **RRF** | Scale-invariant, zero parameters beyond k=60, well-understood behavior |

**Implementation location:** `SearchCoordinator.search()` gets a new optional fusion step. The existing deduplication logic (keep best match type) stays as-is for the simple case. RRF is applied when more than one provider returns results with the same file ID, producing a fused score that replaces the individual provider scores.

**Modified deduplication with RRF:**

```swift
// After collecting all provider results, before deduplication:
// 1. Group results by FileRecord.id
// 2. For files appearing in multiple providers, compute RRF score
// 3. For files in only one provider, keep that provider's score
// 4. Sort by fused score descending
```

---

## 4. Daemon Startup Changes

### 4.1 Pseudocode for Modified DaemonMain.run()

```
func run() async throws {
    // 1. Ensure data directory (existing)
    // 2. Acquire PID file (existing)
    // 3. Load persistence layer (existing)
    // 4. Load records and rebuild in-memory index (existing)

    // === NEW: AI initialization ===
    // 5a. Load AI config
    let config = loadConfig()  // existing ConfigStore
    let aiEnabled = AIConfig.isEnabled(config: config)

    // 5b. Initialize VectorStore and embedding cache
    var vectorStore: (any VectorStore)? = nil
    var aiProvider: AISearchProvider? = nil

    if aiEnabled {
        // Load or create embedding cache from SQLite
        let embeddingCache = try EmbeddingCache(
            dbPath: dataDir + "/cache/embeddings.db"
        )
        let cachedVectors = try await embeddingCache.loadAll()

        // Create concrete VectorStore
        let store = InMemoryVectorStore(dimensions: 512)
        for (fileID, vector) in cachedVectors {
            await store.insert(id: fileID, vector: vector)
        }
        vectorStore = store

        // Create embedding provider (always on-device for filename embeddings)
        let embProvider = NLEmbeddingProvider()

        // Create NL translator (nil if no cloud provider configured)
        let modelName = AIConfig.modelName(config: config)
        let apiKey = AIConfig.getAPIKey(config: config)
        let registry = ProviderRegistry()
        let aiModel = registry.instantiate(model: modelName, apiKey: apiKey)
        let nlTranslator = aiModel.map { NLSearchTranslator(provider: $0) }

        // Create AISearchProvider
        aiProvider = AISearchProvider(
            vectorStore: store,
            embeddingProvider: embProvider,
            index: index,
            nlTranslator: nlTranslator
        )
        await aiProvider?.prepare()
    }

    // 5c. Create SearchCoordinator with all providers
    let fileProvider = FileIndexProvider(index: index)
    await fileProvider.prepare()

    var providers: [any SearchProvider] = [fileProvider]
    if let ai = aiProvider {
        providers.append(ai)
    }
    let coordinator = SearchCoordinator(providers: providers)
    self.coordinator = coordinator
    self.vectorStore = vectorStore
    self.aiProvider = aiProvider

    // 6. Start IPCServer (existing)
    // 7. Start FSEventWatcher (existing)
    // 8. Background initial scan (existing)

    // === NEW: Background embedding computation ===
    if aiEnabled {
        backgroundEmbeddingTask = Task.detached {
            await computeEmbeddingsForUnindexedFiles(
                index: index,
                vectorStore: vectorStore!,
                embeddingProvider: embProvider,
                embeddingCache: embeddingCache
            )
        }
    }

    // 9. Register signal handlers (existing)
    // 10. Wait for shutdown (existing)
}
```

### 4.2 Background Embedding Computation

```
func computeEmbeddingsForUnindexedFiles(...) async {
    let allRecords = await index.allRecords()
    let embeddedIDs = await vectorStore.allIDs()  // needs new method

    let unembedded = allRecords.filter { !embeddedIDs.contains(UInt64($0.id)) }

    // Process in batches to avoid blocking
    let batchSize = 50
    for batch in unembedded.chunks(of: batchSize) {
        guard !Task.isCancelled else { return }

        let names = batch.map { $0.name }
        let embeddings = try? await embeddingProvider.embedBatch(texts: names)

        if let embeddings {
            for (record, vector) in zip(batch, embeddings) {
                await vectorStore.insert(id: UInt64(record.id), vector: vector)
            }
            // Persist to cache
            for (record, vector) in zip(batch, embeddings) {
                await embeddingCache.save(id: UInt64(record.id), vector: vector)
            }
        }

        // Yield to other tasks periodically
        await Task.yield()
    }
}
```

### 4.3 FSEventWatcher Integration for Embedding Updates

When FSEventWatcher detects a file change (rename, new file), it must:

1. Update the InMemoryIndex (existing behavior)
2. **NEW**: Invalidate the old embedding for that file ID
3. **NEW**: Compute the new embedding in the background and insert into VectorStore

This requires the FSEventWatcher to be aware of `EmbeddingCache` and `VectorStore`:

```
// In FSEventWatcher, on file rename:
await vectorStore.delete(id: UInt64(oldRecordID))
await embeddingCache.delete(id: UInt64(oldRecordID))
let newVector = try await embeddingProvider.embed(text: newName)
await vectorStore.insert(id: UInt64(newRecordID), vector: newVector)
await embeddingCache.save(id: UInt64(newRecordID), vector: newVector)

// On new file:
// Same as above: compute + insert + persist
```

---

## 5. Embedding Cache Design

### 5.1 Storage Location

Use a **separate SQLite database** (not the main `index.db`):

```
~/.deep-finder/
  cache/
    index.db           # Existing: FileRecord[] + FSEvents cursor
    embeddings.db      # NEW: filename embeddings (VectorStore cache)
```

Rationale for separate file:
- Embedding cache has different access patterns (write-heavy during initial population, read-heavy after)
- Decouples from index lifecycle (embedding cache can outlive index rebuilds)
- Simpler migration — drop `embeddings.db` to force recompute without touching index

### 5.2 Schema

```sql
CREATE TABLE IF NOT EXISTS embeddings (
    file_id   INTEGER PRIMARY KEY,  -- UInt64, matches FileRecord.id
    vector    BLOB NOT NULL,        -- 512 float32 values = 2048 bytes
    mtime     REAL NOT NULL,        -- File modification time at embedding time
    size      INTEGER NOT NULL,     -- File size at embedding time
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_embeddings_mtime ON embeddings(mtime);
```

- `512 float32 * 4 bytes = 2048 bytes` per vector
- For 500,000 files: ~1 GB of vector data (acceptable for M4+)
- **mtime + size** serve as cache invalidation keys — if either changes, the embedding is stale

### 5.3 Cache Operations

```swift
actor EmbeddingCache {
    private let db: SQLiteConnection  // or use existing IndexPersistence pattern

    init(dbPath: String) throws

    /// Load all embeddings from cache. Returns empty if DB doesn't exist yet.
    func loadAll() async throws -> [(id: UInt64, vector: [Float])]

    /// Save a single embedding. Upserts on conflict (file_id is PRIMARY KEY).
    func save(id: UInt64, vector: [Float], mtime: Date, size: Int64) async throws

    /// Batch save for performance during initial population.
    func saveBatch(_ entries: [(id: UInt64, vector: [Float], mtime: Date, size: Int64)]) async throws

    /// Delete embedding for a file (e.g., file deleted from disk).
    func delete(id: UInt64) async throws

    /// Check if cached embedding is still valid (mtime + size match the current file).
    func isValid(id: UInt64, mtime: Date, size: Int64) async throws -> Bool

    /// Remove embeddings for files that no longer exist or have changed.
    func pruneStale(validIDs: Set<UInt64>) async throws -> Int

    /// Total cached embeddings count.
    func count() async throws -> Int
}
```

### 5.4 Cache Invalidation Rules

| Trigger | Action |
|---------|--------|
| File renamed | Delete old (file_id) embedding, insert new embedding |
| File modified (mtime change) | Invalidate old, recompute |
| File size changed | Invalidate old, recompute |
| File deleted | Delete embedding from cache |
| File moved (same name, different path) | No change (embedding is name-based, not path-based) |
| File metadata-only change (tags, permissions) | No change (name unchanged) |
| Embedding model changed (e.g., 512 -> 768 dim) | Full cache rebuild (detect via `dimensions` mismatch in metadata table) |

### 5.5 Incremental Update Strategy

During FSEventWatcher callbacks:

```
onFileCreated(record):
    1. await vectorStore.delete(id: UInt64(record.id))  // clean any stale
    2. vector = try await embeddingProvider.embed(text: record.name)
    3. await vectorStore.insert(id: UInt64(record.id), vector: vector)
    4. await embeddingCache.save(id: UInt64(record.id), vector: vector, mtime: record.modifiedAt, size: record.size)

onFileModified(record):
    // Check if name changed. If name unchanged, embedding is still valid.
    let oldRecord = await index.record(byID: record.id)
    if oldRecord?.name != record.name {
        // Name changed -> recompute embedding
        same as onFileCreated
    }
    // else: mtime/size update only -> update cache mtime, keep embedding

onFileDeleted(fileID):
    1. await vectorStore.delete(id: UInt64(fileID))
    2. await embeddingCache.delete(id: UInt64(fileID))
```

### 5.6 Initial Population

On first daemon start with AI enabled:
1. Load all cached embeddings from `embeddings.db`
2. Populate `InMemoryVectorStore` with cached vectors
3. Identify files without embeddings (diff of index vs cache)
4. Background task: embed unembedded files in batches (50 per batch, yield between batches)
5. Files added during background scan also get embedded on discovery

### 5.7 Metadata Table for Model Version Tracking

```sql
CREATE TABLE IF NOT EXISTS embedding_meta (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);

-- Stored on first cache creation:
-- ("model", "nlcontextual")
-- ("dimensions", "512")
-- ("version", "1")        -- schema version for migration
```

On startup, check that stored `dimensions` matches `NLEmbeddingProvider.dimensions`. If mismatch, drop and rebuild the entire cache.

---

## 6. Privacy Boundary Enforcement

### 6.1 What Stays On-Device (Always)

| Data | Location | Network |
|------|----------|---------|
| Filename embeddings | `~/.deep-finder/cache/embeddings.db` | Never leaves device |
| Query embeddings | In-memory only (computed per query, discarded after) | Never leaves device |
| Full file paths | `~/.deep-finder/cache/index.db` | Never leaves device (already true) |
| File contents | On disk (never read by AI module) | Never leaves device |
| VectorStore in-memory index | Process memory | Never leaves device |
| Speech recognition | On-device via Speech framework | Never leaves device |
| Image analysis | On-device via Vision framework | Never leaves device |

### 6.2 What Goes to Cloud (Opt-in Only)

| Data | Required Config | Privacy Control |
|------|----------------|-----------------|
| NL query translation (search syntax) | `ai.enabled=true` + `ai.model=<provider>` + API key set | Query string only (no file metadata) |
| Result summarization | `ai.enabled=true` + `ai.sendMetadata=true` + API key | File metadata (anonymized paths, names, sizes) |
| Cloud embeddings | `ai.embeddingModel` != "nlcontextual" + API key | Filenames only (not paths) |

**Critical invariant**: Cloud embedding is opt-in with a separate config key (`ai.embeddingModel`). The default `nlcontextual` embedding provider is on-device. Users who use cloud LLMs (e.g., DeepSeek for NL translation) can still use on-device embeddings for semantic search — these are independent choices.

### 6.3 Path Sanitization

By default (`ai.pathAnonymization = true`), paths sent to cloud providers are anonymized:
- `/Users/nadav/Documents/report.pdf` -> `~/Documents/report.pdf`
- Controlled by `FileMetadataSummary.from(_:anonymize:)` — already implemented

### 6.4 NL Query Translation Privacy

When `NLSearchTranslator.translate()` calls a cloud provider:
- Only the raw query string is sent (e.g., "find PDFs from last week")
- No file metadata, no results, no paths
- The response is a search syntax string (e.g., "ext:pdf dm:lastweek")
- This is the minimum necessary data for translation

### 6.5 Audit Trail

All cloud AI calls are logged (to system log, not to disk) with:
- Timestamp
- Provider name
- Feature used (translate, summarize, etc.)
- Whether metadata was included
- Duration and success/failure

This is for user debugging (`:ai-audit` REPL command in future), not for telemetry.

---

## 7. Graceful Degradation

### 7.1 Degradation Ladder

```
Level 0: Full AI search
  - NL translation + semantic search + keyword search + result summarization + advisor
  - Requires: ai.enabled=true, ai.model=<provider>, API key

Level 1: Semantic search only (no NL translation)
  - keyword search + semantic search via on-device embeddings
  - Requires: ai.enabled=true (but no cloud provider needed)
  - NL queries fall through to keyword search

Level 2: Keyword-only (current behavior)
  - No AI providers registered
  - Requires: ai.enabled=false (default) or initialization failure
```

### 7.2 Degradation Triggers

| Trigger | Degradation | User-Visible Behavior |
|---------|-------------|----------------------|
| `ai.enabled = false` | Level 2 | Current behavior, unchanged |
| `ai.enabled = true` but no API key | Level 1 | Semantic search works (on-device), NL translation disabled |
| `ai.enabled = true` + API key + cloud provider | Level 0 | Full AI features |
| NL embedding model fails to load | Level 2 (skip semantic) | Logged warning, keyword-only |
| Cloud provider rate-limited (HTTP 429) | Level 1 (skip NL translation) | Query treated as raw keyword search |
| Cloud provider timeout (>30s) | Level 1 | Query treated as raw keyword search |
| VectorStore corruption / load failure | Level 2 | Logged error, AI provider not registered |
| Embedding cache corruption | Level 1 (recompute from scratch) | Background re-embedding starts, semantic search unavailable until cache populates |
| NLTranslation returns error | Level 1 | Raw query used for keyword + semantic search |

### 7.3 User Configuration

```
deepfinder config set ai.enabled true          # Enable AI module (on-device only)
deepfinder config set ai.model deepseek        # Enable cloud AI for NL translation
deepfinder config set ai.apiKey sk-...         # API key for cloud provider
deepfinder config set ai.embeddingModel nlcontextual  # On-device embeddings (default)
deepfinder config set ai.embeddingModel qwen    # Switch to cloud embeddings (opt-in)
deepfinder config set ai.cacheTTL 300           # Embedding cache TTL (seconds)
```

### 7.4 Error Handling in AISearchProvider

```swift
func search(query: SearchQuery) async -> SearchResultSequence {
    // Guard: embedding provider available
    guard let embProvider = embeddingProvider else {
        return SearchResultSequence([])  // empty = no semantic results, not an error
    }

    // Guard: vector store has data
    guard await vectorStore.count() > 0 else {
        return SearchResultSequence([])
    }

    do {
        let queryVector = try await embProvider.embed(text: query.rawQuery)
        let matches = try await vectorStore.search(query: queryVector, topK: 200)

        // Look up FileRecords
        let allRecords = await index.allRecords()
        let recordMap = Dictionary(uniqueKeysWithValues: allRecords.map { ($0.id, $0) })

        let results = matches.compactMap { (id: UInt64, score: Float) -> SearchResult? in
            guard let record = recordMap[UInt32(id)] else { return nil }
            return SearchResult(
                record: record,
                providerID: providerID,
                score: Double(score),
                matchType: .semantic
            )
        }
        return SearchResultSequence(results)
    } catch {
        // Log warning, return empty — keyword results still returned by other providers
        return SearchResultSequence([])
    }
}
```

---

## 8. Implementation Phases

### Phase 1: AISearchProvider + VectorStore Integration (Foundation)

**Goal**: End-to-end semantic search works. No persistence. No fusion.

**Deliverables**:
1. `InMemoryVectorStore` — concrete implementation of `VectorStore` protocol
   - Brute-force cosine similarity (acceptable for <500K vectors on M4)
   - `insert`, `search`, `delete`, `count`, `allIDs` (for cache diff)
2. `AISearchProvider` — conforms to `SearchProvider`
   - Bridges NLEmbeddingProvider + InMemoryVectorStore + InMemoryIndex
3. `AISearchProviderTests` — unit tests for search, empty states, error paths
4. `InMemoryVectorStoreTests` — unit tests for insert/search/delete/count
5. DaemonMain.run() modification: register AISearchProvider when ai.enabled=true
6. Background embedding computation (in-memory only, no cache persistence yet)
7. `MatchType.semantic` addition to SearchTypes

**Verification**:
- `swift test --filter AISearchProviderTests`
- `swift test --filter InMemoryVectorStoreTests`
- Manual test: `deepfinder "document about budget"` returns semantically relevant files that don't contain "budget" in their name

**Files changed**:
- `Sources/AI/InMemoryVectorStore.swift` (NEW)
- `Sources/AI/AISearchProvider.swift` (NEW)
- `Sources/Search/SearchTypes.swift` (add `MatchType.semantic`)
- `Sources/Index/InMemoryIndex.swift` (add `record(byID:)` lookup if not present)
- `Sources/Daemon/DaemonMain.swift` (register AISearchProvider)
- `Tests/AITests/AISearchProviderTests.swift` (NEW)
- `Tests/AITests/InMemoryVectorStoreTests.swift` (NEW)

### Phase 2: Embedding Cache Persistence

**Goal**: Embeddings survive daemon restart. Incremental updates via FSEventWatcher.

**Deliverables**:
1. `EmbeddingCache` — SQLite-based persistent cache
   - `loadAll()`, `save()`, `saveBatch()`, `delete()`, `isValid()`, `pruneStale()`
2. `EmbeddingCacheTests`
3. DaemonMain.run(): load cache on startup, populate VectorStore from cache
4. FSEventWatcher: on file create/rename/delete, update embedding cache
5. Cache invalidation: mtime + size based
6. `embedding_meta` table for model version tracking
7. Background: compute embeddings for files not in cache (incremental diff)

**Verification**:
- `swift test --filter EmbeddingCacheTests`
- Manual: start daemon, kill it, restart — embeddings survive
- Manual: rename a file in Finder, search for old name (no result), new name (semantic match)
- Manual: add new file, wait for background embedding, search semantically finds it

**Files changed**:
- `Sources/AI/EmbeddingCache.swift` (NEW)
- `Sources/Daemon/DaemonMain.swift` (load cache, pass to AISearchProvider)
- `Sources/FS/FSEventWatcher.swift` (embedding invalidation/update)
- `Tests/AITests/EmbeddingCacheTests.swift` (NEW)

### Phase 3: Hybrid Search Fusion

**Goal**: Keyword + semantic results merged via RRF. Better ranking than either alone.

**Deliverables**:
1. RRF implementation in `SearchCoordinator` (or separate `ResultFusion` utility)
   - `ReciprocalRankFusion.fuse(results: [[SearchResult]], k: Int = 60) -> [SearchResult]`
2. Modified deduplication that computes fused scores for multi-provider results
3. `ResultFusionTests` — verify RRF formula, edge cases (empty provider, single result)
4. SearchCoordinator modified to apply RRF when >1 provider returns results

**Verification**:
- `swift test --filter ResultFusionTests`
- Manual: search for a term that matches both keywords and semantics — combined ranking is better than either alone
- Benchmark: measure MRR@10 for keyword-only vs hybrid on a test query set

**Files changed**:
- `Sources/Search/SearchCoordinator.swift` (RRF fusion in search())
- `Sources/Search/ResultFusion.swift` (NEW)
- `Tests/SearchTests/ResultFusionTests.swift` (NEW)

### Phase 4: Cross-Encoder Reranker (Optional / Future)

**Goal**: Precision boost for top results. Phase 4 only if Phase 3 quality is insufficient.

**Deliverables**:
1. On-device cross-encoder using CoreML (if available) or cloud reranker API
2. Rerank top-50 fused results -> re-score -> re-sort
3. Configurable depth: `ai.rerankerDepth = 50`

**Verification**:
- Measure MRR@10 with and without reranker on benchmark query set
- Latency impact < 100ms for reranking 50 candidates

**Decision gate**: Implement only if Phase 3 hybrid search alone does not meet quality targets.

---

## 9. Success Metrics

### 9.1 Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Semantic search latency (query embedding) | < 5ms | `NLEmbeddingProvider.embed(text:)` wall-clock |
| VectorStore top-200 search | < 10ms (500K vectors, brute-force) | `InMemoryVectorStore.search()` wall-clock |
| Total AISearchProvider.search() | < 50ms | End-to-end provider search timing |
| Embedding computation per file | < 2ms | `NLEmbeddingProvider.embed(text:)` per filename |
| Initial cache population (500K files) | < 30 min (background, non-blocking) | Wall-clock from daemon start to cache fully populated |
| Cache load on daemon startup (500K vectors) | < 5s | `EmbeddingCache.loadAll()` wall-clock |
| Embedding cache size (500K files) | ~1 GB | `embeddings.db` file size (500K * 2048 bytes) |

### 9.2 Quality Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Recall@10 improvement over keyword-only | +15-30% for semantic queries | Benchmark on curated query set (100 queries) |
| MRR@10 for hybrid vs keyword-only | Improvement on at least 70% of semantic queries | Same benchmark set |
| False positive rate (semantic) | < 5% in top-10 results | Human evaluation on random sample |

### 9.3 User Satisfaction Metrics (Future Telemetry)

These are aspirational — opt-in, privacy-preserving, and fully transparent:

- Percentage of queries that activate semantic search
- Semantic result click-through rate vs keyword result CTR
- Query reformulation rate (did user refine query after seeing results?)
- NL translation accuracy (did user accept the translated syntax or override it?)

---

## Appendix A: InMemoryVectorStore Design Notes

### A.1 Why Brute-Force (Not ANN)

For the expected scale (<500K vectors, 512-dim each) on Apple Silicon M4+:

- 500K * 512 * 4 bytes = 1 GB vector data (in unified memory)
- Brute-force cosine similarity: 500K * 512 = 256M FLOPs per query
- M4 Neural Engine: ~38 TOPS — 256M FLOPs is ~7 microseconds of compute
- Real-world estimate including memory bandwidth: < 10ms per top-200 search
- ANN (HNSW, IVF) adds index build time, memory overhead, and approximate results
- Brute-force is exact (better recall) and simpler (fewer bugs, no tuning)

If file count exceeds 1M, switch to Apple's `ANNSearch` framework (macOS 26+) or SIMD-accelerated brute-force with `vDSP`.

### A.2 Data Structure

```swift
actor InMemoryVectorStore: VectorStore {
    let dimensions: Int
    private var vectors: [UInt64: [Float]] = [:]     // fileID -> embedding
    private var ids: [UInt64] = []                     // ordered list for iteration

    func search(query: [Float], topK: Int) -> [(id: UInt64, score: Float)] {
        // Compute cosine similarity for all vectors
        // Sort by descending score
        // Return top-K
    }
}
```

### A.3 Cosine Similarity (vDSP Accelerated)

```swift
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    // Using vDSP for SIMD acceleration on Apple Silicon
    var dotProduct: Float = 0
    var aMagnitude: Float = 0
    var bMagnitude: Float = 0

    vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
    vDSP_dotpr(a, 1, a, 1, &aMagnitude, vDSP_Length(a.count))
    vDSP_dotpr(b, 1, b, 1, &bMagnitude, vDSP_Length(b.count))

    let denominator = sqrt(aMagnitude) * sqrt(bMagnitude)
    return denominator > 0 ? dotProduct / denominator : 0
}
```

Since all NLEmbeddingProvider outputs are L2-normalized, `magnitude ≈ 1.0` for all vectors — we can skip the magnitude computation and use dot product directly as a similarity proxy (50% faster).

---

## Appendix B: NL Detection Heuristic

Before routing to NLSearchTranslator, determine whether the query is natural language:

```swift
func isNaturalLanguageQuery(_ query: String) -> Bool {
    // Contains search syntax -> not NL
    if NLSearchTranslator.looksLikeSearchSyntax(query) { return false }

    // Very short queries are likely keywords
    if query.split(separator: " ").count <= 1 { return false }

    // Contains natural language markers
    let nlPatterns = [
        "find", "show", "search for", "look for",
        "files with", "documents about", "photos from",
        "找", "搜索", "查找",  // Chinese
    ]
    let lower = query.lowercased()
    for pattern in nlPatterns {
        if lower.contains(pattern) { return true }
    }

    // Default: 3+ words without syntax = probably NL
    return query.split(separator: " ").count >= 3
}
```

This heuristic is intentionally conservative. False positives (keyword query treated as NL) are handled gracefully: NLSearchTranslator will detect syntax in the AI response or return the input unchanged. False negatives (NL query not translated) simply fall through to keyword search.

---

## Appendix C: IPC Protocol Changes

No IPC protocol changes are needed. The existing `.query` message already carries a raw string. NL translation happens at the daemon side (before SearchCoordinator), and semantic results use the same `SearchResult` type as keyword results. The CLI and GUI see no difference — results just include `.semantic` match types in addition to `.exact`, `.prefix`, `.substring`.

The terminal formatter can add a small indicator (e.g., a brain emoji or "[semantic]" tag) for results from the AI provider, but this is cosmetic and can be added later.

---

## Appendix D: Testing Strategy

### D.1 Unit Tests

- `InMemoryVectorStoreTests`: insert, search (top-1, top-K, empty), delete, count, duplicate ID overwrite
- `AISearchProviderTests`: search with mock VectorStore, empty results, embedding failure, nil translator
- `EmbeddingCacheTests`: save, load, delete, isValid, pruneStale, batch save, model version mismatch
- `ResultFusionTests`: RRF formula correctness, empty provider list, single provider, disjoint results, score ordering

### D.2 Integration Tests

- `DaemonMain+AI`: daemon starts with AI enabled, AISearchProvider registered
- `DaemonMain+AI`: daemon starts with AI disabled, AISearchProvider not registered
- `SearchCoordinator+Hybrid`: keyword + semantic providers, results merged via RRF
- `NLSearchTranslator+SearchCoordinator`: NL query translated, then searched via coordinator

### D.3 Benchmark Tests

- `VectorStoreBenchmark`: search latency at 10K, 100K, 500K vector scale
- `EmbeddingBenchmark`: per-file embedding throughput
- `HybridSearchBenchmark`: end-to-end query latency (keyword only vs hybrid)
- `RecallBenchmark`: Recall@10 on curated 100-query test set

---

## Appendix E: Open Questions

1. **FileRecord.id type mismatch**: `VectorStore` uses `UInt64` for `id`, but `FileRecord.id` is `UInt32`. We need to either change VectorStore to use `UInt32` or cast. Recommendation: keep VectorStore as `UInt64` (future-proof for larger ID spaces) and cast `FileRecord.id` when inserting/looking up.

2. **InMemoryIndex record(byID:) lookup**: Does not currently exist. `InMemoryIndex` has `allRecords()` but no single-record lookup. Need to add `func record(byID: UInt32) -> FileRecord?` for mapping VectorStore results to FileRecords.

3. **Embedding content vs filename**: Should we embed file *contents* (first N bytes) or just filenames? Recommendation for v3.1: filenames only. Content embeddings are a separate feature (v3.2+) with different privacy implications.

4. **Cloud embedding provider routing**: Currently `EmbeddingProvider` is always `NLEmbeddingProvider` (on-device). When `ai.embeddingModel` is set to a cloud provider (e.g., `qwen`), should we route to `CloudEmbeddingProvider`? Answer: yes, but this is opt-in and requires separate API key management. Deferred to Phase 2+.

5. **Multi-language embedding quality**: `NLEmbeddingProvider` routes CJK text to `NLContextualEmbedding(script: .simplifiedChinese)`. Does this cover Japanese and Korean filename embeddings adequately? Testing needed.

6. **Memory budget**: 500K * (512 floats * 4 bytes) = 1 GB for vectors + overhead for dictionary. With InMemoryIndex already consuming significant memory, total daemon memory could exceed 4 GB. Acceptable per "memory is not a constraint" design principle, but should be documented.
