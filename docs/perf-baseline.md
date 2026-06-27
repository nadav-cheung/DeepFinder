# DeepFind — Performance Baseline (2026-06-23)

> Captured on macOS (Darwin 25.5) with `cargo bench` (release, default sample counts unless noted).
> This is the synthetic baseline used to gate the Phase D hardening decisions in [decisions.md](decisions.md) (ADR-0010).

---

## Environment

- **OS:** macOS (Darwin 25.5).
- **Build:** release (`cargo bench`), default criterion sample counts unless noted.
- **Corpus:** synthetic; specifics are noted per table (a 40 000-doc / 1.5 MB filename DB for query latency; a temp corpus of N small text files for build throughput; 3 052 entries for peak RSS).

> CPU and RAM are not recorded here because the baseline was captured without pinning them. Record them when re-running on a large real corpus for the deferred hardening items.

## Methodology

- **Query latency:** `cargo bench` (criterion). Reproduce with `cargo bench -p df-core --bench query`.
- **Build throughput:** `cargo bench`. Reproduce with `cargo bench -p df-index --bench build`.
- **Peak RSS:** `/usr/bin/time -l <bin> …` — peak `maximum resident set size`, in bytes.

## Results

### Query latency (in-memory `DbReader`, 40 000 docs / 1.5 MB DB)

`crates/df-core/benches/query.rs` — the core engine path. Production adds one pread per posting/block (page-cache-hot).

| case | query | p50 | notes |
|---|---|---|---|
| rare | `module_00123` | **852 µs** | selective substring (typical) |
| common | `src` | **1.05 ms** | ~1/7 of corpus — single-rarest candidate gen |
| boolean | `src AND tests` | **6.46 ms** | two mid-selectivity terms; `NOT` is O(num_docs) |
| short | `go` (2 bytes) | **2.43 ms** | <3-byte **linear-scan fallback** — no bigram index |

### Build throughput (temp corpus of N small text files)

`crates/df-index/benches/build.rs` — walk → text-gate → dual builders → shard flush (10 samples).

| N | time | throughput |
|---|---|---|
| 1 000 | **70 ms** | ~14 k files/s |
| 5 000 | **292 ms** | ~17 k files/s |

### Peak RSS (`/usr/bin/time -l`)

Corpus: 3 052 entries (3 000 content docs, 1 shard).

| op | peak RSS |
|---|---|
| `deepfind index --force` | **19.1 MiB** (20 037 632 B) |
| `deepfind search --direct` | **3.4 MiB** (3 604 480 B) |

Low and bounded — consistent with the pread (filename) + mmap (content) design.

---

## Opportunities — measurement-driven hardening

Ordered by the bench signal above. Each is a standalone commit with a before/after delta recorded in the table at the end of this section.

1. **Bigram short-query path (D2.2)** — the `short` case (2-byte) is **2.43 ms** because <3-byte queries linear-scan all docs. A 65 k-entry bigram index (folded 2-byte keys → posting) replaces the scan. Expected: `short` drops to the rare-query regime (~µs). **Highest-signal win.**
2. **2-rarest intersection (D2.1)** — `common` (`src`, 1.05 ms) and the rare-trigram tail are dominated by verifying a large candidate set. Intersecting the 2 rarest postings before verify narrows it. Expected: measurable drop on high-frequency trigram queries.
   - *Note:* **already tried + reverted** (see [decisions.md](decisions.md) ADR-0010 / D2.1). For literal-substring candidate generation a query's trigrams are contiguous, so they co-occur in the same documents and the two rarest postings overlap almost entirely — measured `common` stayed at ~1.05 ms (noise). Do **not** re-attempt for the single-term path; it only helps multi-term queries, which route through the boolean AST.
3. (Lower signal without a large real corpus) ASCII direct-index array, dirTable shard pruning, per-shard parallel query, `madvise` hints — revisit after a real multi-GB corpus is benchmarked.

### Hardening deltas

| item | case | before | after | commit |
|---|---|---|---|---|
| _(populate as each hardening item lands)_ | | | | |
