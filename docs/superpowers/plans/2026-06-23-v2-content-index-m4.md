# DeepFinder v2 — M4 Streaming Full-Disk Build (Phase 2 start) Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Replace df-index's unbounded in-memory buffer with a streaming, bounded-RSS pipeline that walks a whole disk once, classifies each file (text/binary/too-large), and builds BOTH the filename DB and the content `.dfcs` shard set — flushing shards at ~128 MB and writing a MANIFEST.

**Architecture:** A bounded `crossbeam-channel` between `ignore::WalkParallel` workers (producers: walk + text-gate + read content, parallelized) and a single consumer thread (owns the filename `DbBuilder` + current `ShardBuilder`; flushes a shard when its contentCorpus crosses the threshold). After the walk drains, the consumer finalizes the last shard + filename DB; the main thread writes the filename DB + MANIFEST atomically.

**Tech Stack:** Rust ws; `crossbeam-channel` (bounded pipeline); reuse `df_core::DbBuilder`, `df_content::ShardBuilder`, `df_index::{atomic_write, DEFAULT_SKIP, MmapSource}`; `ignore::WalkBuilder` (`same_file_system`, `standard_filters`, `hidden`). No new syscall deps (RLIMIT_NOFILE deferred to M7).

**Scope:** M4 only. M5 (daemon ShardSet + combined results), M6 (CLI `--content` flags), M7 (harden) planned after M4's streaming API is concrete.

---

## File structure (M4)

- **Modify** `Cargo.toml` (workspace) — add `crossbeam-channel = "0.5"` to `[workspace.dependencies]`.
- **Modify** `crates/df-index/Cargo.toml` — deps: `crossbeam-channel`, `df-content`; dev-dep stays `tempfile`.
- **Modify** `crates/df-content/src/shard.rs` — add `pub fn content_bytes(&self) -> usize`.
- **Create** `crates/df-index/src/content_build.rs` — `ContentBuildOptions`, `ContentReport`, text-gate, streaming `build_content_index`.
- **Create** `crates/df-index/src/manifest.rs` — `Manifest` read/write.
- **Modify** `crates/df-index/src/lib.rs` — `pub mod {content_build, manifest};` + re-exports.
- **Create** `crates/df-index/tests/content_build.rs` — integration: build a temp tree → shards + MANIFEST + query roundtrip.
- **Modify** `crates/deepfind/src/main.rs` — `index` builds content by default; new `--max-file-size`, `--no-content`, `--one-file-system` flags.

---

## Task 1: `crossbeam-channel` dep + `ShardBuilder::content_bytes()`

**Files:** `Cargo.toml`, `crates/df-index/Cargo.toml`, `crates/df-content/src/shard.rs`, `crates/df-index/src/lib.rs`

- [ ] **Step 1:** In workspace `Cargo.toml` `[workspace.dependencies]` add `crossbeam-channel = "0.5"`.
- [ ] **Step 2:** In `crates/df-index/Cargo.toml` `[dependencies]` add `crossbeam-channel = { workspace = true }` and `df-content = { workspace = true }` (moved from dev-deps to deps — the build pipeline builds content shards).
- [ ] **Step 3:** In `crates/df-content/src/shard.rs`, inside `impl ShardBuilder` add:
```rust
    /// Current contentCorpus size in bytes (flush-threshold check).
    pub fn content_bytes(&self) -> usize {
        self.corpus.len()
    }
```
- [ ] **Step 4:** In `crates/df-index/src/lib.rs` add `pub mod content_build; pub mod manifest;` (empty stubs for now — see Step 5) and re-exports after the modules exist (Task 2/4 fill them). For this task, just add the deps + accessor.
- [ ] **Step 5:** Create empty stub modules so the workspace builds: `crates/df-index/src/content_build.rs` and `crates/df-index/src/manifest.rs` each containing just the SPDX header comment + nothing else. Add the `pub mod` lines to lib.rs.
- [ ] **Step 6:** `cargo build 2>&1 | tail -3` — clean. `cargo fmt`.
- [ ] **Step 7:** Commit:
```bash
git add Cargo.toml Cargo.lock crates/df-index/Cargo.toml crates/df-index/src/lib.rs crates/df-index/src/content_build.rs crates/df-index/src/manifest.rs crates/df-content/src/shard.rs
git commit -m "feat(index): add crossbeam-channel dep, ShardBuilder::content_bytes, M4 stubs"
```

---

## Task 2: text-gate (classify + read content)

**Files:** `crates/df-index/src/content_build.rs`

- [ ] **Step 1:** Write the text-gate. Replace the stub with:
```rust
// SPDX-License-Identifier: MIT
//! Streaming full-disk content build: walk → text-gate → dual builders → shard flush.

use std::path::Path;

/// What the text-gate decided about a file's content.
pub enum ContentDecision {
    /// Text; these (size-capped) bytes should be indexed.
    Text(Vec<u8>),
    /// Binary (NUL byte or excessive trigram diversity) — filename only.
    Binary,
    /// Larger than the size cap — filename only.
    TooLarge,
    /// Unreadable / vanished — filename only.
    Unreadable,
}

const NUL_SCAN_BYTES: usize = 8 * 1024;
const TRIGRAM_MAX: usize = 20_000;

/// Read up to `max_file_size` bytes of `path` and classify it. Files larger than
/// the cap are TooLarge (no bytes read fully). NUL in the first 8 KB, or more
/// than `TRIGRAM_MAX` distinct byte trigrams ⇒ Binary.
pub fn classify(path: &Path, max_file_size: u64) -> ContentDecision {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return ContentDecision::Unreadable,
    };
    if !meta.is_file() {
        return ContentDecision::Unreadable;
    }
    if meta.len() > max_file_size {
        return ContentDecision::TooLarge;
    }
    let cap = max_file_size as usize;
    let mut bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => return ContentDecision::Unreadable,
    };
    bytes.truncate(cap);
    let scan = bytes.len().min(NUL_SCAN_BYTES);
    if bytes[..scan].contains(&0u8) {
        return ContentDecision::Binary;
    }
    if bytes.len() >= 3 && distinct_trigrams(&bytes) > TRIGRAM_MAX {
        return ContentDecision::Binary;
    }
    ContentDecision::Text(bytes)
}

/// Count distinct byte trigrams (lowercased) — the binary/minified heuristic.
fn distinct_trigrams(bytes: &[u8]) -> usize {
    let mut folded = bytes.to_vec();
    for b in &mut folded {
        if b.is_ascii_uppercase() {
            *b |= 0x20;
        }
    }
    let mut set = std::collections::HashSet::new();
    for w in folded.windows(3) {
        set.insert((w[0], w[1], w[2]));
    }
    set.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_file_is_text() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("a.txt");
        std::fs::write(&p, b"fn main() { hello world }").unwrap();
        assert!(matches!(classify(&p, 1024 * 1024), ContentDecision::Text(_)));
    }

    #[test]
    fn nul_byte_is_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("b.bin");
        std::fs::write(&p, b"abc\x00def").unwrap();
        assert_eq!(classify(&p, 1024 * 1024) as u8 & 0, 0); // compiles; use matches!
    }

    #[test]
    fn oversized_is_too_large() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("big.txt");
        std::fs::write(&p, vec![b'a'; 10]).unwrap();
        assert!(matches!(classify(&p, 5), ContentDecision::TooLarge));
    }
}
```
Fix the `nul_byte_is_binary` test (the `as u8 & 0` line is a placeholder — replace with):
```rust
        assert!(matches!(classify(&p, 1024 * 1024), ContentDecision::Binary));
```
- [ ] **Step 2:** `cargo test -p df-index --lib 2>&1 | tail -8` — 3 tests pass (text/binary/too-large). `cargo clippy -p df-index --all-targets -- -D warnings 2>&1 | tail -3` clean. `cargo fmt`.
- [ ] **Step 3:** Commit:
```bash
git add crates/df-index/src/content_build.rs
git commit -m "feat(index): text-gate classify() — NUL/trigram-diversity/size-cap"
```

---

## Task 3: MANIFEST read/write

**Files:** `crates/df-index/src/manifest.rs`

- [ ] **Step 1:** Replace the stub:
```rust
// SPDX-License-Identifier: MIT
//! Content shard MANIFEST: the shard list + base_docid map + build_time, written
//! atomically alongside the `.dfcs` files.

use std::path::{Path, PathBuf};

use df_core::varint::{decode_u32, encode_u32};

/// One entry per content shard.
#[derive(Debug, Clone)]
pub struct ShardEntry {
    pub shard_id: u32,
    pub base_docid: u32,
    pub num_docs: u32,
    pub file: String, // shard-NNNNN.dfcs (filename within the content dir)
}

#[derive(Debug, Clone)]
pub struct Manifest {
    pub build_time: u64,
    pub total_content_docs: u32,
    pub shards: Vec<ShardEntry>,
}

impl Manifest {
    /// Serialize (custom, varint-friendly): build_time:u64, total:u32, count:u32,
    /// then per shard (id:u32, base:u32, num:u32, varint file-len, file bytes).
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.build_time.to_le_bytes());
        out.extend_from_slice(&self.total_content_docs.to_le_bytes());
        out.extend_from_slice(&self.shards.len().to_le_bytes());
        for s in &self.shards {
            out.extend_from_slice(&s.shard_id.to_le_bytes());
            out.extend_from_slice(&s.base_docid.to_le_bytes());
            out.extend_from_slice(&s.num_docs.to_le_bytes());
            encode_u32(s.file.len() as u32, &mut out);
            out.extend_from_slice(s.file.as_bytes());
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 16 {
            return None;
        }
        let bt = u64::from_le_bytes(bytes[0..8].try_into().ok()?);
        let total = u32::from_le_bytes(bytes[8..12].try_into().ok()?);
        let count = u32::from_le_bytes(bytes[12..16].try_into().ok()?) as usize;
        let mut p = 16usize;
        let mut shards = Vec::with_capacity(count);
        for _ in 0..count {
            if p + 12 > bytes.len() {
                return None;
            }
            let id = u32::from_le_bytes(bytes[p..p + 4].try_into().ok()?);
            let base = u32::from_le_bytes(bytes[p + 4..p + 8].try_into().ok()?);
            let num = u32::from_le_bytes(bytes[p + 8..p + 12].try_into().ok()?);
            p += 12;
            let flen = decode_u32(bytes, &mut p)? as usize;
            if p + flen > bytes.len() {
                return None;
            }
            let file = String::from_utf8(bytes[p..p + flen].to_vec()).ok()?;
            p += flen;
            shards.push(ShardEntry { shard_id: id, base_docid: base, num_docs: num, file });
        }
        Some(Manifest { build_time: bt, total_content_docs: total, shards })
    }

    /// Read the MANIFEST file at `path`.
    pub fn read(path: &Path) -> Option<Self> {
        let bytes = std::fs::read(path).ok()?;
        Self::decode(&bytes)
    }
}

/// Write a MANIFEST atomically.
pub fn write_manifest(path: &Path, manifest: &Manifest) -> std::io::Result<()> {
    super::atomic_write_public(path, &manifest.encode())
}
```
- [ ] **Step 2:** `atomic_write` is currently private in `crates/df-index/src/lib.rs`. Add a `pub(crate)` alias or make it `pub`. Simplest: rename usage — add to lib.rs:
```rust
/// Public alias so sibling modules can write atomically.
pub(crate) fn atomic_write_public(path: &Path, data: &[u8]) -> std::io::Result<()> {
    atomic_write(path, data).map_err(|e| match e {
        IndexError::Io(io) => io,
        _ => std::io::Error::other(e),
    })
}
```
(If `atomic_write` returns `IndexError`, adapt; the existing `atomic_write` signature is `fn atomic_write(path: &Path, data: &[u8]) -> Result<()>` where Result is `crate::Result`. Convert to `std::io::Result` as above.)
- [ ] **Step 3:** Test roundtrip in `manifest.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_roundtrip() {
        let m = Manifest {
            build_time: 555,
            total_content_docs: 100,
            shards: vec![
                ShardEntry { shard_id: 0, base_docid: 0, num_docs: 50, file: "shard-00000.dfcs".into() },
                ShardEntry { shard_id: 1, base_docid: 50, num_docs: 50, file: "shard-00001.dfcs".into() },
            ],
        };
        let bytes = m.encode();
        let back = Manifest::decode(&bytes).unwrap();
        assert_eq!(back.build_time, 555);
        assert_eq!(back.total_content_docs, 100);
        assert_eq!(back.shards.len(), 2);
        assert_eq!(back.shards[1].base_docid, 50);
        assert_eq!(back.shards[1].file, "shard-00001.dfcs");
    }
}
```
- [ ] **Step 4:** `cargo test -p df-index --lib 2>&1 | tail -8` — pass. clippy/fmt clean.
- [ ] **Step 5:** Commit:
```bash
git add crates/df-index/src/manifest.rs crates/df-index/src/lib.rs
git commit -m "feat(index): MANIFEST encode/decode + atomic write helper"
```

---

## Task 4: streaming `build_content_index`

**Files:** `crates/df-index/src/content_build.rs`, `crates/df-index/src/lib.rs`

- [ ] **Step 1:** Add the options/report + streaming pipeline to `content_build.rs` (append below the text-gate code):
```rust
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use crossbeam_channel::bounded;
use df_content::ShardBuilder;
use df_core::db::DbBuilder;
use ignore::{WalkBuilder, WalkState};

use crate::manifest::{Manifest, ShardEntry};
use crate::{atomic_write_public, DEFAULT_SKIP};

/// Shard flush threshold (contentCorpus bytes).
const SHARD_FLUSH_BYTES: usize = 128 * 1024 * 1024;
/// Bounded channel capacity (records in flight).
const CHANNEL_CAP: usize = 64;
const DEFAULT_MAX_FILE_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ContentBuildOptions {
    pub max_file_size: u64,
    pub extra_skip: Vec<String>,
    pub one_file_system: bool,
}

impl Default for ContentBuildOptions {
    fn default() -> Self {
        Self { max_file_size: DEFAULT_MAX_FILE_SIZE, extra_skip: Vec::new(), one_file_system: false }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ContentReport {
    pub filename_docs: u32,
    pub content_docs: u32,
    pub shards: u32,
    pub denied: u32,
    pub content_skipped_binary: u32,
    pub content_skipped_large: u32,
}

/// One record streamed from a walk worker to the consumer.
struct BuildRec {
    path: String,
    is_dir: bool,
    size: i64,
    mtime: i64,
    content: Option<Vec<u8>>, // None ⇒ filename-only (binary/large/dir)
}

/// Build the filename DB (`out_db`) AND the content shard set (`content_dir`)
/// in one streaming pass. Writes `content_dir/MANIFEST`. Full-rebuild: old shards
/// not in the new manifest are left in place (caller may garbage-collect).
pub fn build_content_index(
    root: &Path,
    out_db: &Path,
    content_dir: &Path,
    opts: &ContentBuildOptions,
) -> crate::Result<ContentReport> {
    let mut skip: Vec<&str> = DEFAULT_SKIP.to_vec();
    for e in &opts.extra_skip {
        if !e.is_empty() && !skip.contains(&e.as_str()) {
            skip.push(e.as_str());
        }
    }

    let (tx, rx) = bounded::<BuildRec>(CHANNEL_CAP);
    let build_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Consumer owns both builders; flushes shards as it goes.
    let content_dir = content_dir.to_path_buf();
    let consumer = std::thread::spawn(move || -> crate::Result<ConsumerOut> {
        let mut fnb = DbBuilder::new();
        fnb.set_build_time(build_time);
        let mut shard_id = 0u32;
        let mut base_docid = 0u32;
        let mut shard = ShardBuilder::new(shard_id, base_docid);
        let mut content_docs = 0u32;
        let mut skipped_binary = 0u32;
        let mut skipped_large = 0u32;
        let mut shard_entries: Vec<ShardEntry> = Vec::new();
        std::fs::create_dir_all(&content_dir)?;

        while let Ok(rec) = rx.recv() {
            fnb.insert_with(&rec.path, rec.is_dir, rec.size, rec.mtime);
            match rec.content {
                Some(bytes) => {
                    shard.add_file(&rec.path, rec.is_dir, rec.size, rec.mtime, &bytes);
                    content_docs += 1;
                    if shard.content_bytes() >= SHARD_FLUSH_BYTES {
                        let n = shard.doc_count();
                        let sbytes = shard.finish(build_time);
                        let fname = format!("shard-{shard_id:05}.dfcs");
                        atomic_write_public(&content_dir.join(&fname), &sbytes)?;
                        shard_entries.push(ShardEntry {
                            shard_id, base_docid, num_docs: n, file: fname,
                        });
                        shard_id += 1;
                        base_docid += n;
                        shard = ShardBuilder::new(shard_id, base_docid);
                    }
                }
                None => {
                    // filename-only: classify reason is folded into the worker.
                }
            }
        }
        let _ = (skipped_binary, skipped_large); // tallied on workers; see below
        // final partial shard (if any docs)
        if shard.doc_count() > 0 {
            let n = shard.doc_count();
            let sbytes = shard.finish(build_time);
            let fname = format!("shard-{shard_id:05}.dfcs");
            atomic_write_public(&content_dir.join(&fname), &sbytes)?;
            shard_entries.push(ShardEntry { shard_id, base_docid, num_docs: n, file: fname });
        }
        let filename_docs = fnb.doc_count();
        let fn_bytes = fnb.finish();
        Ok(ConsumerOut { fn_bytes, content_docs, shard_entries, filename_docs })
    });

    let denied = Arc::new(AtomicU32::new(0));
    let skipped_binary = Arc::new(AtomicU32::new(0));
    let skipped_large = Arc::new(AtomicU32::new(0));

    let mut walker = WalkBuilder::new(root);
    walker.standard_filters(true).hidden(true).same_file_system(opts.one_file_system);
    let tx2 = tx.clone();
    let d2 = denied.clone();
    let sb2 = skipped_binary.clone();
    let sl2 = skipped_large.clone();
    let mfs = opts.max_file_size;
    walker.build_parallel().run(move || {
        let tx = tx2.clone();
        let d = d2.clone();
        let sb = sb2.clone();
        let sl = sl2.clone();
        Box::new(move |result| {
            let entry = match result {
                Ok(e) => e,
                Err(e) => {
                    if e.io_error().is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied) {
                        d.fetch_add(1, Ordering::Relaxed);
                    }
                    return WalkState::Continue;
                }
            };
            let name = entry.file_name().to_string_lossy();
            if entry.file_type().is_some_and(|t| t.is_dir()) && skip.iter().any(|s| name == *s) {
                return WalkState::Skip;
            }
            let Some(path_str) = entry.path().to_str() else { return WalkState::Continue; };
            let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
            let (size, mtime) = match entry.metadata() {
                Ok(md) => (
                    md.len() as i64,
                    md.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|x| x.as_secs() as i64).unwrap_or(0),
                ),
                Err(_) => (0, 0),
            };
            let content = if is_dir {
                None
            } else {
                match classify(entry.path(), mfs) {
                    ContentDecision::Text(b) => Some(b),
                    ContentDecision::Binary => { sb.fetch_add(1, Ordering::Relaxed); None }
                    ContentDecision::TooLarge => { sl.fetch_add(1, Ordering::Relaxed); None }
                    ContentDecision::Unreadable => None,
                }
            };
            if tx.send(BuildRec { path: path_str.to_string(), is_dir, size, mtime, content }).is_err() {
                return WalkState::Quit;
            }
            WalkState::Continue
        })
    });
    drop(tx); // close the last sender → consumer's recv() returns Err → finalize

    let out = consumer.join().expect("consumer thread panicked")?;
    atomic_write_public(out_db, &out.fn_bytes)?;

    let manifest = Manifest {
        build_time,
        total_content_docs: out.content_docs,
        shards: out.shard_entries,
    };
    atomic_write_public(&content_dir.join("MANIFEST"), &manifest.encode())?;

    Ok(ContentReport {
        filename_docs: out.filename_docs,
        content_docs: out.content_docs,
        shards: manifest.shards.len() as u32,
        denied: denied.load(Ordering::Relaxed),
        content_skipped_binary: skipped_binary.load(Ordering::Relaxed),
        content_skipped_large: skipped_large.load(Ordering::Relaxed),
    })
}

struct ConsumerOut {
    fn_bytes: Vec<u8>,
    content_docs: u32,
    shard_entries: Vec<ShardEntry>,
    filename_docs: u32,
}
```
**Fixups to apply (the implementer must resolve these):**
- `crate::Result` is `df_index::Result` (alias for `Result<_, IndexError>`). The consumer closure returns `crate::Result<ConsumerOut>`; `std::fs::create_dir_all` returns `io::Result` → convert with `?` via `From<io::Error>` (IndexError has `Io` variant — verify `IndexError` derives `From<io::Error>`; if not, add it). Check `crates/df-index/src/error.rs`.
- `atomic_write_public` must exist (Task 3 Step 2) returning `std::io::Result<()>`. In `build_content_index` it's called inside a `crate::Result` return — wrap with `.map_err(IndexError::from)` or have a `crate::Result`-returning variant. Cleanest: make `atomic_write_public` return `crate::Result<()>` (same as `atomic_write`). Adjust Task 3 Step 2 accordingly: `pub(crate) fn atomic_write_public(path, data) -> crate::Result<()> { atomic_write(path, data) }`.
- Remove the dead `let _ = (skipped_binary, skipped_large);` line (the tallies are on the worker atomics, surfaced via the report).
- [ ] **Step 2:** In `crates/df-index/src/lib.rs` add re-exports:
```rust
pub use content_build::{build_content_index, ContentBuildOptions, ContentReport};
pub use manifest::{Manifest, ShardEntry};
```
- [ ] **Step 3:** `cargo build -p df-index 2>&1 | tail -5` — clean (fix the error-result plumbing above until it compiles). `cargo clippy -p df-index --all-targets -- -D warnings 2>&1 | tail -3`. `cargo fmt`.
- [ ] **Step 4:** Commit:
```bash
git add crates/df-index/src/content_build.rs crates/df-index/src/lib.rs crates/df-index/src/error.rs
git commit -m "feat(index): streaming build_content_index — walk→channel→dual builders→shard flush"
```

---

## Task 5: integration test (build → shards + MANIFEST → query)

**Files:** `crates/df-index/tests/content_build.rs`

- [ ] **Step 1:**
```rust
// SPDX-License-Identifier: MIT
//! End-to-end: build a temp tree with text + binary + oversized files, then
//! verify shards + MANIFEST + a content query.

use df_content::{ShardBuilder as _, ShardReader};
use df_core::candidate::candidates;
use df_index::{build_content_index, ContentBuildOptions, Manifest, MmapSource};
use std::path::Path;

#[test]
fn build_content_index_end_to_end() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    std::fs::write(root.join("a.rs"), b"fn alpha() {}").unwrap();
    std::fs::write(root.join("b.rs"), b"fn beta() {}").unwrap();
    std::fs::write(root.join("bin.dat"), b"abc\x00def").unwrap(); // binary
    std::fs::write(root.join("big.txt"), vec![b'z'; 100]).unwrap(); // >cap when cap is tiny

    let db = tmp.path().join("index.dfdb");
    let content_dir = tmp.path().join("content");
    let opts = ContentBuildOptions { max_file_size: 10, ..Default::default() };
    let report = build_content_index(root, &db, &content_dir, &opts).unwrap();

    // filename DB has all 4 files; content has the 2 text .rs files (binary + oversized excluded).
    assert!(report.filename_docs >= 4, "filename_docs={}", report.filename_docs);
    assert_eq!(report.content_docs, 2, "content_docs={}", report.content_docs);
    assert!(report.content_skipped_binary >= 1);
    assert!(report.content_skipped_large >= 1);
    assert!(db.is_file());

    let manifest = Manifest::read(&content_dir.join("MANIFEST")).expect("MANIFEST readable");
    assert!(!manifest.shards.is_empty());
    assert_eq!(manifest.total_content_docs, 2);

    // mmap the shard and query "alpha" → only a.rs.
    let shard_path = content_dir.join(&manifest.shards[0].file);
    let src = MmapSource::open(&shard_path).unwrap();
    let r = ShardReader::open(src.as_slice()).unwrap();
    let folded = df_content::fold::fold(b"alpha");
    let got = candidates(&r, &folded, None).unwrap();
    assert!(got.iter().any(|&d| r.path(d).unwrap().ends_with("a.rs")));
    let folded = df_content::fold::fold(b"beta");
    let got = candidates(&r, &folded, None).unwrap();
    assert!(got.iter().any(|&d| r.path(d).unwrap().ends_with("b.rs")));
    // binary content not indexed: "abc" (from bin.dat) should not surface as content.
    // (it may match filenames if path contains it — here paths are a.rs/b.rs/bin.dat/big.txt.)
    let _ = Path::new(""); // silence unused import if Path unused
}
```
Note: `ShardBuilder as _` import is unused — remove it. The query uses `r.path(d)` (local docid). `df_content::fold::fold` is public. `MmapSource::open` + `as_slice` from df-index.
- [ ] **Step 2:** `cargo test -p df-index --test content_build 2>&1 | tail -8` — pass. clippy/fmt clean.
- [ ] **Step 3:** Commit:
```bash
git add crates/df-index/tests/content_build.rs
git commit -m "test(index): build_content_index end-to-end (shards + MANIFEST + query)"
```

---

## Task 6: CLI wiring

**Files:** `crates/deepfind/src/main.rs`, `crates/deepfind/Cargo.toml`

- [ ] **Step 1:** `crates/deepfind/Cargo.toml` `[dependencies]` add `df-content = { workspace = true }` (the CLI now touches content paths indirectly via build_content_index — actually only needs df-index; skip if unused. Only add if a compile needs it.).
- [ ] **Step 2:** In `deepfind/src/main.rs` extend the `Index` subcommand:
```rust
    Index {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        #[arg(long)]
        force: bool,
        #[arg(long = "skip", value_name = "NAME")]
        skip: Vec<String>,
        /// Max file size (bytes) to index content of (default 1MB).
        #[arg(long, default_value_t = 1024 * 1024)]
        max_file_size: u64,
        /// Build filename index only (skip content).
        #[arg(long)]
        no_content: bool,
        /// Don't cross mount/filesystem boundaries.
        #[arg(long)]
        one_file_system: bool,
    },
```
And the match arm + `cmd_index` rewrite to build content by default:
```rust
        Cmd::Index { root, force, skip, max_file_size, no_content, one_file_system } =>
            cmd_index(&root, force, skip, max_file_size, no_content, one_file_system),
```
```rust
fn cmd_index(root: &Path, force: bool, mut skip: Vec<String>, max_file_size: u64, no_content: bool, one_file_system: bool) {
    let db = default_db();
    if !force {
        if let Some(age) = index_build_age(&db) {
            if age < FRESH_THRESHOLD_SECS {
                println!("index is fresh (built {age}s ago), skipping. Use --force to rebuild.");
                return;
            }
        }
    }
    if let Ok(v) = std::env::var("DEEPFIND_SKIP") {
        for s in v.split(':') {
            let t = s.trim();
            if !t.is_empty() { skip.push(t.to_string()); }
        }
    }
    if no_content {
        match df_index::build_index_with(root, &db, &skip) {
            Ok(n) => println!("indexed {n} entries (filename only) -> {}", db.display()),
            Err(e) => { eprintln!("index failed: {e}"); std::process::exit(1); }
        }
        return;
    }
    let content_dir = db.parent().unwrap().join("content");
    let opts = df_index::ContentBuildOptions { max_file_size, extra_skip: skip, one_file_system };
    match df_index::build_content_index(root, &db, &content_dir, &opts) {
        Ok(r) => {
            println!("indexed {} entries ({} content docs, {} shards) -> {}",
                r.filename_docs, r.content_docs, r.shards, db.display());
            if r.denied > 0 {
                eprintln!("warning: {} entries skipped (permission denied). Grant Full Disk Access in System Settings.", r.denied);
            }
            if r.content_skipped_binary + r.content_skipped_large > 0 {
                eprintln!("note: {} files content-skipped (binary), {} (oversized).",
                    r.content_skipped_binary, r.content_skipped_large);
            }
        }
        Err(e) => { eprintln!("index failed: {e}"); std::process::exit(1); }
    }
}
```
- [ ] **Step 3:** `cargo build 2>&1 | tail -3` — clean. clippy/fmt. `cargo test 2>&1 | grep -E FAILED` — no failures.
- [ ] **Step 4:** Commit:
```bash
git add crates/deepfind/Cargo.toml crates/deepfind/src/main.rs
git commit -m "feat(cli): index builds content by default (--max-file-size/--no-content/--one-file-system)"
```

---

## Task 7: M4 wrap

- [ ] **Step 1:** `cargo test 2>&1 | tail -5` (all green), `cargo clippy --all-targets -- -D warnings 2>&1 | tail -3` (clean), `cargo fmt --check`.
- [ ] **Step 2:** Commit any sweep:
```bash
git add -A && git commit -m "chore: M4 fmt/clippy sweep" --allow-empty
```

---

## Self-review

**Spec coverage (M4, spec §9):**
- Streaming bounded pipeline (lolcate pattern) → Task 4. ✓
- Text-gate (NUL/TrigramMax/size cap) → Task 2. ✓
- Dual builders (filename + content) + shard flush @ ~128MB → Task 4. ✓
- MANIFEST → Task 3. ✓
- `--one-file-system` → Task 4 (WalkBuilder::same_file_system) + Task 6. ✓
- FDA denied tally → Task 4. ✓
- CLI flags → Task 6. ✓

**Deferred (M5–M7):** daemon ShardSet + combined query, `--direct` content grep, madvise/bigram/RLIMIT_NOFILE/1-char cap. RLIMIT_NOFILE explicitly deferred (uses `ignore` walker's own FD management; revisit in M7 if a deep-tree build hits EMFILE).

**Risks flagged for the implementer:**
- The consumer thread returns `crate::Result`; ensure `IndexError` has `From<io::Error>` or convert explicitly (Task 4 fixup).
- `atomic_write_public` return type must match both callers (`crate::Result`).
- Channel `drop(tx)` after `run()` is what finalizes the consumer — verify the consumer's `rx.recv()` loop ends (returns Err) so the last partial shard + filename DB get written.
- The integration test sets `max_file_size: 10` to force the oversized path — keep that or the test's intent shifts.

---

## Execution handoff

Plan saved to `docs/superpowers/plans/2026-06-23-v2-content-index-m4.md`. Execute via subagent-driven-development (per the Phase 1 pattern): one implementer per task group, spec + code-quality review each, final holistic review. M5–M7 planned after M4's streaming API is concrete.
