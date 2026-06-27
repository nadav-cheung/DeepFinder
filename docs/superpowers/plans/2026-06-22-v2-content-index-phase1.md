# DeepFind v2 Content Index — Phase 1 (M0–M3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the content-shard engine: hand-feed files into a mmap-able `.dfcs` shard, then run content substring queries against a single shard — verified against brute-force grep. No full-disk walker or daemon changes yet.

**Architecture:** A new `df-content` crate holds the shard builder/reader (`ShardBuilder` → `.dfcs` bytes; `ShardReader` parses a borrowed byte slice). `df-core` gains a `CandidateSource` trait so filename and content layers share rarest-trigram→verify candidate generation, and exposes its Robin Hood hash builder for reuse. `df-index` gains a `MmapSource` (memmap2-backed `DbSource`). The shard format is zoekt-style tagged-TOC + 8-byte footer; v2.0 uses the Robin Hood hash for ALL content trigrams (the ASCII direct-array fast-path is deferred to M7 hardening).

**Tech Stack:** Rust (edition 2021, ws), memmap2 (mmap), memchr (substring verify), reuse v1 TurboPFor / Robin Hood / trigrams / boolquery / varint.

**Scope:** Phase 1 = spec milestones M0–M3. Phase 2 (M4 full-disk streaming build, M5 daemon ShardSet + combined results, M6 CLI/--direct, M7 hardening) gets a follow-up plan once the shard API here is concrete.

---

## File structure (Phase 1)

- **Create** `crates/df-content/Cargo.toml` — new crate, deps: df-core, memmap2, memchr.
- **Create** `crates/df-content/src/lib.rs` — re-exports.
- **Create** `crates/df-content/src/shard.rs` — `ShardBuilder`, `ShardReader`, `.dfcs` format (sections + TOC + footer).
- **Create** `crates/df-content/src/fold.rs` — ASCII-fold helper (shared by build + verify).
- **Create** `crates/df-content/tests/shard.rs` — roundtrip + query correctness tests.
- **Create** `crates/df-index/src/mmap_source.rs` — `MmapSource`.
- **Modify** `crates/df-core/src/candidate.rs` (NEW) — `CandidateSource` trait + `candidates()`.
- **Modify** `crates/df-core/src/lib.rs` — export candidate module; make `db::build_robin_hood` pub.
- **Modify** `crates/df-core/src/db.rs` — `impl CandidateSource for DbReader`; refactor `single_docids` to use `candidates()`.
- **Modify** `crates/df-core/src/query.rs` — route single-term path through `candidates()`.
- **Modify** `crates/df-index/src/lib.rs` — `pub mod mmap_source;`.
- **Modify** `Cargo.toml` (workspace) — add `df-content` member + `memmap2`/`memchr` to `[workspace.dependencies]`.

---

## Task 0: M0 — v1 baseline locked

**Files:** none.

- [ ] **Step 1: Confirm v1 suite is green**

Run: `cargo test 2>&1 | tail -5`
Expected: all `test result: ok`, 0 failed (≈59 tests).

- [ ] **Step 2: Confirm fmt + clippy clean**

Run: `cargo fmt --check && cargo clippy --all-targets -- -D warnings 2>&1 | tail -3`
Expected: no output / `Finished` with no errors.

No commit (baseline only).

---

## Task 1: M1 — `CandidateSource` trait + generalize candidate generation

**Files:**
- Create: `crates/df-core/src/candidate.rs`
- Modify: `crates/df-core/src/lib.rs`
- Modify: `crates/df-core/src/db.rs`
- Modify: `crates/df-core/src/query.rs`
- Test: existing `crates/df-core/tests/query.rs` (must still pass)

- [ ] **Step 1: Write the trait + generic helper**

Create `crates/df-core/src/candidate.rs`:

```rust
// SPDX-License-Identifier: MIT
//! Shared rarest-trigram candidate generation. Both the filename layer
//! (`DbReader`) and the content layer (`df_content::ShardReader`) implement
//! [`CandidateSource`], so the same `candidates()` algorithm drives both.

use crate::{trigram::trigrams, Result};

/// A source over which rarest-trigram candidate generation + per-doc verify runs.
pub trait CandidateSource {
    /// Postings (docids) for a trigram key, or `None` if absent.
    fn cs_posting(&self, trig: u32) -> Result<Option<Vec<u32>>>;
    /// True if `docid` matches `needle` (already ASCII-folded lowercase bytes).
    fn cs_verify(&self, docid: u32, needle: &[u8]) -> Result<bool>;
    /// Total docs in this source.
    fn cs_num_docs(&self) -> u32;
}

/// Rarest-trigram candidate generation. Returns verified docids. Queries with no
/// trigram (<3 bytes) fall back to scanning all docs. Capped at `limit`.
pub fn candidates<S: CandidateSource + ?Sized>(
    src: &S,
    folded_query: &[u8],
    limit: Option<u32>,
) -> Result<Vec<u32>> {
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut out = Vec::new();

    if folded_query.len() < 3 {
        for d in 0..src.cs_num_docs() {
            if out.len() >= cap {
                break;
            }
            if src.cs_verify(d, folded_query)? {
                out.push(d);
            }
        }
        return Ok(out);
    }

    let qtris = trigrams(folded_query);
    let mut best: Option<Vec<u32>> = None;
    for t in &qtris {
        match src.cs_posting(*t)? {
            Some(post) => {
                best = Some(match best {
                    None => post,
                    Some(b) if post.len() < b.len() => post,
                    Some(b) => b,
                });
            }
            // A query trigram absent from the source ⇒ no doc can match.
            None => return Ok(Vec::new()),
        }
    }
    let Some(cands) = best else {
        return Ok(Vec::new());
    };

    for d in cands {
        if out.len() >= cap {
            break;
        }
        if src.cs_verify(d, folded_query)? {
            out.push(d);
        }
    }
    Ok(out)
}
```

- [ ] **Step 2: Export the module**

In `crates/df-core/src/lib.rs`, add `pub mod candidate;` to the module list (after `pub mod boolquery;`) and `pub use candidate::{candidates, CandidateSource};` to the re-exports.

- [ ] **Step 3: Implement `CandidateSource` for `DbReader`**

In `crates/df-core/src/db.rs`, add at the end of the file (after the `DbReader` impl block):

```rust
use crate::candidate::CandidateSource;

impl<S: DbSource> CandidateSource for DbReader<S> {
    fn cs_posting(&self, trig: u32) -> Result<Option<Vec<u32>>> {
        self.posting(trig)
    }

    fn cs_verify(&self, docid: u32, needle: &[u8]) -> Result<bool> {
        let p = self.doc_path(docid)?;
        let low = p.to_lowercase();
        Ok(if needle.is_empty() {
            true
        } else {
            low.as_bytes()
                .windows(needle.len())
                .any(|w| w == needle)
        })
    }

    fn cs_num_docs(&self) -> u32 {
        self.num_docs()
    }
}
```

Note: `needle` arrives ASCII-folded; `to_lowercase()` is full-Unicode but ASCII-folded needles still match ASCII paths. (Content layer uses pure ASCII-fold; filename keeps Unicode lowercase — consistent within each layer.)

- [ ] **Step 4: Route `single_docids` through `candidates()`**

In `crates/df-core/src/query.rs`, replace the body of `single_docids`:

```rust
fn single_docids<S: DbSource>(
    db: &DbReader<S>,
    q: &str,
    limit: Option<u32>,
) -> Result<Vec<u32>> {
    let folded = q.to_lowercase();
    crate::candidate::candidates(db, folded.as_bytes(), limit)
}
```

Delete the now-unused `scan_docids` function and the `use crate::{trigram::trigrams, ...}` import if it becomes unused (run clippy to confirm). `query()` / `query_docids()` are unchanged.

- [ ] **Step 5: Run the suite to confirm filename query still passes**

Run: `cargo test -p df-core 2>&1 | tail -5`
Expected: all pass (query.rs, boolean.rs, robin_hood.rs, meta.rs).

- [ ] **Step 6: clippy + fmt**

Run: `cargo clippy -p df-core --all-targets -- -D warnings 2>&1 | tail -3 && cargo fmt`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add crates/df-core/src/candidate.rs crates/df-core/src/lib.rs crates/df-core/src/db.rs crates/df-core/src/query.rs
git commit -m "refactor(core): CandidateSource trait; generalize rarest-trigram candidates"
```

---

## Task 2: M2a — expose Robin Hood hash builder for reuse

**Files:**
- Modify: `crates/df-core/src/db.rs`

- [ ] **Step 1: Make `build_robin_hood` and `write_slot`/`SLOT_LEN` pub**

In `crates/df-core/src/db.rs`:
- Change `fn build_robin_hood(` → `pub fn build_robin_hood(`.
- Change `const SLOT_LEN: usize = 20;` → `pub const SLOT_LEN: usize = 20;`.
- Change `const EMPTY_KEY: u32 = 0xFFFF_FFFF;` → `pub const EMPTY_KEY: u32 = 0xFFFF_FFFF;`.

- [ ] **Step 2: Run suite**

Run: `cargo test -p df-core 2>&1 | tail -3`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add crates/df-core/src/db.rs
git commit -m "refactor(core): expose build_robin_hood + SLOT_LEN/EMPTY_KEY for content reuse"
```

---

## Task 3: M2b — `df-content` crate scaffold + workspace deps

**Files:**
- Modify: `Cargo.toml` (workspace root)
- Create: `crates/df-content/Cargo.toml`
- Create: `crates/df-content/src/lib.rs`

- [ ] **Step 1: Add workspace members + deps**

In `Cargo.toml` root, add `"crates/df-content",` to `members`, and to `[workspace.dependencies]` add:

```toml
df-content = { path = "crates/df-content" }
memmap2 = "0.9"
memchr = "2"
```

- [ ] **Step 2: Create the crate manifest**

`crates/df-content/Cargo.toml`:

```toml
[package]
name = "df-content"
version.workspace = true
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
df-core = { workspace = true }
memchr = { workspace = true }

[dev-dependencies]
tempfile = { workspace = true }
```

(memmap2 is added to df-index in Task 7; df-content itself stays pure-ish over borrowed bytes — the daemon owns the mmap.)

- [ ] **Step 3: Create lib.rs stub**

`crates/df-content/src/lib.rs`:

```rust
// SPDX-License-Identifier: MIT
//! df-content — content substring index: mmap-able `.dfcs` shard builder/reader
//! + substring verify. Pure over borrowed byte slices (the daemon owns the mmap
//! and lends `&[u8]`). No filesystem I/O of its own.

pub mod fold;
pub mod shard;

pub use shard::{ShardBuilder, ShardReader};
```

- [ ] **Step 4: Create the ASCII-fold helper**

`crates/df-content/src/fold.rs`:

```rust
// SPDX-License-Identifier: MIT
//! ASCII lowercase fold for byte slices (A-Z → a-z). Used by both the shard
//! builder (over content bytes) and the query verifier, so trigram keys and
//! substring matches agree byte-for-byte. Non-ASCII bytes are unchanged (CJK has
//! no case; matches the byte-trigram model).

#[inline]
pub fn fold_in_place(bytes: &mut [u8]) {
    for b in bytes {
        if b.is_ascii_uppercase() {
            *b |= 0x20;
        }
    }
}

/// Owned, folded copy.
pub fn fold(bytes: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    fold_in_place(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_ascii_upper() {
        assert_eq!(fold(b"AbC \xC3\xA9"), b"abc \xC3\xA9");
    }
}
```

- [ ] **Step 5: Build the crate**

Run: `cargo build -p df-content 2>&1 | tail -3`
Expected: compiles.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock crates/df-content
git commit -m "feat(content): scaffold df-content crate + ASCII-fold helper"
```

---

## Task 4: M2c — `ShardBuilder` (write `.dfcs` sections + TOC + footer)

**Files:**
- Create: `crates/df-content/src/shard.rs` (builder half)

- [ ] **Step 1: Write the builder**

Create `crates/df-content/src/shard.rs` with the builder (reader added in Task 5):

```rust
// SPDX-License-Identifier: MIT
//! `.dfcs` content shard — builder + reader.
//!
//! Layout (little-endian):
//! ```text
//! [body sections, back-to-back]
//! TOC:    u32 section_count
//!         repeat section_count × (varint tag_len, tag bytes, u8 kind=0,
//!                                 u32 off, u32 sz)
//! FOOTER: u32 toc_off, u32 toc_sz   (8 bytes, at file end)
//! ```
//! v2.0 sections (all `kind=0` simple):
//! - "metaData":      version:u16, build_time:u64, shard_id:u32, base_docid:u32, num_docs:u32, slots_log2:u32
//! - "fileNames":     num_docs × (u32 len + bytes)
//! - "fileMeta":      num_docs × (is_dir:u8, size:i64, mtime:i64)   [17 B, == df_core::LiteMeta]
//! - "contentOffsets":num_docs × (u64 abs_off into contentCorpus, u32 len)  [12 B]
//! - "contentCorpus": raw size-capped bytes
//! - "ctHash":        Robin Hood table (slots × 20 B)
//! - "ctPostings":    TurboPFor posting blobs

use std::collections::BTreeMap;

use df_core::db::{build_robin_hood, EMPTY_KEY, SLOT_LEN};
use df_core::{turbopfor, trigram::trigrams, LiteMeta};

use crate::fold::fold_in_place;

const SHARD_VERSION: u16 = 1;

fn le_u32(v: u32) -> [u8; 4] { v.to_le_bytes() }
fn le_u64(v: u64) -> [u8; 8] { v.to_le_bytes() }
fn le_i64(v: i64) -> [u8; 8] { v.to_le_bytes() }
fn le_u16(v: u16) -> [u8; 2] { v.to_le_bytes() }

/// Builds a `.dfcs` shard from hand-fed files.
pub struct ShardBuilder {
    shard_id: u32,
    base_docid: u32,
    paths: Vec<String>,
    meta: Vec<(u8, i64, i64)>,
    corpus: Vec<u8>,
    offsets: Vec<(u64, u32)>,
    try_map: BTreeMap<u32, Vec<u32>>,
}

impl ShardBuilder {
    pub fn new(shard_id: u32, base_docid: u32) -> Self {
        Self {
            shard_id,
            base_docid,
            paths: Vec::new(),
            meta: Vec::new(),
            corpus: Vec::new(),
            offsets: Vec::new(),
            try_map: BTreeMap::new(),
        }
    }

    /// Add a file: path + metadata + size-capped content bytes. Extracts byte
    /// trigrams over ASCII-folded content into the per-shard inverted map.
    pub fn add_file(&mut self, path: &str, is_dir: bool, size: i64, mtime: i64, content: &[u8]) {
        let docid = self.paths.len() as u32;
        self.paths.push(path.to_string());
        self.meta.push((u8::from(is_dir), size, mtime));
        let off = self.corpus.len() as u64;
        self.corpus.extend_from_slice(content);
        self.offsets.push((off, content.len() as u32));

        let mut folded = content.to_vec();
        fold_in_place(&mut folded);
        for t in trigrams(&folded) {
            let v = self.try_map.entry(t).or_default();
            if v.last() != Some(&docid) {
                v.push(docid);
            }
        }
    }

    pub fn doc_count(&self) -> u32 {
        self.paths.len() as u32
    }

    /// Serialize the shard to bytes (sections + TOC + footer).
    pub fn finish(self, build_time: u64) -> Vec<u8> {
        let num_docs = self.paths.len() as u32;

        // --- fileNames ---
        let mut file_names = Vec::new();
        for p in &self.paths {
            let b = p.as_bytes();
            file_names.extend_from_slice(&le_u32(b.len() as u32));
            file_names.extend_from_slice(b);
        }

        // --- fileMeta ---
        let mut file_meta = Vec::with_capacity(self.meta.len() * 17);
        for &(is_dir, size, mtime) in &self.meta {
            file_meta.push(is_dir);
            file_meta.extend_from_slice(&le_i64(size));
            file_meta.extend_from_slice(&le_i64(mtime));
        }

        // --- contentOffsets ---
        let mut content_offsets = Vec::with_capacity(self.offsets.len() * 12);
        for &(off, len) in &self.offsets {
            content_offsets.extend_from_slice(&le_u64(off));
            content_offsets.extend_from_slice(&le_u32(len));
        }

        // --- content trigram hash + postings (reuse v1 primitives) ---
        let n_entries = self.try_map.len() as u64;
        let slots = if n_entries == 0 {
            0u64
        } else {
            (n_entries * 2).next_power_of_two().max(1)
        };
        let slots_log2: u32 = if slots == 0 { 0 } else { slots.trailing_zeros() };

        let mut post_sec = Vec::new();
        let mut entries: Vec<(u32, u32, u64, u32)> = Vec::with_capacity(n_entries as usize);
        for (key, post) in &self.try_map {
            let mut deltas = Vec::with_capacity(post.len());
            let mut prev = 0u32;
            for &d in post {
                deltas.push(d - prev);
                prev = d;
            }
            let enc = turbopfor::encode(&deltas);
            let abs_off = post_sec.len() as u64;
            entries.push((*key, post.len() as u32, abs_off, enc.len() as u32));
            post_sec.extend_from_slice(&enc);
        }
        let hash_table = build_robin_hood(&entries, slots);

        // --- metaData ---
        let mut meta_data = Vec::with_capacity(30);
        meta_data.extend_from_slice(&le_u16(SHARD_VERSION));
        meta_data.extend_from_slice(&le_u64(build_time));
        meta_data.extend_from_slice(&le_u32(self.shard_id));
        meta_data.extend_from_slice(&le_u32(self.base_docid));
        meta_data.extend_from_slice(&le_u32(num_docs));
        meta_data.extend_from_slice(&le_u32(slots_log2));

        // --- assemble body + record section locations ---
        let sections: [(&str, &[u8]); 7] = [
            ("metaData", &meta_data),
            ("fileNames", &file_names),
            ("fileMeta", &file_meta),
            ("contentOffsets", &content_offsets),
            ("contentCorpus", &self.corpus),
            ("ctHash", &hash_table),
            ("ctPostings", &post_sec),
        ];

        let mut out: Vec<u8> = Vec::new();
        let mut locs: Vec<(&str, u32, u32)> = Vec::with_capacity(sections.len());
        for (tag, bytes) in &sections {
            let off = out.len() as u32;
            out.extend_from_slice(bytes);
            locs.push((tag, off, bytes.len() as u32));
        }

        // --- TOC ---
        let toc_off = out.len() as u32;
        out.extend_from_slice(&le_u32(locs.len() as u32));
        for (tag, off, sz) in &locs {
            encode_tag(&mut out, tag.as_bytes());
            out.push(0); // kind = simple
            out.extend_from_slice(&le_u32(*off));
            out.extend_from_slice(&le_u32(*sz));
        }
        let toc_sz = (out.len() as u32) - toc_off;

        // --- footer (8 bytes at end) ---
        out.extend_from_slice(&le_u32(toc_off));
        out.extend_from_slice(&le_u32(toc_sz));
        out
    }
}

fn encode_tag(out: &mut Vec<u8>, tag: &[u8]) {
    df_core::varint::encode_u32(tag.len() as u32, out);
    out.extend_from_slice(tag);
}

#[allow(dead_code)]
fn _keep_constants_referenced() {
    let _ = (EMPTY_KEY, SLOT_LEN);
    let _ = std::mem::size_of::<LiteMeta>();
}
```

(The `_keep_constants_referenced` stub avoids unused-import warnings for `EMPTY_KEY`/`SLOT_LEN`/`LiteMeta` until the reader in Task 5 uses them. Remove the stub once the reader lands if clippy flags it.)

- [ ] **Step 2: Build**

Run: `cargo build -p df-content 2>&1 | tail -5`
Expected: compiles (no test yet — reader comes next).

- [ ] **Step 3: Commit**

```bash
git add crates/df-content/src/shard.rs
git commit -m "feat(content): ShardBuilder — writes .dfcs sections + TOC + footer"
```

---

## Task 5: M2d — `ShardReader` (parse footer + TOC; section accessors) + roundtrip

**Files:**
- Modify: `crates/df-content/src/shard.rs` (add reader)
- Create: `crates/df-content/tests/shard.rs`

- [ ] **Step 1: Add the reader to `shard.rs`**

Append to `crates/df-content/src/shard.rs`:

```rust
// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

fn rd_u32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn rd_u64(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}
fn rd_u16(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes(b[at..at + 2].try_into().unwrap())
}
fn rd_i64(b: &[u8], at: usize) -> i64 {
    i64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

/// Read-only view over a `.dfcs` byte slice (borrowed; the daemon owns the mmap).
pub struct ShardReader<'a> {
    bytes: &'a [u8],
    num_docs: u32,
    base_docid: u32,
    slots_log2: u32,
    slots: u64,
    mask: u64,
    sect: std::collections::HashMap<&'static str, (u32, u32)>, // tag -> (off, sz)
}

impl<'a> ShardReader<'a> {
    /// Parse a shard from a borrowed byte slice.
    pub fn open(bytes: &'a [u8]) -> df_core::Result<Self> {
        use df_core::error::CoreError;
        if bytes.len() < 8 {
            return Err(CoreError::DbFormat("shard too short".into()));
        }
        let footer = bytes.len() - 8;
        let toc_off = rd_u32(bytes, footer) as usize;
        let toc_sz = rd_u32(bytes, footer + 4) as usize;
        let toc_end = toc_off.checked_add(toc_sz).ok_or_else(|| {
            CoreError::DbFormat("shard TOC overruns file".into())
        })?;
        if toc_end != footer {
            return Err(CoreError::DbFormat("shard TOC/end mismatch".into()));
        }
        let toc = &bytes[toc_off..toc_end];
        let count = rd_u32(toc, 0) as usize;
        let mut p = 4usize;
        let mut sect = std::collections::HashMap::new();
        for _ in 0..count {
            let (tag_len, np) = df_core::varint::decode_u32(toc, &mut p)
                .map(|v| (v as usize, 0))
                .unwrap_or((0, 0));
            // decode_u32 advances p already; recompute tag bytes window:
            let _ = np;
            let tag_bytes = &toc[p..p + tag_len];
            p += tag_len;
            let _kind = toc[p]; p += 1;
            let off = rd_u32(toc, p); p += 4;
            let sz = rd_u32(toc, p); p += 4;
            // tag strings are static literals; intern via leak-free match:
            let tag: &'static str = match std::str::from_utf8(tag_bytes) {
                Ok("metaData") => "metaData",
                Ok("fileNames") => "fileNames",
                Ok("fileMeta") => "fileMeta",
                Ok("contentOffsets") => "contentOffsets",
                Ok("contentCorpus") => "contentCorpus",
                Ok("ctHash") => "ctHash",
                Ok("ctPostings") => "ctPostings",
                _ => continue, // unknown tag → skip (forward-compat)
            };
            sect.insert(tag, (off, sz));
        }

        let md = sect
            .get("metaData")
            .ok_or_else(|| CoreError::DbFormat("missing metaData".into()))?;
        let md = &bytes[md.0 as usize..(md.0 + md.1) as usize];
        let num_docs = rd_u32(md, 2 + 8 + 4 + 4);
        let base_docid = rd_u32(md, 2 + 8 + 4);
        let slots_log2 = rd_u32(md, 2 + 8 + 4 + 4 + 4);
        let slots: u64 = if slots_log2 == 0 { 0 } else { 1u64 << slots_log2 };

        Ok(Self {
            bytes,
            num_docs,
            base_docid,
            slots_log2,
            slots,
            mask: if slots == 0 { 0 } else { slots - 1 },
            sect,
        })
    }

    pub fn num_docs(&self) -> u32 {
        self.num_docs
    }
    pub fn base_docid(&self) -> u32 {
        self.base_docid
    }

    fn section(&self, tag: &'static str) -> df_core::Result<&[u8]> {
        use df_core::error::CoreError;
        let (off, sz) = self
            .sect
            .get(tag)
            .ok_or_else(|| CoreError::DbFormat(format!("missing section {tag}")))?;
        Ok(&self.bytes[*off as usize..(*off as usize + *sz as usize)])
    }

    /// Path for a LOCAL docid (sequential scan of length-prefixed fileNames).
    pub fn path(&self, local_docid: u32) -> df_core::Result<String> {
        use df_core::error::CoreError;
        let fn_ = self.section("fileNames")?;
        let mut p = 0usize;
        for i in 0..=local_docid as usize {
            if p + 4 > fn_.len() {
                return Err(CoreError::DbFormat("fileNames truncated".into()));
            }
            let len = rd_u32(fn_, p) as usize;
            p += 4;
            if p + len > fn_.len() {
                return Err(CoreError::DbFormat("path overruns fileNames".into()));
            }
            if i == local_docid as usize {
                return String::from_utf8(fn_[p..p + len].to_vec())
                    .map_err(|e| CoreError::DbFormat(format!("non-utf8 path: {e}")));
            }
            p += len;
        }
        Err(CoreError::DbFormat("docid not in fileNames".into()))
    }

    /// Per-doc metadata.
    pub fn meta(&self, local_docid: u32) -> df_core::Result<LiteMeta> {
        use df_core::error::CoreError;
        let fm = self.section("fileMeta")?;
        let at = local_docid as usize * 17;
        if at + 17 > fm.len() {
            return Err(CoreError::Query("docid out of range".into()));
        }
        Ok(LiteMeta {
            is_dir: fm[at] != 0,
            size: rd_i64(fm, at + 1),
            mtime: rd_i64(fm, at + 9),
        })
    }

    /// The indexed content bytes for a LOCAL docid (slice of contentCorpus).
    pub fn content(&self, local_docid: u32) -> df_core::Result<&[u8]> {
        use df_core::error::CoreError;
        let co = self.section("contentOffsets")?;
        let at = local_docid as usize * 12;
        if at + 12 > co.len() {
            return Err(CoreError::Query("docid out of range".into()));
        }
        let off = rd_u64(co, at) as usize;
        let len = rd_u32(co, at + 8) as usize;
        let corpus = self.section("contentCorpus")?;
        if off + len > corpus.len() {
            return Err(CoreError::DbFormat("content slice overruns corpus".into()));
        }
        Ok(&corpus[off..off + len])
    }

    /// Robin Hood lookup of a content trigram → local docid posting (decoded).
    pub fn posting(&self, trig: u32) -> df_core::Result<Option<Vec<u32>>> {
        use df_core::error::CoreError;
        if self.slots == 0 {
            return Ok(None);
        }
        let hash = self.section("ctHash")?;
        let postings = self.section("ctPostings")?;
        let mut idx = (df_core::db::hash(trig) as u64) & self.mask;
        let mut probe = 0u64;
        loop {
            let slot_off = idx as usize * SLOT_LEN;
            if slot_off + SLOT_LEN > hash.len() {
                return Err(CoreError::DbFormat("ctHash truncated".into()));
            }
            let key = rd_u32(hash, slot_off);
            if key == EMPTY_KEY {
                return Ok(None);
            }
            let ideal = (df_core::db::hash(key) as u64) & self.mask;
            let their_probe = ((idx + self.slots) - ideal) & self.mask;
            if probe > their_probe {
                return Ok(None);
            }
            if key == trig {
                let count = rd_u32(hash, slot_off + 4);
                let post_off = rd_u64(hash, slot_off + 8) as usize;
                let enc_len = rd_u32(hash, slot_off + 16) as usize;
                let deltas = turbopfor::decode(&postings[post_off..post_off + enc_len], count as usize);
                let mut post = Vec::with_capacity(count as usize);
                let mut prev = 0u32;
                for d in deltas {
                    prev = prev
                        .checked_add(d)
                        .ok_or_else(|| CoreError::Codec("docid overflow".into()))?;
                    post.push(prev);
                }
                return Ok(Some(post));
            }
            idx = (idx + 1) & self.mask;
            probe += 1;
        }
    }
}
```

Also make `df_core::db::hash` and `df_core::db::SLOT_LEN`/`EMPTY_KEY` accessible: `hash` is already `fn hash` (private) in db.rs — change it to `pub fn hash`. Add that to Task 2's exposed items (if not done, do it now: `pub fn hash(...)`).

- [ ] **Step 2: Expose `df_core::db::hash`**

In `crates/df-core/src/db.rs`, change `fn hash(x: u32) -> u32 {` → `pub fn hash(x: u32) -> u32 {`.

- [ ] **Step 3: Remove the `_keep_constants_referenced` stub from Task 4** (the reader now uses `EMPTY_KEY`/`SLOT_LEN`/`LiteMeta`/`build_robin_hood`/`turbopfor`). Delete the stub function and the now-unused import lines if clippy flags any.

- [ ] **Step 4: Write the roundtrip test**

`crates/df-content/tests/shard.rs`:

```rust
// SPDX-License-Identifier: MIT
//! Shard roundtrip: build → open → read paths/meta/content/postings.

use df_content::{ShardBuilder, ShardReader};
use df_core::LiteMeta;

fn sample() -> Vec<u8> {
    let mut b = ShardBuilder::new(0, 1000);
    b.add_file("/src/main.rs", false, 12, 1_700_000_000, b"fn main() { todo() }");
    b.add_file("/src/lib.rs", false, 8, 1_700_000_010, b"pub fn lib() {}");
    b.add_file("/docs/readme.md", false, 5, 1_700_000_020, b"# readme");
    b.finish(1_700_000_030)
}

#[test]
fn open_and_metadata() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.num_docs(), 3);
    assert_eq!(r.base_docid(), 1000);
    assert_eq!(r.path(0).unwrap(), "/src/main.rs");
    let m = r.meta(1).unwrap();
    assert_eq!(m, LiteMeta { is_dir: false, size: 8, mtime: 1_700_000_010 });
}

#[test]
fn content_slice() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.content(0).unwrap(), b"fn main() { todo() }");
    assert_eq!(r.content(2).unwrap(), b"# readme");
}

#[test]
fn posting_roundtrip() {
    let bytes = sample();
    let r = ShardReader::open(&bytes).unwrap();
    // trigram "fn " appears in main.rs (docid 0) and lib.rs (docid 1).
    let key = (b'f' as u32) << 16 | (b'n' as u32) << 8 | b' ' as u32;
    let post = r.posting(key).unwrap().unwrap();
    assert!(post.contains(&0));
    assert!(post.contains(&1));
    assert!(!post.contains(&2));
    // absent trigram
    let zzz = (b'z' as u32) << 16 | (b'z' as u32) << 8 | b'z' as u32;
    assert!(r.posting(zzz).unwrap().is_none());
}
```

- [ ] **Step 5: Run the test**

Run: `cargo test -p df-content 2>&1 | tail -8`
Expected: 3 tests pass.

- [ ] **Step 6: clippy + fmt**

Run: `cargo clippy -p df-content --all-targets -- -D warnings 2>&1 | tail -3 && cargo fmt`

If clippy flags the `decode_u32` double-count in the reader TOC loop (the varint decode advances `p`), fix by replacing that block with:

```rust
let tag_len = df_core::varint::decode_u32(toc, &mut p)
    .ok_or_else(|| CoreError::DbFormat("bad tag varint".into()))? as usize;
let tag_bytes = &toc[p..p + tag_len];
p += tag_len;
```

(Remove the `np`/`tag_len` shadowing noise — the cleaner version above is canonical.)

- [ ] **Step 7: Commit**

```bash
git add crates/df-content/src/shard.rs crates/df-content/tests/shard.rs crates/df-core/src/db.rs
git commit -m "feat(content): ShardReader — parse .dfcs TOC/footer, posting lookup"
```

---

## Task 6: M2e — empty-shard edge case

**Files:**
- Modify: `crates/df-content/tests/shard.rs`

- [ ] **Step 1: Add the empty-shard test**

Append to `crates/df-content/tests/shard.rs`:

```rust
#[test]
fn empty_shard_roundtrips() {
    let bytes = ShardBuilder::new(0, 0).finish(1);
    let r = ShardReader::open(&bytes).unwrap();
    assert_eq!(r.num_docs(), 0);
    let zzz = (b'z' as u32) << 16 | (b'z' as u32) << 8 | b'z' as u32;
    assert!(r.posting(zzz).unwrap().is_none());
}
```

- [ ] **Step 2: Run + clippy**

Run: `cargo test -p df-content 2>&1 | tail -5 && cargo clippy -p df-content --all-targets -- -D warnings 2>&1 | tail -2`
Expected: 4 tests pass, clippy clean.

- [ ] **Step 3: Commit**

```bash
git add crates/df-content/tests/shard.rs
git commit -m "test(content): empty-shard roundtrip"
```

---

## Task 7: M2f — `MmapSource` (memmap2) in df-index

**Files:**
- Modify: `Cargo.toml` (add memmap2 to workspace deps — already added in Task 3)
- Modify: `crates/df-index/Cargo.toml`
- Create: `crates/df-index/src/mmap_source.rs`
- Modify: `crates/df-index/src/lib.rs`
- Create: `crates/df-index/tests/mmap_source.rs`

- [ ] **Step 1: Add memmap2 to df-index**

In `crates/df-index/Cargo.toml` `[dependencies]`, add `memmap2 = { workspace = true }`.

- [ ] **Step 2: Write `MmapSource`**

`crates/df-index/src/mmap_source.rs`:

```rust
// SPDX-License-Identifier-Identifier: MIT
//! mmap-backed [`DbSource`] (MAP_SHARED, read-only). The content daemon holds
//! these for the process lifetime; shards are write-once so there is no
//! SIGBUS-from-write risk.

use std::fs::File;
use std::io;
use std::path::Path;

use df_core::DbSource;

/// Owns the `File` (kept alive) + its read-only mmap.
pub struct MmapSource {
    _file: File,
    mmap: memmap2::Mmap,
}

impl MmapSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        // SAFETY: map after open; the file is treated as immutable for the
        // mapping's lifetime (shards are write-once; rebuilds swap files).
        let mmap = unsafe { memmap2::Mmap::map(&file) }?;
        Ok(Self { _file: file, mmap })
    }

    /// Borrow the underlying bytes (zero-copy).
    pub fn as_slice(&self) -> &[u8] {
        &self.mmap[..]
    }
}

impl DbSource for MmapSource {
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>> {
        let start = usize::try_from(off)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "offset overflow"))?;
        let end = start
            .checked_add(len)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "len overflow"))?;
        if end > self.mmap.len() {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "read past mmap end"));
        }
        Ok(self.mmap[start..end].to_vec())
    }
}
```

- [ ] **Step 3: Export the module**

In `crates/df-index/src/lib.rs`, add `pub mod mmap_source;` and `pub use mmap_source::MmapSource;`.

- [ ] **Step 4: Write the mmap roundtrip test**

`crates/df-index/tests/mmap_source.rs`:

```rust
// SPDX-License-Identifier: MIT
//! MmapSource: write a shard to disk, mmap it, read it back identically.

use df_content::{ShardBuilder, ShardReader};
use df_index::MmapSource;

#[test]
fn mmap_shard_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("shard-00000.dfcs");

    let mut b = ShardBuilder::new(0, 0);
    b.add_file("/a/x.txt", false, 3, 1, b"abc");
    b.add_file("/a/y.txt", false, 3, 2, b"abd");
    let bytes = b.finish(99);
    std::fs::write(&path, &bytes).unwrap();

    let src = MmapSource::open(&path).unwrap();
    assert_eq!(src.as_slice(), &bytes[..]); // mmap sees the exact bytes

    let r = ShardReader::open(src.as_slice()).unwrap();
    assert_eq!(r.num_docs(), 2);
    assert_eq!(r.content(0).unwrap(), b"abc");

    // via DbSource::read_at too
    use df_core::DbSource;
    let head = src.read_at(0, 4).unwrap();
    assert_eq!(head.len(), 4);
}
```

(Note: df-index's dev-dependencies already include df-content indirectly? No — add `df-content = { workspace = true }` to `crates/df-index/Cargo.toml` `[dev-dependencies]` so the test can build a shard. Do that in this step.)

- [ ] **Step 5: Run + clippy**

Run: `cargo test -p df-index --test mmap_source 2>&1 | tail -5 && cargo clippy -p df-index --all-targets -- -D warnings 2>&1 | tail -2`
Expected: pass, clean.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock crates/df-index/Cargo.toml crates/df-index/src/mmap_source.rs crates/df-index/src/lib.rs crates/df-index/tests/mmap_source.rs
git commit -m "feat(index): MmapSource — memmap2-backed DbSource for content shards"
```

---

## Task 8: M3a — content substring verify + `CandidateSource` for `ShardReader`

**Files:**
- Modify: `crates/df-content/src/shard.rs`
- Modify: `crates/df-content/src/lib.rs`
- Modify: `crates/df-content/Cargo.toml` (memchr already a dep)

- [ ] **Step 1: Implement `CandidateSource` for `ShardReader`**

Append to `crates/df-content/src/shard.rs`:

```rust
use df_core::candidate::CandidateSource;

impl<'a> CandidateSource for ShardReader<'a> {
    fn cs_posting(&self, trig: u32) -> df_core::Result<Option<Vec<u32>>> {
        self.posting(trig)
    }

    fn cs_verify(&self, local_docid: u32, needle: &[u8]) -> df_core::Result<bool> {
        if needle.is_empty() {
            return Ok(true);
        }
        let content = self.content(local_docid)?;
        // ASCII-fold the content bytes, then memchr the first needle byte and
        // compare. (Content is usually ASCII-folded already at build time only
        // for trigram keys; verify folds the slice to be safe.)
        let folded = crate::fold::fold(content);
        Ok(memchr::memmem::find(&folded, needle).is_some())
    }

    fn cs_num_docs(&self) -> u32 {
        self.num_docs()
    }
}
```

- [ ] **Step 2: Build**

Run: `cargo build -p df-content 2>&1 | tail -3`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add crates/df-content/src/shard.rs
git commit -m "feat(content): CandidateSource for ShardReader — memchr substring verify"
```

---

## Task 9: M3b — single-shard content query (correctness vs brute-force grep)

**Files:**
- Create: `crates/df-content/tests/query.rs`

- [ ] **Step 1: Write the query-correctness test**

`crates/df-content/tests/query.rs`:

```rust
// SPDX-License-Identifier: MIT
//! Single-shard content query: candidates() over a ShardReader must match a
//! brute-force ASCII-folded substring scan of every file.

use df_content::{ShardBuilder, ShardReader};
use df_core::candidate::{candidates, CandidateSource};
use df_core::CandidateSource as _;

fn brute_force(paths: &[(String, &[u8])], needle_folded: &[u8]) -> Vec<u32> {
    paths
        .iter()
        .enumerate()
        .filter_map(|(i, (_, c))| {
            let f = df_content::fold::fold(c);
            (memchr::memmem::find(&f, needle_folded).is_some()).then_some(i as u32)
        })
        .collect()
}

#[test]
fn content_query_matches_grep() {
    let files: Vec<(String, Vec<u8>)> = vec![
        ("/a/main.rs".into(), b"fn main() { return 0; }".to_vec()),
        ("/a/lib.rs".into(), b"pub fn lib(x: u32) -> u32 { x }".to_vec()),
        ("/b/notes.md".into(), b"# Notes\nmain idea here\n".to_vec()),
        ("/b/data.csv".into(), b"name,value\nmain,42\n".to_vec()),
        ("/c/empty.txt".into(), b"".to_vec()),
    ];

    let mut b = ShardBuilder::new(0, 0);
    for (p, c) in &files {
        b.add_file(p, false, c.len() as i64, 1, c);
    }
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();

    let refs: Vec<(String, &[u8])> = files
        .iter()
        .map(|(p, c)| (p.clone(), c.as_slice()))
        .collect();

    for q in ["main", "fn ", "u32", "Notes", "zzz", "MA"] {
        let folded = df_content::fold::fold(q.as_bytes());
        let got = candidates(&r, &folded, None).unwrap();
        let want = brute_force(&refs, &folded);
        let mut got = got;
        got.sort();
        assert_eq!(got, want, "query {q:?} mismatch");
    }
}

#[test]
fn content_query_respects_limit() {
    let mut b = ShardBuilder::new(0, 0);
    for i in 0..20u32 {
        b.add_file(&format!("/x/f{i}.txt"), false, 3, 1, b"abc");
    }
    let bytes = b.finish(1);
    let r = ShardReader::open(&bytes).unwrap();
    let folded = df_content::fold::fold(b"abc");
    assert_eq!(candidates(&r, &folded, Some(5)).unwrap().len(), 5);
    assert_eq!(candidates(&r, &folded, Some(0)).unwrap().len(), 0);
}
```

- [ ] **Step 2: Make `fold` module accessible from tests**

`crate::fold` is `pub mod fold` in lib.rs (done in Task 3), so `df_content::fold::fold` is reachable. The test also uses `CandidateSource` trait import for the `_` — remove the unused `use df_core::CandidateSource as _;` line if clippy flags it (candidates is called as a free fn). Keep only `use df_core::candidate::{candidates, CandidateSource};`.

- [ ] **Step 3: Run the test**

Run: `cargo test -p df-content --test query 2>&1 | tail -8`
Expected: 2 tests pass (the property test asserts every query matches brute force).

- [ ] **Step 4: clippy + fmt**

Run: `cargo clippy -p df-content --all-targets -- -D warnings 2>&1 | tail -3 && cargo fmt`

- [ ] **Step 5: Commit**

```bash
git add crates/df-content/tests/query.rs
git commit -m "test(content): single-shard query correctness vs brute-force grep"
```

---

## Task 10: Phase 1 wrap

**Files:** none.

- [ ] **Step 1: Full workspace test + clippy + fmt**

Run:
```bash
cargo test 2>&1 | grep -E "FAILED|error" | head
cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error|^warning" | head
cargo fmt --check
```
Expected: no failures, no clippy errors, fmt clean.

- [ ] **Step 2: Commit any fmt fixes**

```bash
git add -A
git commit -m "chore: phase-1 fmt/clippy sweep" --allow-empty
```

---

## Self-review

**Spec coverage (M0–M3):**
- M0 (lock v1) → Task 0. ✓
- M1 (CandidateSource abstraction) → Task 1. ✓
- M2 shard format (tagged-TOC + footer, sections, builder, reader, mmap) → Tasks 2–7. ✓
- M3 single-shard query (rarest-trigram → verify) → Tasks 8–9. ✓

**Deferred to Phase 2 plan (M4–M7):** streaming full-disk build (lolcate channel), ShardSet + daemon combined-query + dedup, CLI flags + `--direct` content grep, hardening (ASCII array, bigram, madvise, 1-char cap). These depend on the shard API finalized here.

**Placeholder scan:** none; every code step has real Rust. The one sketchy spot (Task 5 Step 1 varint decode) has an explicit canonical fix in Step 6.

**Type consistency:** `ShardReader::open(&[u8]) -> df_core::Result<Self>`; `candidates(&r, &folded, limit)`; `CandidateSource` methods `cs_posting`/`cs_verify`/`cs_num_docs` used consistently. `local_docid` vs global docid: Phase 1 is single-shard so local == the only space; `base_docid()` is stored for Phase 2's combined space. `df_core::db::{hash, build_robin_hood, SLOT_LEN, EMPTY_KEY}` all made pub (Tasks 2 + 5 Step 2).

**Known simplifications (acceptable for Phase 1, flagged for Phase 2):**
- Content trigram index uses Robin Hood hash for ALL trigrams; ASCII direct-array deferred to M7.
- `fileNames` is sequential-scan (no offset index) — fine while query resolves few match paths; compound index is a Phase 2/3 tuning item if it shows up in profiles.
- ASCII-fold for content vs Unicode-lowercase for filename: consistent per-layer; cross-layer dedup happens on resolved path strings (Phase 2), so the fold difference does not affect dedup.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-v2-content-index-phase1.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
