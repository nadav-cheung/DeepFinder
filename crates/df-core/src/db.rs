// SPDX-License-Identifier: MIT
//! Single-file index DB: builder + reader.
//!
//! Step 7 format — zstd-compressed filename blocks + trained dictionary
//! (plocate-style), on top of the Step 6 Robin Hood hash + TurboPFor postings:
//! - Postings: TurboPFor PFor-delta.
//! - Trigram lookup: Robin Hood open-addressed hash, lazy pread decode.
//! - Filenames: grouped into blocks of 256 paths, each zstd-compressed with a
//!   dictionary trained on the path corpus (stored once in the DOCS section).
//!
//! Layout (all integers little-endian):
//! ```text
//! HEADER (64 B): magic[4] | version:u32 | num_docs:u32 | build_time:u64
//!                docs_off:u64 | meta_off:u64 | dirmtime_off:u64(reserved)
//!                try_off:u64 | post_off:u64 | slots_log2:u32
//! DOCS    : dict_len:u32 | dict[dict_len]
//!           num_blocks:u32 | num_blocks × (block_off:u64 | clen:u32 | count:u32)
//!           blocks × zstd(blob)
//! META    : num_docs × [is_dir:u8 | size:i64 | mtime:i64]  (17 B each, docid order)
//! HASH    : slots × [key:u32 | count:u32 | post_off:u64 | enc_len:u32]  (20 B)
//!           empty slot: key = 0xFFFFFFFF
//! POSTINGS: concatenated TurboPFor blobs
//! ```
//!
//! `build_time` (index-build epoch, REVIEW §6.2 staleness) and `dirmtime_off`
//! (reserved hook for future incremental readdir reuse, plocate updatedb.cpp
//! pattern) are v2 header additions; `dirmtime_off` is 0 until that table exists.

use std::collections::BTreeMap;
use std::io::{Read, Write};

use crate::error::CoreError;
use crate::meta::LiteMeta;
use crate::{trigram::trigrams, turbopfor, DbSource, Result};

const MAGIC: &[u8; 4] = b"DFDB";
const VERSION: u32 = 2;
const HEADER_LEN: usize = 64;
const EMPTY_KEY: u32 = 0xFFFF_FFFF;
const SLOT_LEN: usize = 20;
/// Per-doc META record: is_dir:u8 | size:i64 | mtime:i64.
const META_REC_LEN: usize = 17;

const BLOCK_PATHS: usize = 256;
const ZSTD_LEVEL: i32 = 3;
const MIN_DICT_CORPUS: usize = 8192;
const DICT_SIZE: usize = 112_640;

fn le_u32(buf: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(buf[at..at + 4].try_into().unwrap())
}
fn le_u64(buf: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(buf[at..at + 8].try_into().unwrap())
}

/// Avalanche integer hash for the Robin Hood table (splitmix32-style).
fn hash(x: u32) -> u32 {
    let mut z = x.wrapping_add(0x9E37_79B9);
    z = (z ^ (z >> 16)).wrapping_mul(0x85eb_ca6b);
    z = (z ^ (z >> 13)).wrapping_mul(0xc2b2_ae35);
    z ^ (z >> 16)
}

fn zstd_encode(data: &[u8], dict: &[u8]) -> Vec<u8> {
    if dict.is_empty() {
        zstd::encode_all(data, ZSTD_LEVEL).unwrap_or_default()
    } else {
        match zstd::Encoder::with_dictionary(Vec::new(), ZSTD_LEVEL, dict) {
            Ok(mut enc) => {
                let _ = enc.write_all(data);
                enc.finish().unwrap_or_default()
            }
            Err(_) => zstd::encode_all(data, ZSTD_LEVEL).unwrap_or_default(),
        }
    }
}

fn zstd_decode(comp: &[u8], dict: &[u8]) -> Result<Vec<u8>> {
    if dict.is_empty() {
        return zstd::decode_all(comp).map_err(|e| CoreError::Codec(format!("zstd decode: {e}")));
    }
    let mut dec = zstd::Decoder::with_dictionary(comp, dict)
        .map_err(|e| CoreError::Codec(format!("zstd decoder: {e}")))?;
    let mut out = Vec::new();
    dec.read_to_end(&mut out)
        .map_err(|e| CoreError::Codec(format!("zstd read: {e}")))?;
    Ok(out)
}

/// Train a dictionary on the path corpus. Returns empty when the corpus is too
/// small to train (blocks then use plain zstd).
fn train_dict(paths: &[String]) -> Vec<u8> {
    let total: usize = paths.iter().map(|p| p.len() + 4).sum();
    if total < MIN_DICT_CORPUS {
        return Vec::new();
    }
    let sizes: Vec<usize> = paths.iter().map(|p| p.len()).collect();
    let mut buf = Vec::with_capacity(total);
    for p in paths {
        buf.extend_from_slice(p.as_bytes());
    }
    zstd::dict::from_continuous(&buf[..], &sizes, DICT_SIZE).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

pub struct DbBuilder {
    paths: Vec<String>,
    /// Per-doc (is_dir, size, mtime), parallel to `paths`.
    meta: Vec<(u8, i64, i64)>,
    try_map: BTreeMap<u32, Vec<u32>>,
    build_time: u64,
}

impl DbBuilder {
    pub fn new() -> Self {
        Self {
            paths: Vec::new(),
            meta: Vec::new(),
            try_map: BTreeMap::new(),
            build_time: 0,
        }
    }

    pub fn insert(&mut self, path: &str) -> u32 {
        self.insert_with(path, false, 0, 0)
    }

    /// Insert a path with its per-file metadata (`is_dir`, `size` bytes,
    /// `mtime` unix seconds). df-core stays I/O-free: callers (df-index) gather
    /// the metadata; the builder only stores what it is given.
    pub fn insert_with(&mut self, path: &str, is_dir: bool, size: i64, mtime: i64) -> u32 {
        let id = self.paths.len() as u32;
        self.paths.push(path.to_string());
        self.meta.push((is_dir.into(), size, mtime));
        let lower = path.to_lowercase();
        for t in trigrams(lower.as_bytes()) {
            let v = self.try_map.entry(t).or_default();
            if v.last() != Some(&id) {
                v.push(id);
            }
        }
        id
    }

    /// Stamp the index build time (unix seconds). Used for staleness checks
    /// (REVIEW §6.2); df-index sets this from the system clock at build.
    pub fn set_build_time(&mut self, secs: u64) {
        self.build_time = secs;
    }

    pub fn doc_count(&self) -> u32 {
        self.paths.len() as u32
    }

    pub fn finish(self) -> Vec<u8> {
        let num_docs = self.paths.len() as u32;
        let docs_off = HEADER_LEN as u64;

        // --- DOCS section: dict + block index + compressed blocks ---
        let dict = train_dict(&self.paths);
        let num_blocks = self.paths.len().div_ceil(BLOCK_PATHS);
        let front_len = 4 + dict.len() + 4 + num_blocks * 16;
        let blocks_base = docs_off + front_len as u64;

        let mut blocks_bytes = Vec::new();
        let mut index: Vec<(u64, u32, u32)> = Vec::with_capacity(num_blocks);
        for chunk in self.paths.chunks(BLOCK_PATHS) {
            let mut blk = Vec::new();
            for p in chunk {
                let b = p.as_bytes();
                blk.extend_from_slice(&(b.len() as u32).to_le_bytes());
                blk.extend_from_slice(b);
            }
            let comp = zstd_encode(&blk, &dict);
            let off = blocks_base + blocks_bytes.len() as u64;
            index.push((off, comp.len() as u32, chunk.len() as u32));
            blocks_bytes.extend_from_slice(&comp);
        }

        let mut docs = Vec::with_capacity(front_len + blocks_bytes.len());
        docs.extend_from_slice(&(dict.len() as u32).to_le_bytes());
        docs.extend_from_slice(&dict);
        docs.extend_from_slice(&(num_blocks as u32).to_le_bytes());
        for (off, clen, count) in &index {
            docs.extend_from_slice(&off.to_le_bytes());
            docs.extend_from_slice(&clen.to_le_bytes());
            docs.extend_from_slice(&count.to_le_bytes());
        }
        docs.extend_from_slice(&blocks_bytes);

        // --- META section: num_docs × 17 B (is_dir | size | mtime), docid order ---
        let meta_off = docs_off + docs.len() as u64;
        let mut meta_sec = Vec::with_capacity(self.paths.len() * META_REC_LEN);
        for &(is_dir, size, mtime) in &self.meta {
            meta_sec.push(is_dir);
            meta_sec.extend_from_slice(&size.to_le_bytes());
            meta_sec.extend_from_slice(&mtime.to_le_bytes());
        }

        let try_off = meta_off + meta_sec.len() as u64;

        // --- HASH table + POSTINGS ---
        let n_entries = self.try_map.len() as u64;
        let slots = if n_entries == 0 {
            0
        } else {
            (n_entries * 2).next_power_of_two().max(1)
        };
        let table_bytes = slots as usize * SLOT_LEN;
        let post_off = try_off + table_bytes as u64;

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
            let abs_off = post_off + post_sec.len() as u64;
            entries.push((*key, post.len() as u32, abs_off, enc.len() as u32));
            post_sec.extend_from_slice(&enc);
        }
        let table = build_robin_hood(&entries, slots);
        let slots_log2: u32 = if slots == 0 {
            0
        } else {
            slots.trailing_zeros()
        };

        let mut out = Vec::with_capacity(
            HEADER_LEN + docs.len() + meta_sec.len() + table.len() + post_sec.len(),
        );
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&num_docs.to_le_bytes());
        out.extend_from_slice(&self.build_time.to_le_bytes());
        out.extend_from_slice(&docs_off.to_le_bytes());
        out.extend_from_slice(&meta_off.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes()); // dirmtime_off: reserved hook (absent)
        out.extend_from_slice(&try_off.to_le_bytes());
        out.extend_from_slice(&post_off.to_le_bytes());
        out.extend_from_slice(&slots_log2.to_le_bytes());
        debug_assert_eq!(out.len(), HEADER_LEN);
        out.extend_from_slice(&docs);
        out.extend_from_slice(&meta_sec);
        out.extend_from_slice(&table);
        out.extend_from_slice(&post_sec);
        out
    }
}

impl Default for DbBuilder {
    fn default() -> Self {
        Self::new()
    }
}

fn write_slot(table: &mut [u8], idx: usize, key: u32, count: u32, off: u64, len: u32) {
    let b = idx * SLOT_LEN;
    table[b..b + 4].copy_from_slice(&key.to_le_bytes());
    table[b + 4..b + 8].copy_from_slice(&count.to_le_bytes());
    table[b + 8..b + 16].copy_from_slice(&off.to_le_bytes());
    table[b + 16..b + 20].copy_from_slice(&len.to_le_bytes());
}

fn build_robin_hood(entries: &[(u32, u32, u64, u32)], slots: u64) -> Vec<u8> {
    if slots == 0 {
        return Vec::new();
    }
    let slots = slots as usize;
    let mask = slots - 1;
    let mut table = vec![0u8; slots * SLOT_LEN];
    for i in 0..slots {
        write_slot(&mut table, i, EMPTY_KEY, 0, 0, 0);
    }
    for &(key, count, off, len) in entries {
        let mut idx = (hash(key) as usize) & mask;
        let (mut e_key, mut e_count, mut e_off, mut e_len) = (key, count, off, len);
        let mut e_probe = 0usize;
        loop {
            let slot_key = le_u32(&table, idx * SLOT_LEN);
            if slot_key == EMPTY_KEY {
                write_slot(&mut table, idx, e_key, e_count, e_off, e_len);
                break;
            }
            let ideal = (hash(slot_key) as usize) & mask;
            let their_probe = ((idx + slots) - ideal) & mask;
            if e_probe > their_probe {
                let (r_key, r_count, r_off, r_len) = (
                    slot_key,
                    le_u32(&table, idx * SLOT_LEN + 4),
                    le_u64(&table, idx * SLOT_LEN + 8),
                    le_u32(&table, idx * SLOT_LEN + 16),
                );
                write_slot(&mut table, idx, e_key, e_count, e_off, e_len);
                e_key = r_key;
                e_count = r_count;
                e_off = r_off;
                e_len = r_len;
                e_probe = their_probe;
            }
            idx = (idx + 1) & mask;
            e_probe += 1;
        }
    }
    table
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

pub struct DbReader<S> {
    src: S,
    num_docs: u32,
    build_time: u64,
    meta_off: u64,
    try_off: u64,
    slots: u64,
    mask: u64,
    dict: Vec<u8>,
    blocks: Vec<(u64, u32, u32)>, // (abs_off, clen, count)
    block_start: Vec<u32>,        // first docid of each block
}

impl<S: DbSource> DbReader<S> {
    pub fn open(src: S) -> Result<Self> {
        let hdr = src.read_at(0, HEADER_LEN)?;
        if hdr.len() < HEADER_LEN || &hdr[0..4] != MAGIC {
            return Err(CoreError::DbFormat("bad magic / short header".into()));
        }
        let version = le_u32(&hdr, 4);
        if version != VERSION {
            return Err(CoreError::DbFormat(format!(
                "unsupported version {version}"
            )));
        }
        let num_docs = le_u32(&hdr, 8);
        let build_time = le_u64(&hdr, 12);
        let docs_off = le_u64(&hdr, 20);
        let meta_off = le_u64(&hdr, 28);
        // dirmtime_off at 36 is a reserved hook (unused until incremental lands).
        let try_off = le_u64(&hdr, 44);
        let slots_log2 = le_u32(&hdr, 60);
        let slots: u64 = if slots_log2 == 0 {
            0
        } else {
            1u64 << slots_log2
        };

        // DOCS front matter: dict + block index.
        let dict_len = le_u32(&src.read_at(docs_off, 4)?, 0);
        let dict = src.read_at(docs_off + 4, dict_len as usize)?;
        let idx_base = docs_off + 4 + dict_len as u64;
        let num_blocks = le_u32(&src.read_at(idx_base, 4)?, 0) as usize;
        let idx_bytes = src.read_at(idx_base + 4, num_blocks * 16)?;
        let mut blocks = Vec::with_capacity(num_blocks);
        let mut block_start = Vec::with_capacity(num_blocks);
        let mut start = 0u32;
        for i in 0..num_blocks {
            let b = i * 16;
            let off = le_u64(&idx_bytes, b);
            let clen = le_u32(&idx_bytes, b + 8);
            let count = le_u32(&idx_bytes, b + 12);
            block_start.push(start);
            blocks.push((off, clen, count));
            start += count;
        }

        Ok(Self {
            src,
            num_docs,
            build_time,
            meta_off,
            try_off,
            slots,
            mask: if slots == 0 { 0 } else { slots - 1 },
            dict,
            blocks,
            block_start,
        })
    }

    pub fn num_docs(&self) -> u32 {
        self.num_docs
    }

    /// Index build time (unix seconds), or 0 if unset. For staleness checks.
    pub fn build_time(&self) -> u64 {
        self.build_time
    }

    /// Fetch per-file metadata for `docid` (one 17 B pread).
    pub fn doc_meta(&self, docid: u32) -> Result<LiteMeta> {
        if docid >= self.num_docs {
            return Err(CoreError::Query(format!("docid {docid} out of range")));
        }
        let off = self.meta_off + docid as u64 * META_REC_LEN as u64;
        let rec = self.src.read_at(off, META_REC_LEN)?;
        Ok(LiteMeta {
            is_dir: rec[0] != 0,
            size: i64::from_le_bytes(rec[1..9].try_into().unwrap()),
            mtime: i64::from_le_bytes(rec[9..17].try_into().unwrap()),
        })
    }

    /// Fetch the original-case path for `docid` (decompresses its filename block).
    pub fn doc_path(&self, docid: u32) -> Result<String> {
        if self.block_start.is_empty() {
            return Err(CoreError::Query("no docs indexed".into()));
        }
        let i = self.block_start.partition_point(|&s| s <= docid);
        let i = if i == 0 { 0 } else { i - 1 };
        let (off, clen, count) = self.blocks[i];
        let local = docid.saturating_sub(self.block_start[i]);
        if local >= count {
            return Err(CoreError::Query(format!("docid {docid} out of range")));
        }
        let comp = self.src.read_at(off, clen as usize)?;
        let block = zstd_decode(&comp, &self.dict)?;
        let mut p = 0usize;
        for j in 0..=local as usize {
            if p + 4 > block.len() {
                return Err(CoreError::DbFormat("truncated filename block".into()));
            }
            let plen = le_u32(&block, p) as usize;
            p += 4;
            if p + plen > block.len() {
                return Err(CoreError::DbFormat("path overruns filename block".into()));
            }
            if j == local as usize {
                return String::from_utf8(block[p..p + plen].to_vec())
                    .map_err(|e| CoreError::DbFormat(format!("non-utf8 path: {e}")));
            }
            p += plen;
        }
        Err(CoreError::DbFormat("doc not found in block".into()))
    }

    /// Robin Hood lookup of `trig`; on hit, pread + TurboPFor-decode the posting.
    pub fn posting(&self, trig: u32) -> Result<Option<Vec<u32>>> {
        if self.slots == 0 {
            return Ok(None);
        }
        let mut idx = (hash(trig) as u64) & self.mask;
        let mut probe = 0u64;
        loop {
            let slot_off = self.try_off + idx * SLOT_LEN as u64;
            let slot = self.src.read_at(slot_off, SLOT_LEN)?;
            let key = le_u32(&slot, 0);
            if key == EMPTY_KEY {
                return Ok(None);
            }
            let ideal = (hash(key) as u64) & self.mask;
            let their_probe = ((idx + self.slots) - ideal) & self.mask;
            if probe > their_probe {
                return Ok(None);
            }
            if key == trig {
                let count = le_u32(&slot, 4);
                let off = le_u64(&slot, 8);
                let len = le_u32(&slot, 16) as usize;
                let enc = self.src.read_at(off, len)?;
                let deltas = turbopfor::decode(&enc, count as usize);
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
