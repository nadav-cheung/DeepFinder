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
