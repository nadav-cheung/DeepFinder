// SPDX-License-Identifier: MIT
//! Single-file index DB: builder + reader.
//!
//! Step 1 (slice) format — deliberately simple; hardening comes later:
//! - Postings: varint-delta (Step 5 swaps in TurboPFor).
//! - Trigram table: linear, loaded eagerly into a HashMap (Step 6 → on-disk
//!   Robin Hood + pread lookup).
//! - Filenames: raw length-prefixed bytes (Step 7 → zstd blocks + dict).
//!
//! Layout (all integers little-endian):
//! ```text
//! HEADER (36 B): magic[4] | version:u32 | num_docs:u32
//!                 docs_off:u64 | try_off:u64 | try_len:u64
//! DOCS   : for each doc (DocID = order): path_len:u32 | path bytes (UTF-8)
//! TRIGRAMS: num:u32 | repeat { key:u32 | count:u32 | count × varint-delta docid }
//! ```

use std::collections::{BTreeMap, HashMap};

use crate::error::CoreError;
use crate::{trigram::trigrams, varint, DbSource, Result};

const MAGIC: &[u8; 4] = b"DFDB";
const VERSION: u32 = 1;
const HEADER_LEN: usize = 36;

fn le_u32(buf: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(buf[at..at + 4].try_into().unwrap())
}
fn le_u64(buf: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(buf[at..at + 8].try_into().unwrap())
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
            // DocIDs are inserted in increasing order, so `id` is strictly
            // greater than the current last → append keeps the list sorted+unique.
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

        let mut try_sec = Vec::new();
        try_sec.extend_from_slice(&(self.try_map.len() as u32).to_le_bytes());
        for (key, post) in &self.try_map {
            try_sec.extend_from_slice(&key.to_le_bytes());
            try_sec.extend_from_slice(&(post.len() as u32).to_le_bytes());
            let mut prev = 0u32;
            for &d in post {
                varint::encode_u32(d - prev, &mut try_sec);
                prev = d;
            }
        }

        let docs_off = HEADER_LEN as u64;
        let try_off = docs_off + docs.len() as u64;
        let try_len = try_sec.len() as u64;

        let mut out = Vec::with_capacity(HEADER_LEN + docs.len() + try_sec.len());
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&num_docs.to_le_bytes());
        out.extend_from_slice(&docs_off.to_le_bytes());
        out.extend_from_slice(&try_off.to_le_bytes());
        out.extend_from_slice(&try_len.to_le_bytes());
        out.extend_from_slice(&docs);
        out.extend_from_slice(&try_sec);
        out
    }
}

impl Default for DbBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// Reads an index DB through a [`DbSource`] (pread/low-RSS in the daemon,
/// `&[u8]` in tests). The slice loads the trigram table eagerly; later steps
/// make lookups lazy.
pub struct DbReader<S> {
    src: S,
    num_docs: u32,
    doc_off: Vec<u64>,
    try_index: HashMap<u32, Vec<u32>>,
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
        let try_len = le_u64(&hdr, 28);

        // Build per-doc offset index by scanning the docs section once.
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

        // Decode the trigram table.
        let try_bytes = src.read_at(try_off, try_len as usize)?;
        if try_bytes.len() < 4 {
            return Err(CoreError::DbFormat("truncated trigram table".into()));
        }
        let n = le_u32(&try_bytes, 0);
        let mut q = 4usize;
        let mut try_index = HashMap::with_capacity(n as usize);
        for _ in 0..n {
            if q + 8 > try_bytes.len() {
                return Err(CoreError::DbFormat("truncated trigram entry".into()));
            }
            let key = le_u32(&try_bytes, q);
            let count = le_u32(&try_bytes, q + 4);
            q += 8;
            let mut post = Vec::with_capacity(count as usize);
            let mut prev = 0u32;
            for _ in 0..count {
                let delta = varint::decode_u32(&try_bytes, &mut q)
                    .ok_or_else(|| CoreError::Codec("truncated posting varint".into()))?;
                prev = prev
                    .checked_add(delta)
                    .ok_or_else(|| CoreError::Codec("docid overflow".into()))?;
                post.push(prev);
            }
            try_index.insert(key, post);
        }

        Ok(Self {
            src,
            num_docs,
            doc_off,
            try_index,
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

    /// Posting list (sorted-unique DocIDs) for a trigram key, if indexed.
    pub fn posting(&self, trig: u32) -> Option<&Vec<u32>> {
        self.try_index.get(&trig)
    }
}
