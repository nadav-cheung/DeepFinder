// SPDX-License-Identifier: MIT
//! `.dfcs` content shard — builder (reader lands in M2b).
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

use df_core::db::build_robin_hood;
use df_core::{trigram::trigrams, turbopfor};

use crate::fold::fold_in_place;

const SHARD_VERSION: u16 = 1;

fn le_u32(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}
fn le_u64(v: u64) -> [u8; 8] {
    v.to_le_bytes()
}
fn le_i64(v: i64) -> [u8; 8] {
    v.to_le_bytes()
}
fn le_u16(v: u16) -> [u8; 2] {
    v.to_le_bytes()
}

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
        let slots_log2: u32 = if slots == 0 {
            0
        } else {
            slots.trailing_zeros()
        };

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
            df_core::varint::encode_u32(tag.len() as u32, &mut out);
            out.extend_from_slice(tag.as_bytes());
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

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

fn rd_u32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn rd_u64(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}
fn rd_i64(b: &[u8], at: usize) -> i64 {
    i64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

/// Read-only view over a `.dfcs` byte slice (borrowed; the daemon owns the mmap).
pub struct ShardReader<'a> {
    bytes: &'a [u8],
    num_docs: u32,
    base_docid: u32,
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
        let toc_end = toc_off
            .checked_add(toc_sz)
            .ok_or_else(|| CoreError::DbFormat("shard TOC overruns file".into()))?;
        if toc_end != footer {
            return Err(CoreError::DbFormat("shard TOC/end mismatch".into()));
        }
        let toc = &bytes[toc_off..toc_end];

        let mut p = 0usize;
        let count = rd_u32(toc, p) as usize;
        p += 4;
        let mut sect = std::collections::HashMap::new();
        for _ in 0..count {
            let tag_len = df_core::varint::decode_u32(toc, &mut p)
                .ok_or_else(|| CoreError::DbFormat("bad tag varint".into()))?
                as usize;
            let tag_bytes = &toc[p..p + tag_len];
            p += tag_len;
            let _kind = toc[p];
            p += 1;
            let off = rd_u32(toc, p);
            p += 4;
            let sz = rd_u32(toc, p);
            p += 4;
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
        let num_docs = rd_u32(md, 18);
        let base_docid = rd_u32(md, 14);
        let slots_log2 = rd_u32(md, 22);
        let slots: u64 = if slots_log2 == 0 {
            0
        } else {
            1u64 << slots_log2
        };

        Ok(Self {
            bytes,
            num_docs,
            base_docid,
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
        let fns = self.section("fileNames")?;
        let mut p = 0usize;
        for i in 0..=local_docid as usize {
            if p + 4 > fns.len() {
                return Err(CoreError::DbFormat("fileNames truncated".into()));
            }
            let len = rd_u32(fns, p) as usize;
            p += 4;
            if p + len > fns.len() {
                return Err(CoreError::DbFormat("path overruns fileNames".into()));
            }
            if i == local_docid as usize {
                return String::from_utf8(fns[p..p + len].to_vec())
                    .map_err(|e| CoreError::DbFormat(format!("non-utf8 path: {e}")));
            }
            p += len;
        }
        Err(CoreError::DbFormat("docid not in fileNames".into()))
    }

    /// Per-doc metadata.
    pub fn meta(&self, local_docid: u32) -> df_core::Result<df_core::LiteMeta> {
        use df_core::error::CoreError;
        let fm = self.section("fileMeta")?;
        let at = local_docid as usize * 17;
        if at + 17 > fm.len() {
            return Err(CoreError::Query("docid out of range".into()));
        }
        Ok(df_core::LiteMeta {
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
            let slot_off = idx as usize * df_core::db::SLOT_LEN;
            if slot_off + df_core::db::SLOT_LEN > hash.len() {
                return Err(CoreError::DbFormat("ctHash truncated".into()));
            }
            let key = rd_u32(hash, slot_off);
            if key == df_core::db::EMPTY_KEY {
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
                if post_off + enc_len > postings.len() {
                    return Err(CoreError::DbFormat("posting overruns ctPostings".into()));
                }
                let deltas = df_core::turbopfor::decode(
                    &postings[post_off..post_off + enc_len],
                    count as usize,
                );
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
