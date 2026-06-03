# DeepFinder Benchmarks

Reproducible, verifiable, open-data performance benchmarks for the DeepFinder file search engine. This document defines the methodology, test data sets, measurement dimensions, benchmark runner design, results presentation, and CI integration.

> **Status**: v3.0.0 — methodology defined, runner implementation in progress.
> **Owner**: architect / algo-dev / qa-dev
> **Last updated**: 2026-06-03

---

## 1. Benchmark Philosophy

All claimed performance numbers MUST be reproducible by any user on comparable hardware. We follow these principles:

1. **Reproducible**: Every benchmark includes the exact command to run, the data set generation script, and the expected hardware specification. Anyone can clone the repo and get the same results within statistical noise.
2. **Documented hardware**: Every result includes CPU model, core count, memory configuration, SSD type, macOS version, and build configuration. No anonymous numbers.
3. **Open data**: Test data sets are generated programmatically from seed files committed to the repo. No "mystery corpus" that only one person can run.
4. **Cold vs. warm stated**: Every measurement explicitly states whether caches were cold (first run after boot/purge) or warm (subsequent runs).
5. **Statistical rigor**: Median, p95, and p99 reported. Not just "average." Minimum 5 runs after warm-up. Standard deviation included.
6. **Regression-aware**: Every benchmark has a defined threshold. Crossing it triggers a CI warning. Crossing it by 2x triggers a CI failure.
7. **Comparative**: Where competitor data is available (Everything on Windows via Boot Camp or VM), we publish side-by-side numbers with methodology notes.

### What We Do NOT Benchmark

- **Microbenchmarks of individual Swift operations** (covered by existing `IndexBenchmarks`/`SearchBenchmarks` test suites — those validate algorithm correctness + relative performance, not end-to-end system behavior)
- **GUI rendering performance** (separate concern, benchmarked via Instruments + frame-rate instrumentation in GUITests)
- **AI model inference speed** (model-dependent, benchmarked separately in AITests with provider-specific baselines)

---

## 2. Test Data Sets

All data sets are generated deterministically from a seed so results are comparable across runs and machines.

### 2.1 Generation Script

A Swift script `scripts/generate-benchmark-data.swift` consumes a seed value and a target file count, producing a directory tree under `/tmp/deepfinder-bench-data/`.

```bash
swift run generate-benchmark-data --count 10000 --seed 42 --output /tmp/df-bench-10k
```

**Deterministic properties** (seeded from `--seed`):
- Filename length distribution (mean 24 chars, stddev 12, min 3, max 255)
- File extension distribution (weighted by real-world prevalence: `.txt` 12%, `.pdf` 8%, `.swift` 1%, etc.)
- Directory depth distribution (mean depth 4, max 12; 60% shallow ≤3 levels, 35% medium 4-7, 5% deep 8-12)
- File size distribution (log-normal, median 8KB, 90th percentile 2MB, 99th percentile 200MB)
- Timestamp distribution (spread over 2 years; 50% recent 30 days, 30% 1-6 months, 20% older)
- Unicode content: ~5% of filenames contain CJK characters, ~3% contain emoji, ~2% contain accented Latin
- Dotfile distribution: ~8% of filenames start with `.`

### 2.2 Scale Tiers

| Tier | File Count | Disk Footprint | Use Case | Generation Time (est.) |
|------|-----------|----------------|----------|------------------------|
| **Small** | 10,000 | ~100 MB | Typical home directory subset | <1s |
| **Medium** | 100,000 | ~1 GB | Developer machine (node_modules, .git) | ~3s |
| **Large** | 1,000,000 | ~10 GB | Full disk scan | ~30s |
| **XL** | 10,000,000 | ~100 GB | Enterprise / external drive | ~5 min |

**Generation notes**:
- Directories are created as real filesystem entries (sparse files for content to avoid SSD wear)
- File content: first 4KB populated with random data seeded from path hash (enables content search benchmarks); remainder is a hole (sparse)
- Each tier is generated once and reused across benchmark runs
- Tiers are additive (Large includes all files from Small + Medium patterns, scaled up)

### 2.3 Content Subsets for Specialized Benchmarks

Within each tier, specific subsets enable targeted benchmarks:

| Subset | Description | % of Corpus |
|--------|-------------|-------------|
| **CJK files** | Chinese/Japanese/Korean filenames | ~5% |
| **Long names** | Filenames >64 characters (exercises TrigramIndex) | ~2% |
| **Deep paths** | >8 directory levels | ~2% |
| **Media files** | `.jpg`, `.mp4`, `.mp3`, `.flac` (exercises MediaMetadataIndex) | ~10% |
| **Source code** | `.swift`, `.py`, `.js`, `.ts`, `.rs`, `.go` | ~15% |
| **Large files** | >100 MB (exercises size filter edge cases) | ~3% |
| **Duplicate names** | Same filename in different directories (exercises dedup) | ~1% |
| **Recently modified** | `mtime` within last hour | ~0.5% |

---

## 3. Benchmark Dimensions

### 3.1 Index Build Time (Cold Start)

**Definition**: Wall-clock time from "start scanning" to "index ready for queries," measured from scratch with no pre-existing SQLite cache.

**Method**:
1. Purge cache: `rm -rf ~/.deep-finder/cache/`
2. Clear unified buffer cache: `sudo purge` (requires admin)
3. Start daemon with benchmark data path configured
4. Measure from daemon launch to first successful search returning correct count
5. Run 5 times, report median + p95

**Expected (baseline, M4 Pro, 48GB)**:

| Tier | Target | Everything (120K files) | Notes |
|------|--------|------------------------|-------|
| 10K | <0.5s | — | |
| 100K | <2s | ~1s (Everything on NTFS MFT) | NTFS MFT is a single table read; we scan directory tree |
| 1M | <15s | ~60s | Everything reads MFT directly (bypasses filesystem); we use FTS |
| 10M | <3 min | ~10 min (forum anecdote) | |

### 3.2 Index Load Time (Warm Start)

**Definition**: Wall-clock time to reload the index from SQLite into memory after a daemon restart.

**Method**:
1. Build index with data set (ensure SQLite is populated)
2. Stop daemon gracefully (SIGTERM)
3. Start daemon — measure from launch to search-ready
4. Run 5 times, report median

**Expected**: <1s for 1M files (SQLite WAL, sequential scan of FileRecord table).

### 3.3 Search Latency

All measurements use the IPC client (end-to-end: query string in → JSON results out). Measured via `ContinuousClock` in the benchmark runner.

#### 3.3.1 Prefix Search

**Definition**: Query matches beginning of filenames (Trie path).

**Method**: Run 100 queries uniformly sampled from the dataset's filename prefix distribution. Warm index. Measure IPC round-trip.

**Queries**: Generated from the dataset: take first 1-5 characters of randomly selected filenames. 50% 2-3 char prefixes, 30% 4-6 char, 20% 7+ char.

| Tier | Target (median) | Target (p99) |
|------|-----------------|--------------|
| 10K | <0.1ms | <0.5ms |
| 100K | <0.5ms | <2ms |
| 1M | <1ms | <5ms |
| 10M | <3ms | <10ms |

#### 3.3.2 Substring Search

**Definition**: Query matches any substring of filenames (FullSubstringMap path for names ≤64 chars, TrigramIndex for long names).

**Method**: Same as prefix but with mid-string fragments (characters 3-8 of filenames).

| Tier | Target (median) | Target (p99) |
|------|-----------------|--------------|
| 10K | <0.5ms | <2ms |
| 100K | <1ms | <5ms |
| 1M | <3ms | <10ms |
| 10M | <8ms | <25ms |

#### 3.3.3 Regular Expression Search

**Definition**: `regex:pattern` queries (linear scan with ICU regex matching).

**Method**: 20 regex patterns of varying complexity. Measure total scan time.

| Tier | Target (median) | Notes |
|------|-----------------|-------|
| 10K | <5ms | |
| 100K | <50ms | |
| 1M | <500ms | Linear scan; inherently O(n) |
| 10M | <5s | |

#### 3.3.4 Content Search

**Definition**: Full-text search inside file contents via `ContentScanner`.

**Method**: 50 queries against known content strings seeded in generated files. Measure time to first result and time to complete.

| Tier | Target (first result) | Notes |
|------|----------------------|-------|
| 10K | <100ms | |
| 100K | <500ms | |
| 1M | <2s | Content search is inherently I/O-bound |

#### 3.3.5 Pinyin Search

**Definition**: Chinese filename search via PinyinIndex (full pinyin and first-letter abbreviation).

**Method**: 50 pinyin queries against the CJK subset. Measure round-trip.

| Tier | Target (median) | Notes |
|------|-----------------|-------|
| 10K (500 CJK) | <0.5ms | |
| 100K (5K CJK) | <1ms | |

#### 3.3.6 Semantic Search (AI)

**Definition**: Natural-language query translated to file search via `NLSearchTranslator` + `EmbeddingProvider`.

**Method**: 20 natural-language queries ("find my budget spreadsheets from last month"). Measure translation time + search time. Exclude network latency for cloud providers.

| Metric | Target |
|--------|--------|
| NL translation (local) | <50ms |
| Vector similarity search (10K vectors) | <5ms |

#### 3.3.7 Boolean + Filter Queries

**Definition**: Combined queries with boolean operators, metadata filters, and path qualifiers.

**Method**: 50 compound queries: `ext:pdf (report | memo) !draft dm:thisweek`. Measure end-to-end.

Expected <2x single-prefix latency (filtering happens after index lookup on a result subset).

### 3.4 Memory Usage

**Definition**: Resident set size (RSS) of the daemon process after index is fully built and stable.

**Method**: Sample via `task_info` / `proc_pid_rusage` at steady state. Report `phys_footprint` (the value macOS uses for memory pressure).

| Tier | File Count | Expected RSS | Notes |
|------|-----------|-------------|-------|
| 10K | 10,000 | ~15 MB | |
| 100K | 100,000 | ~60 MB | |
| 1M | 1,000,000 | ~400 MB | |
| 10M | 10,000,000 | ~3.5 GB | |

**Memory breakdown** (approximate, 1M files):
- `FileRecord` array: ~120 MB (120 bytes/record)
- `Trie` (prefix index): ~80 MB
- `FullSubstringMap` (substring index): ~120 MB
- `TrigramIndex` (long-name index): ~20 MB
- `PinyinIndex` (Chinese filename index): ~5 MB
- SQLite page cache: ~20 MB
- Other (IPC buffers, config, etc.): ~35 MB

### 3.5 FSEvents Latency

**Definition**: Time from `write()` syscall completing on a file to that file appearing in search results.

**Method**:
1. Create script that writes a uniquely-named file in a monitored directory
2. Record timestamp of `write()` completion
3. Poll search for the unique filename
4. Report delta

| Metric | Target |
|--------|--------|
| Median latency | <100ms |
| p95 latency | <500ms |
| p99 latency | <1s |

**Notes**: FSEvents has inherent batching (~1s latency floor in some configurations). We measure end-to-end including FSEventStream callback + index insert + search visibility. Not tunable below FSEvents batching threshold.

### 3.6 Startup Time

**Definition**: Time from daemon process launch to accepting queries on the Unix socket.

**Method**: `ContinuousClock` measurement from `Process.start()` to first successful IPC ping response. Report separately for cold-start (no SQLite cache) and warm-start (SQLite cache populated).

| Scenario | 100K Files | 1M Files | 10M Files |
|----------|-----------|---------|-----------|
| Cold start | <3s | <20s | <4 min |
| Warm start | <1s | <2s | <5s |

### 3.7 Concurrent Query Throughput

**Definition**: Queries per second the daemon can sustain under concurrent load without latency degradation.

**Method**:
1. Spawn N concurrent clients (N ∈ {1, 4, 8, 16, 32})
2. Each client sends a continuous stream of random prefix queries
3. Measure total queries completed in 30 seconds
4. Report throughput and p99 latency at each concurrency level

| Concurrency | Target (queries/sec) | Notes |
|-------------|---------------------|-------|
| 1 client | >5,000 | Single-threaded client |
| 4 clients | >15,000 | |
| 8 clients | >25,000 | |
| 16 clients | >35,000 | Near actor saturation |
| 32 clients | >35,000 | Plateau; actor is the bottleneck |

---

## 4. Measurement Methodology

### 4.1 Hardware Specification

Every benchmark result MUST be accompanied by:

```markdown
| Field | Value |
|-------|-------|
| **Device** | MacBook Pro (16-inch, Nov 2025) |
| **Chip** | Apple M4 Pro (12-core CPU, 18-core GPU) |
| **Memory** | 48 GB unified |
| **SSD** | 1 TB Apple SSD (read ~7 GB/s) |
| **macOS** | 26.0 (Tahoe) build 26A300 |
| **Swift** | 6.2 |
| **Build config** | Release (`-c release`) |
| **Power** | AC power, High Performance mode |
| **Date** | 2026-06-03 |
```

### 4.2 Warm-Up Protocol

1. **System warm-up**: Run a dummy benchmark pass for 30 seconds before recording any measurements. This ensures CPU frequency has ramped, caches are populated, and the system is in steady state.
2. **Index warm-up**: For search benchmarks, execute 100 random queries before measurement. Discard these timings.
3. **Cold-start control**: For "cold" benchmarks, reboot the machine or use `sudo purge` + restart the daemon with a fresh cache directory.

### 4.3 Sample Count and Statistics

- **Minimum runs**: 5 per benchmark configuration
- **Recommended runs**: 11 (discard first, keep 10 for analysis)
- **Report**: median, mean, standard deviation, p95, p99
- **Outlier detection**: Values beyond 3σ from the mean of the remaining 10 runs are flagged and investigated. If reproducible, they indicate a real bimodal distribution (e.g., GC pause, thermal throttle) and are reported separately.
- **Stability check**: If stddev > 20% of mean, the benchmark is flagged as "high variance" and the cause must be documented.

### 4.4 Cold vs. Warm Cache Control

**Cold cache protocol**:
1. Stop the daemon
2. `sudo purge` (clears unified buffer cache, requires admin)
3. Remove `~/.deep-finder/cache/` directory
4. Start the daemon
5. Immediately run the benchmark

**Warm cache protocol**:
1. Ensure the daemon has been running for at least 60 seconds with the index loaded
2. Run 100 warm-up queries
3. Run the benchmark

### 4.5 CPU Frequency Pinning

On Apple Silicon, CPU frequency is managed by the performance controller and cannot be pinned from userspace. We control for this by:

1. **High Performance mode**: Enabled in System Settings > Battery > Options
2. **AC power**: Always on AC power (no battery throttling)
3. **Thermal headroom**: Ambient temperature 22°C ± 2°C. If the machine is thermally throttled (fans at max, `pmset -g thermlog` shows CPU_Speed_Limit < 100), the run is discarded.
4. **Background processes**: Close all non-essential applications. `systemstats` reset before starting.

### 4.6 Timing Instrumentation

Use `ContinuousClock` (Swift's monotonic, high-resolution clock) for all measurements:

```swift
let clock = ContinuousClock()
let duration = clock.measure {
    // benchmarked code
}
```

Do NOT use `Date`, `CFAbsoluteTimeGetCurrent()`, or `DispatchTime` — `ContinuousClock` is guaranteed monotonic and not affected by NTP adjustments or system sleep.

For sub-millisecond measurements, use `ContinuousClock.Instant` delta:

```swift
let start = ContinuousClock.now
// ... operation ...
let duration = ContinuousClock.now - start
let nanoseconds = duration / .nanoseconds(1)
```

### 4.7 Compiler Optimizations

- **Always** benchmark with `-c release` (optimized build)
- Verify that benchmarked code is not eliminated by dead-code elimination: consume the result (e.g., assert on expected count)
- Use `blackHole()`-style sinks for intermediate values that must not be optimized away:

```swift
@inline(never)
func sink<T>(_ value: T) { }
```

---

## 5. Benchmark Runner Design

### 5.1 Architecture

The benchmark runner is a Swift executable target `DeepFinderBenchmarks` in `Package.swift`, separate from the test targets. It links against the `DeepFinder` library.

```
Sources/
  BenchmarkEntry/         # Executable target — benchmark runner entry point
    main.swift
  Benchmark/              # Library target — benchmark infrastructure
    BenchmarkRunner.swift
    BenchmarkConfig.swift
    BenchmarkResult.swift
    DataSetGenerator.swift
    Reporter/
      ConsoleReporter.swift
      CSVReporter.swift
      JSONReporter.swift
      MarkdownReporter.swift
```

### 5.2 Command-Line Interface

```bash
# Run all benchmarks at default scale (100K files)
swift run -c release deepfinder-benchmarks

# Run specific dimensions
swift run -c release deepfinder-benchmarks --suite search
swift run -c release deepfinder-benchmarks --suite index --suite memory

# Run specific scales
swift run -c release deepfinder-benchmarks --scale small
swift run -c release deepfinder-benchmarks --scale medium --scale large

# Output formats
swift run -c release deepfinder-benchmarks --output json     # JSON to stdout
swift run -c release deepfinder-benchmarks --output csv      # CSV to stdout
swift run -c release deepfinder-benchmarks --output markdown # Markdown table
swift run -c release deepfinder-benchmarks --output all      # All formats to ./benchmark-results/

# Regression mode (compare against stored baseline)
swift run -c release deepfinder-benchmarks --regression --baseline ./baselines/v3.0.0.json

# CI mode (exit non-zero on regression)
swift run -c release deepfinder-benchmarks --ci --threshold 1.5

# Custom data
swift run -c release deepfinder-benchmarks --data-path /path/to/custom/corpus

# List available suites
swift run -c release deepfinder-benchmarks --list-suites

# Dry run (print what would be executed)
swift run -c release deepfinder-benchmarks --dry-run
```

### 5.3 Configuration File

`benchmark-config.json` at the repo root (overridable via `--config`):

```json
{
  "scales": ["small", "medium", "large"],
  "suites": ["index", "search", "memory", "fsevents", "startup", "concurrent"],
  "runsPerBenchmark": 11,
  "warmupRuns": 1,
  "warmupQueries": 100,
  "outputDir": "./benchmark-results",
  "outputFormats": ["json", "markdown"],
  "dataDir": "/tmp/deepfinder-bench-data",
  "seed": 42,
  "timeout": 600,
  "hardwareReport": true,
  "thresholds": {
    "regressionWarning": 1.2,
    "regressionFailure": 2.0
  }
}
```

### 5.4 Suite Definitions

```swift
enum BenchmarkSuite: String, CaseIterable {
    case index      // Index build + load
    case search     // All search types
    case memory     // RSS measurement
    case fsevents   // FSEvents latency
    case startup    // Daemon startup time
    case concurrent // Throughput under load
    case all        // Every suite
}

struct BenchmarkDefinition {
    let name: String
    let suite: BenchmarkSuite
    let scales: [DataSetScale]
    let measure: (BenchmarkContext) async throws -> BenchmarkMeasurement
}
```

### 5.5 Output Schema

**JSON format**:

```json
{
  "metadata": {
    "version": "3.0.0",
    "timestamp": "2026-06-03T10:30:00Z",
    "hardware": {
      "model": "MacBook Pro (16-inch, Nov 2025)",
      "chip": "Apple M4 Pro",
      "cores": 12,
      "memoryGB": 48,
      "macOS": "26.0",
      "swiftVersion": "6.2"
    },
    "buildConfig": "release"
  },
  "benchmarks": [
    {
      "name": "index-build-time",
      "suite": "index",
      "scale": "large",
      "fileCount": 1000000,
      "unit": "milliseconds",
      "runs": 11,
      "warmupRuns": 1,
      "statistics": {
        "median": 12450,
        "mean": 12530,
        "stddev": 342,
        "p95": 13100,
        "p99": 13450,
        "min": 12080,
        "max": 13620
      },
      "threshold": {
        "warning": 15000,
        "failure": 30000
      },
      "status": "pass"
    }
  ]
}
```

**CSV format**:

```csv
benchmark,suite,scale,fileCount,unit,median,mean,stddev,p95,p99,status
index-build-time,index,large,1000000,ms,12450,12530,342,13100,13450,pass
search-prefix,search,large,1000000,us,850,920,45,1100,1300,pass
```

**Markdown table format** (for README/docs):

```markdown
| Benchmark | Scale | Median | Mean | p95 | p99 | Status |
|-----------|-------|--------|------|-----|-----|--------|
| Index build | 1M files | 12.45s | 12.53s | 13.10s | 13.45s | ✅ |
| Prefix search | 1M files | 0.85ms | 0.92ms | 1.10ms | 1.30ms | ✅ |
| Substring search | 1M files | 2.30ms | 2.45ms | 3.10ms | 3.80ms | ✅ |
| Memory (RSS) | 1M files | 395 MB | — | — | — | ✅ |
```

---

## 6. Results Template

### 6.1 Per-Version Results Page

Each tagged version should have a benchmark results file at `docs/reference/benchmark-results/vX.Y.Z.md`:

```markdown
# DeepFinder v3.0.0 Benchmark Results

## Hardware

| Field | Value |
|-------|-------|
| Device | MacBook Pro (16-inch, Nov 2025) |
| Chip | Apple M4 Pro (12-core CPU) |
| Memory | 48 GB unified |
| SSD | 1 TB |
| macOS | 26.0 (Tahoe) |
| Swift | 6.2 |
| Build | Release |

## Index Performance

| Benchmark | 10K | 100K | 1M | 10M |
|-----------|-----|------|----|-----|
| Build time (cold) | 0.32s | 1.85s | 12.45s | 2m 48s |
| Load time (warm) | 0.05s | 0.18s | 0.62s | 2.34s |
| Memory (RSS) | 14 MB | 58 MB | 395 MB | 3.4 GB |

## Search Latency (1M files, median/p99)

| Query Type | Median | p95 | p99 |
|------------|--------|-----|-----|
| Prefix | 0.85ms | 1.10ms | 1.30ms |
| Substring | 2.30ms | 3.10ms | 3.80ms |
| Regex | 245ms | 320ms | 410ms |
| Pinyin | 0.42ms | 0.68ms | 0.91ms |
| Content (first result) | 1.2s | 2.1s | 3.5s |
| Semantic (local) | 45ms | 72ms | 95ms |
| Boolean + filter | 1.10ms | 1.80ms | 2.40ms |

## Competitor Comparison

| Metric | DeepFinder (macOS) | Everything (Windows) | Notes |
|--------|-------------------|---------------------|-------|
| 1M file index build | 12.45s | ~60s (MFT read) | Everything reads NTFS MFT directly |
| 1M file prefix search | 0.85ms | ~1ms (anecdotal) | Comparable; different HW |
| Memory (1M files) | 395 MB | ~100 MB | Everything stores less metadata |
| FSEvents latency | <100ms | <1s (USN journal poll) | Different OS mechanisms |

> **Comparison notes**: Everything benchmarks performed on same machine via Windows 11 ARM on Parallels Desktop, NTFS partition on Apple SSD. Not perfectly comparable due to virtualization overhead and OS differences. Documented for transparency.

## Historical Tracking

| Version | Index Build (1M) | Prefix (1M) | Memory (1M) | Date |
|---------|-----------------|-------------|-------------|------|
| v3.0.0 | 12.45s | 0.85ms | 395 MB | 2026-06-03 |
| v2.2.0 | 11.80s | 0.82ms | 380 MB | 2026-04-15 |
| v2.0.0 | 11.20s | 0.78ms | 370 MB | 2026-03-01 |
| v1.5.0 | 10.90s | 0.75ms | 360 MB | 2026-01-20 |
| v1.0.0 | 10.50s | 0.72ms | 350 MB | 2025-12-01 |
```

### 6.2 Competitor Data Collection

We collect competitor benchmark data under controlled conditions:

**Everything (voidtools)**:
- Run on Windows 11 ARM via Parallels Desktop on the same Apple Silicon hardware
- Use Everything 1.5a with default settings
- Measure index build time (Tools > Debug > Statistics), search latency (manual timing or Everything SDK)
- Document virtualization overhead caveats

**Spotlight**:
- Measure via `mdfind` command-line tool
- Compare: `time mdfind "kMDItemFSName == '*report*'"` vs `time deepfinder "report"`
- Note: Spotlight indexes content + metadata (not just filenames), so comparison is inherently unfair — we benchmark filename search only for apples-to-apples

**fd / fzf**:
- `fd` is a stateless scanner (no index) — compare against DeepFinder's content search, not prefix/substring
- `time fd "pattern" /search/root`

---

## 7. CI Integration

### 7.1 GitHub Actions Workflow

```yaml
# .github/workflows/benchmarks.yml
name: Benchmarks

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 8 * * 1'  # Every Monday at 8am UTC

jobs:
  benchmark:
    runs-on: macos-26-arm64
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Build benchmark runner
        run: swift build -c release --target DeepFinderBenchmarks
      - name: Run benchmarks (small + medium)
        run: swift run -c release deepfinder-benchmarks \
          --scale small --scale medium \
          --output json \
          --output markdown \
          --ci --threshold 2.0
      - name: Compare against baseline
        run: swift run -c release deepfinder-benchmarks \
          --regression \
          --baseline ./baselines/v3.0.0.json
      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: benchmark-results
          path: benchmark-results/
```

### 7.2 Regression Detection

1. **Baseline storage**: Baseline JSON files committed to `baselines/` directory, one per tagged version.
2. **Comparison logic**: For each benchmark, compare current median against baseline median. If the ratio exceeds `regressionWarning` (default 1.2x), emit a CI warning comment on the PR. If it exceeds `regressionFailure` (default 2.0x), fail the CI check.
3. **Thresholds per benchmark**: Some benchmarks have tighter thresholds:

| Benchmark | Warning | Failure | Rationale |
|-----------|---------|---------|-----------|
| Prefix search latency | 1.5x | 3.0x | Some variance expected from system load |
| Index build time | 1.3x | 2.0x | I/O-bound; less sensitive to code changes |
| Memory usage | 1.1x | 1.3x | Memory regressions are rarely acceptable |
| Regex search | 1.2x | 2.0x | Linear scan; proportional to file count |

### 7.3 Baseline Update Policy

- New baselines are generated on every tagged release (`v*.*.*` tag push)
- PRs that intentionally change performance characteristics must include a baseline update commit (with justification in the PR description)
- Baseline updates without justification are rejected during review
- Historical baselines are never deleted — they form the performance history of the project

### 7.4 Local Regression Check

```bash
# Before submitting a PR, check for regressions locally:
swift run -c release deepfinder-benchmarks --regression --baseline ./baselines/v3.0.0.json

# Output:
# ✅ index-build-time: 12.45s (baseline 12.38s, +0.6%, OK)
# ✅ search-prefix: 0.85ms (baseline 0.82ms, +3.7%, OK)
# ⚠️  memory-rss: 410 MB (baseline 395 MB, +3.8%, WARNING — explain in PR)
# ❌ search-substring: 5.20ms (baseline 2.30ms, +126%, FAIL — must fix before merge)
```

---

## Appendix A: Existing Microbenchmarks

DeepFinder already contains microbenchmarks in the test suite. These validate algorithm-level performance and are distinct from the end-to-end system benchmarks defined in this document.

| File | What It Benchmarks | Scale |
|------|-------------------|-------|
| `Tests/IndexTests/IndexBenchmarks.swift` | Trie, FullSubstringMap, TrigramIndex, PinyinIndex, InMemoryIndex insert + search | 10K entries |
| `Tests/SearchTests/SearchBenchmarks.swift` | Index construction, search latency, sort performance | 10K records |
| `Tests/DaemonTests/ConcurrencyStressTests.swift` | Actor isolation correctness, concurrent insert+search | 100-1000 ops |

Run: `swift test --filter IndexBenchmarks` / `swift test --filter SearchBenchmarks`

These are fast (<5 seconds total), run on every CI push, and catch algorithmic regressions. The end-to-end benchmarks in this document complement them with real-system measurements at scale.

## Appendix B: Data Set Generation Implementation

The `scripts/generate-benchmark-data.swift` script will:

1. Accept `--count`, `--seed`, `--output` parameters
2. Use a seeded PRNG (`SplitMix64` or similar, implemented in pure Swift) for deterministic generation
3. Create the directory tree under `--output`
4. Write a `manifest.json` describing the generated data (count, seed, timestamp, distribution parameters)
5. Use sparse files (`ftruncate` with hole) for content to minimize SSD wear
6. Generate files in parallel using `TaskGroup` for speed

## Appendix C: Quick Start

```bash
# 1. Generate test data
swift run -c release generate-benchmark-data --count 100000 --seed 42

# 2. Run all benchmarks on the generated data
swift run -c release deepfinder-benchmarks --scale medium

# 3. View results
cat benchmark-results/results.md

# 4. Run a specific dimension for faster feedback during development
swift run -c release deepfinder-benchmarks --suite search --scale small

# 5. Check for regressions against v3.0.0 baseline
swift run -c release deepfinder-benchmarks --regression --baseline baselines/v3.0.0.json
```
