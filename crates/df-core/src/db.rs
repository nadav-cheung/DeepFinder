// SPDX-License-Identifier: MIT
//! Single-file index DB: builder + reader.
//!
//! Step 6 format — on-disk Robin Hood hash for trigram→posting, lazy pread
//! decode (low RSS: the reader never loads the whole table or all postings):
//! - Postings: TurboPFor PFor-delta.
//! - Trigram lookup: Robin Hood open-addressed hash (2^k slots), pread per query.
//! - Filenames: raw length-prefixed bytes (Step 7 → zstd blocks + dict).
//!
//! Layout (all integers little-endian):
//! ```text
//! HEADER (40 B): magic[4] | version:u32 | num_docs:u32
//!                docs_off:u64 | try_off:u64 | post_off:u64 | slots_log2:u32
//! DOCS    : per doc (DocID = order): path_len:u32 | path bytes (UTF-8)
//! HASH    : slots × [key:u32 | count:u32 | post_off:u64 | enc_len:u32]  (20 B)
//!           empty slot: key = 0xFFFFFFFF (never a real 24-bit trigram)
//! POSTINGS: concatenated TurboPFor blobs (each referenced by a hash slot)
//! ```

use std::collections::BTreeMap;

use crate::error::CoreError;
use crate::{trigram::trigrams, turbopfor, DbSource, Result};

const MAGIC: &[u8; 4] = b"DFDB";
const VERSION: u32 = 1;
const HEADER_LEN: usize = 40;
const EMPTY_KEY: u32 = 0xFFFF_FFFF;
const SLOT_LEN: usize = 20;

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

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Accumulates paths + trigram→posting map, then serializes to one buffer.
pub struct DbBuilder {
    paths: Vec<String>,
    try_map: BTreeMap<u32, Vec<u32>>, // trigram -> sorted-unique DocIDs
}

impl DbBuilder {
    pub fn new() -> Self {
        Self {
            paths: Vec::new(),
            try_map: BTreeMap::new(),
        }
    }

    /// Insert a path (caller dedups). Returns the assigned DocID.
    pub fn insert(&mut self, path: &str) -> u32 {
        let id = self.paths.len() as u32;
        self.paths.push(path.to_string());
        let lower = path.to_lowercase();
        for t in trigrams(lower.as_bytes()) {
            let v = self.try_map.entry(t).or_default();
            if v.last() != Some(&id) {
                v.push(id);
            }
        }
        id
    }

    pub fn doc_count(&self) -> u32 {
        self.paths.len() as u32
    }

    /// Serialize to a self-contained byte buffer.
    pub fn finish(self) -> Vec<u8> {
        let num_docs = self.paths.len() as u32;

        let mut docs = Vec::new();
        for p in &self.paths {
            let b = p.as_bytes();
            docs.extend_from_slice(&(b.len() as u32).to_le_bytes());
            docs.extend_from_slice(b);
        }

        let docs_off = HEADER_LEN as u64;
        let try_off = docs_off + docs.len() as u64;

        // Hash table size: power-of-two with load factor ≤ 0.5.
        let n_entries = self.try_map.len() as u64;
        let slots = if n_entries == 0 {
            0
        } else {
            (n_entries * 2).next_power_of_two().max(1)
        };
        let table_bytes = slots as usize * SLOT_LEN;
        let post_off = try_off + table_bytes as u64;

        // Encode postings, recording each trigram's (count, absolute offset, len).
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

        let mut out = Vec::with_capacity(HEADER_LEN + docs.len() + table.len() + post_sec.len());
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&num_docs.to_le_bytes());
        out.extend_from_slice(&docs_off.to_le_bytes());
        out.extend_from_slice(&try_off.to_le_bytes());
        out.extend_from_slice(&post_off.to_le_bytes());
        out.extend_from_slice(&slots_log2.to_le_bytes());
        out.extend_from_slice(&docs);
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

/// Build a Robin Hood (displacement-stealing) open-addressed table. `slots`
/// must be a power of two (or 0). Each slot holds (key, count, post_off, enc_len).
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
        // current entry being placed + its probe distance from its ideal slot
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
                // steal the slot; continue inserting the evicted resident
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

/// Reads an index DB through a [`DbSource`] (pread/low-RSS in the daemon,
/// `&[u8]` in tests). Trigram lookups are lazy: each [`DbReader::posting`] does
/// a Robin Hood probe + a single posting pread + TurboPFor decode.
pub struct DbReader<S> {
    src: S,
    num_docs: u32,
    doc_off: Vec<u64>,
    try_off: u64,
    slots: u64,
    mask: u64,
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
        let docs_off = le_u64(&hdr, 12);
        let try_off = le_u64(&hdr, 20);
        let slots_log2 = le_u32(&hdr, 36);
        let slots: u64 = if slots_log2 == 0 {
            0
        } else {
            1u64 << slots_log2
        };

        // Per-doc filename offsets (eager; Step 7 moves filenames to zstd blocks).
        let docs_len = try_off
            .checked_sub(docs_off)
            .ok_or_else(|| CoreError::DbFormat("try_off < docs_off".into()))?;
        let docs_bytes = src.read_at(docs_off, docs_len as usize)?;
        let mut doc_off = Vec::with_capacity(num_docs as usize);
        let mut p = 0usize;
        for _ in 0..num_docs {
            if p + 4 > docs_bytes.len() {
                return Err(CoreError::DbFormat("truncated docs section".into()));
            }
            doc_off.push(docs_off + p as u64);
            let len = le_u32(&docs_bytes, p) as usize;
            p += 4 + len;
            if p > docs_bytes.len() {
                return Err(CoreError::DbFormat("doc path overruns docs section".into()));
            }
        }

        Ok(Self {
            src,
            num_docs,
            doc_off,
            try_off,
            slots,
            mask: if slots == 0 { 0 } else { slots - 1 },
        })
    }

    pub fn num_docs(&self) -> u32 {
        self.num_docs
    }

    /// Fetch the original-case path for `docid`.
    pub fn doc_path(&self, docid: u32) -> Result<String> {
        let off = *self
            .doc_off
            .get(docid as usize)
            .ok_or_else(|| CoreError::Query(format!("docid {docid} out of range")))?;
        let len_bytes = self.src.read_at(off, 4)?;
        let len = le_u32(&len_bytes, 0) as usize;
        let pb = self.src.read_at(off + 4, len)?;
        String::from_utf8(pb).map_err(|e| CoreError::DbFormat(format!("non-utf8 path: {e}")))
    }

    /// Robin Hood lookup of `trig`; on hit, pread + TurboPFor-decode the posting
    /// list (sorted-unique DocIDs). Returns `Ok(None)` if `trig` is not indexed.
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
            // Robin Hood: if the resident is closer to its ideal slot than we are
            // to ours, our key can't be further along → absent.
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
