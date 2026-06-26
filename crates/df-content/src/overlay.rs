// SPDX-License-Identifier: MIT
//! Hot overlay — the LSM "MemTable" that absorbs per-file changes between
//! compactions. Pure over owned in-memory data (no I/O); the daemon holds it
//! behind an `ArcSwap` and `df-index::overlay_store` persists it as a WAL.
//!
//! Query model: the cold layers (filename `DbReader` + content `ShardReader`)
//! and this overlay are each queried independently; the daemon merges results
//! by path, letting overlay entries **override** cold ones and tombstones
//! **remove** cold ones (standard LSM read semantics). Because docids are local
//! to each source (`base_docid` is never added at query time), the overlay's
//! `0..N` docid space cannot collide with shard docids.

use std::collections::{BTreeMap, HashMap, HashSet};

use df_core::{
    candidate::candidates, trigram::trigrams, CandidateSource, CoreError, LiteMeta, Result,
};
use memchr::memmem;
use serde::{Deserialize, Serialize};

use crate::fold::{fold, fold_in_place};

/// In-memory hot overlay: per-file changes absorbed since the last compaction.
/// One entry per changed path; re-upserts replace in place, deletes leave an
/// inert slot plus a tombstone.
#[derive(Debug, Clone, Default)]
pub struct Overlay {
    /// path → local docid.
    by_path: HashMap<String, u32>,
    /// docid → path.
    paths: Vec<String>,
    /// docid → metadata.
    metas: Vec<LiteMeta>,
    /// docid → content bytes; `None` = not content-indexed (dir / binary / too large).
    contents: Vec<Option<Vec<u8>>>,
    /// trigram → docids (the content index, mirroring `ShardBuilder::try_map`).
    try_map: BTreeMap<u32, Vec<u32>>,
    /// docid → the trigrams it appears in (targeted posting removal on replace).
    doc_trigrams: Vec<Vec<u32>>,
    /// Deleted paths — suppresses cold-layer hits at query merge time.
    tombstones: HashSet<String>,
}

impl Overlay {
    /// Apply one WAL record (pure; the I/O layer feeds this the replayed log).
    pub fn apply_record(&mut self, rec: &WalRecord) {
        match rec {
            WalRecord::Upsert {
                path,
                meta,
                content,
            } => {
                self.tombstones.remove(path);
                // Re-upsert: drop this doc's old trigram postings first.
                if let Some(&d) = self.by_path.get(path) {
                    self.remove_doc_postings(d);
                    self.metas[d as usize] = meta.clone();
                    self.contents[d as usize] = content.clone();
                } else {
                    let d = self.paths.len() as u32;
                    self.paths.push(path.clone());
                    self.metas.push(meta.clone());
                    self.contents.push(content.clone());
                    self.doc_trigrams.push(Vec::new());
                    self.by_path.insert(path.clone(), d);
                };
                let d = self.by_path[path];
                if let Some(c) = content {
                    let tris = {
                        let mut f = c.clone();
                        fold_in_place(&mut f);
                        trigrams(&f)
                    };
                    for t in &tris {
                        let v = self.try_map.entry(*t).or_default();
                        if v.last() != Some(&d) {
                            v.push(d);
                        }
                    }
                    self.doc_trigrams[d as usize] = tris;
                } else {
                    self.doc_trigrams[d as usize] = Vec::new();
                }
            }
            WalRecord::Delete { path } => {
                if let Some(&d) = self.by_path.get(path) {
                    self.remove_doc_postings(d);
                    self.contents[d as usize] = None;
                    self.doc_trigrams[d as usize] = Vec::new();
                }
                self.tombstones.insert(path.clone());
            }
        }
    }

    /// Replay a record stream (startup recovery + tests).
    pub fn apply_records<'a>(&'a mut self, recs: impl IntoIterator<Item = &'a WalRecord>) {
        for r in recs {
            self.apply_record(r);
        }
    }

    /// Remove every posting of `d` from `try_map` (replace/delete path).
    fn remove_doc_postings(&mut self, d: u32) {
        if let Some(tris) = self.doc_trigrams.get(d as usize) {
            for t in tris {
                if let Some(v) = self.try_map.get_mut(t) {
                    v.retain(|x| *x != d);
                    if v.is_empty() {
                        self.try_map.remove(t);
                    }
                }
            }
        }
    }

    /// Number of changed paths tracked (live + inert slots). Compaction trigger.
    pub fn len(&self) -> usize {
        self.paths.len()
    }

    pub fn is_empty(&self) -> bool {
        self.paths.is_empty()
    }

    /// Tombstones — the daemon retains these out of the merged result map.
    pub fn tombstones(&self) -> &HashSet<String> {
        &self.tombstones
    }

    /// Whether the overlay shadows any path (so cold-layer hits need filtering).
    /// False for an empty/freshly-compacted overlay → the common query skips the
    /// retain pass.
    pub fn shadows_anything(&self) -> bool {
        !self.paths.is_empty() || !self.tombstones.is_empty()
    }

    /// True if the overlay shadows `path` — the cold-layer hit for this path is
    /// stale and must be dropped at query-merge time (the overlay's own current
    /// version, if it matches, is added separately). Covers upserted (changed)
    /// AND tombstoned (deleted) paths.
    pub fn suppresses(&self, path: &str) -> bool {
        self.by_path.contains_key(path) || self.tombstones.contains(path)
    }

    /// path for a local docid (line rendering / result resolution).
    pub fn path(&self, docid: u32) -> Option<&str> {
        self.paths.get(docid as usize).map(|s| s.as_str())
    }

    /// content bytes for a local docid (`-n` / `-C` line rendering).
    pub fn content(&self, docid: u32) -> Option<&[u8]> {
        self.contents.get(docid as usize).and_then(|c| c.as_deref())
    }

    /// Content-layer query over the overlay: rarest-trigram candidate + verify
    /// (reuses `df_core::candidate::candidates` via [`OverlayReader`]). Returns
    /// `(path, meta)` per live (non-tombstoned) hit.
    pub fn content_query(
        &self,
        folded: &[u8],
        original: &[u8],
        case_sensitive: bool,
        limit: Option<u32>,
    ) -> Vec<(String, LiteMeta)> {
        let reader = OverlayReader { o: self };
        let docids =
            candidates(&reader, folded, original, case_sensitive, limit).unwrap_or_default();
        docids
            .into_iter()
            .filter_map(|d| {
                let path = self.paths.get(d as usize)?.clone();
                if self.tombstones.contains(&path) {
                    return None;
                }
                let meta = self.metas.get(d as usize).cloned().unwrap_or_default();
                Some((path, meta))
            })
            .collect()
    }

    /// Content-layer regex query: linear scan of overlay docs (the overlay is
    /// small by design, so the candidate index isn't worth building for regex).
    /// Returns `(path, meta)` per live doc whose content matches `re`.
    pub fn content_regex_hits(
        &self,
        re: &regex::bytes::Regex,
        limit: Option<u32>,
    ) -> Vec<(String, LiteMeta)> {
        let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
        let mut out = Vec::new();
        for (d, path) in self.paths.iter().enumerate() {
            if out.len() >= cap {
                break;
            }
            if self.tombstones.contains(path) {
                continue;
            }
            if let Some(content) = self.contents.get(d).and_then(|c| c.as_deref()) {
                if re.is_match(content) {
                    out.push((path.clone(), self.metas.get(d).cloned().unwrap_or_default()));
                }
            }
        }
        out
    }

    /// Filename-layer query: linear scan of the (small) overlay path list.
    /// `basename_only` mirrors the daemon's `PathMode::Basename`.
    pub fn filename_query(
        &self,
        needle: &str,
        case_sensitive: bool,
        basename_only: bool,
        limit: Option<u32>,
    ) -> Vec<(String, LiteMeta)> {
        let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
        let lneedle = needle.to_lowercase();
        let mut out = Vec::new();
        for (d, path) in self.paths.iter().enumerate() {
            if out.len() >= cap {
                break;
            }
            if self.tombstones.contains(path) {
                continue;
            }
            let hay = if basename_only {
                path.rsplit('/').next().unwrap_or(path)
            } else {
                path.as_str()
            };
            let hit = if case_sensitive {
                hay.contains(needle)
            } else {
                hay.to_lowercase().contains(&lneedle)
            };
            if hit {
                out.push((path.clone(), self.metas.get(d).cloned().unwrap_or_default()));
            }
        }
        out
    }
}

/// Borrowing view over an [`Overlay`] (mirrors `ShardReader` over its mmap):
/// the daemon constructs one per query so the owning `Arc<Overlay>` can be
/// swapped concurrently.
pub struct OverlayReader<'a> {
    o: &'a Overlay,
}

impl<'a> OverlayReader<'a> {
    pub fn new(o: &'a Overlay) -> Self {
        Self { o }
    }
}

impl<'a> CandidateSource for OverlayReader<'a> {
    fn cs_posting(&self, trig: u32) -> Result<Option<Vec<u32>>> {
        Ok(self.o.try_map.get(&trig).cloned())
    }

    fn cs_verify(&self, docid: u32, needle: &[u8], case_sensitive: bool) -> Result<bool> {
        let Some(Some(content)) = self.o.contents.get(docid as usize) else {
            return Ok(false);
        };
        if needle.is_empty() {
            return Ok(true);
        }
        Ok(if case_sensitive {
            memmem::find(content, needle).is_some()
        } else {
            let folded = fold(content);
            memmem::find(&folded, needle).is_some()
        })
    }

    fn cs_num_docs(&self) -> u32 {
        self.o.paths.len() as u32
    }
}

/// One persisted overlay operation. The WAL is an append-only stream of these,
/// framed as `u32 len + bincode body`; recovery replays them in order.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub enum WalRecord {
    Upsert {
        path: String,
        meta: LiteMeta,
        content: Option<Vec<u8>>,
    },
    Delete {
        path: String,
    },
}

/// Encode one record as a length-framed blob (for `df-index::overlay_store`).
pub fn encode_record(rec: &WalRecord) -> Result<Vec<u8>> {
    let body = bincode::serde::encode_to_vec(rec, bincode::config::standard())
        .map_err(|e| CoreError::Codec(format!("wal encode: {e}")))?;
    let mut out = (body.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(&body);
    Ok(out)
}

/// Decode a WAL byte stream into records. Stops at the first truncated or
/// corrupt frame — earlier complete records still apply (a half-written tail
/// from a crash is silently dropped; the safety-net rebuild backstops it).
pub fn decode_records(bytes: &[u8]) -> Vec<WalRecord> {
    let mut out = Vec::new();
    let mut p = 0usize;
    while p + 4 <= bytes.len() {
        let n = u32::from_le_bytes(bytes[p..p + 4].try_into().unwrap()) as usize;
        p += 4;
        if p + n > bytes.len() {
            break; // truncated tail
        }
        match bincode::serde::decode_from_slice::<WalRecord, _>(
            &bytes[p..p + n],
            bincode::config::standard(),
        ) {
            Ok((rec, _)) => out.push(rec),
            Err(_) => break, // corrupt frame → stop (prior records stand)
        }
        p += n;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(size: i64) -> LiteMeta {
        LiteMeta {
            is_dir: false,
            size,
            mtime: 0,
        }
    }

    fn upsert(path: &str, content: &str) -> WalRecord {
        WalRecord::Upsert {
            path: path.to_string(),
            meta: meta(content.len() as i64),
            content: Some(content.as_bytes().to_vec()),
        }
    }

    /// Folded/original pair for a lowercase query.
    fn q(s: &str) -> (&[u8], &[u8]) {
        (s.as_bytes(), s.as_bytes())
    }

    #[test]
    fn upsert_then_content_query_hits() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        let hits = o.content_query(q("hello").0, q("hello").1, false, None);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].0, "/a.txt");
    }

    #[test]
    fn re_upsert_replaces_old_postings() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        o.apply_record(&upsert("/a.txt", "goodbye now"));
        // old content no longer matches
        assert!(o
            .content_query(q("hello").0, q("hello").1, false, None)
            .is_empty());
        // new content does
        assert_eq!(
            o.content_query(q("goodbye").0, q("goodbye").1, false, None)
                .len(),
            1
        );
        // still a single entry, not duplicated
        assert_eq!(o.len(), 1);
    }

    #[test]
    fn delete_creates_tombstone_and_suppresses() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        o.apply_record(&WalRecord::Delete {
            path: "/a.txt".to_string(),
        });
        assert!(o.tombstones().contains("/a.txt"));
        assert!(o
            .content_query(q("hello").0, q("hello").1, false, None)
            .is_empty());
        assert!(o.filename_query("a.txt", false, false, None).is_empty());
    }

    #[test]
    fn delete_after_upsert_removes_postings() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        o.apply_record(&WalRecord::Delete {
            path: "/a.txt".to_string(),
        });
        // The trigram posting must be gone (not just masked by tombstone).
        let reader = OverlayReader::new(&o);
        assert!(reader.cs_posting(0x68_65_6c).unwrap().is_none()); // "hel"
    }

    #[test]
    fn recreate_after_delete_clears_tombstone() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        o.apply_record(&WalRecord::Delete {
            path: "/a.txt".to_string(),
        });
        o.apply_record(&upsert("/a.txt", "hello again"));
        assert!(!o.tombstones().contains("/a.txt"));
        assert_eq!(
            o.content_query(q("hello").0, q("hello").1, false, None)
                .len(),
            1
        );
    }

    #[test]
    fn candidates_over_overlay_matches_expected_docids() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        o.apply_record(&upsert("/b.txt", "hello there"));
        o.apply_record(&upsert("/c.txt", "totally unrelated"));
        let reader = OverlayReader::new(&o);
        // "hel" is the rarest trigram shared by /a and /b; verify keeps both.
        let docids = candidates(&reader, q("hello").0, q("hello").1, false, None).unwrap();
        assert_eq!(docids.len(), 2);
    }

    #[test]
    fn absent_trigram_returns_empty() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "hello world"));
        // query contains a trigram the overlay doesn't have → empty (cold layer
        // may still match; merged separately by the daemon).
        assert!(o
            .content_query(q("zzz").0, q("zzz").1, false, None)
            .is_empty());
    }

    #[test]
    fn short_query_scans_all_docs() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "ab"));
        // folded.len() < 3 → linear scan path
        let hits = o.content_query(q("a").0, q("a").1, false, None);
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn filename_query_full_path_and_basename() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/src/lib.rs", "x"));
        assert_eq!(o.filename_query("src", false, false, None).len(), 1); // full path
        assert_eq!(o.filename_query("lib.rs", false, true, None).len(), 1); // basename
        assert!(o.filename_query("src", false, true, None).is_empty()); // basename only
    }

    #[test]
    fn filename_query_case_sensitive() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/Foo.txt", "x"));
        assert_eq!(o.filename_query("Foo", true, false, None).len(), 1);
        assert!(o.filename_query("foo", true, false, None).is_empty()); // case-sensitive
        assert_eq!(o.filename_query("foo", false, false, None).len(), 1); // case-insensitive
    }

    #[test]
    fn content_case_insensitive_matches_folded() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "HelloWorld"));
        // folded needle "hello" against folded doc "helloworld"
        let f = b"hello".to_vec();
        let hits = o.content_query(&f, b"hello", false, None);
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn wal_record_roundtrip() {
        let recs = vec![
            upsert("/a.txt", "hello"),
            WalRecord::Delete {
                path: "/b".to_string(),
            },
            WalRecord::Upsert {
                path: "/c".to_string(),
                meta: meta(0),
                content: None,
            },
        ];
        let mut bytes = Vec::new();
        for r in &recs {
            bytes.extend_from_slice(&encode_record(r).unwrap());
        }
        assert_eq!(decode_records(&bytes), recs);
    }

    #[test]
    fn decode_stops_at_truncated_tail() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode_record(&upsert("/a.txt", "hello")).unwrap());
        let full_second = encode_record(&upsert("/b.txt", "world")).unwrap();
        bytes.extend_from_slice(&full_second);
        // truncate the last 3 bytes (corrupt the second frame's tail)
        bytes.truncate(bytes.len() - 3);
        let got = decode_records(&bytes);
        assert_eq!(got.len(), 1, "first record survives, second dropped");
        assert_eq!(got[0], upsert("/a.txt", "hello"));
    }

    #[test]
    fn replay_sequence_builds_expected_state() {
        let recs = vec![
            upsert("/a.txt", "hello world"),
            upsert("/b.txt", "hello there"),
            upsert("/a.txt", "goodbye"), // replace
            WalRecord::Delete {
                path: "/b.txt".to_string(),
            },
        ];
        let mut o = Overlay::default();
        o.apply_records(&recs);
        assert!(o
            .content_query(q("hello").0, q("hello").1, false, None)
            .is_empty()); // /a replaced, /b deleted
        assert_eq!(
            o.content_query(q("goodbye").0, q("goodbye").1, false, None)
                .len(),
            1
        );
        assert!(o.tombstones().contains("/b.txt"));
        assert_eq!(o.len(), 2); // /a (live) + /b (inert slot)
    }

    #[test]
    fn content_accessor_for_line_rendering() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "line1\nline2"));
        assert_eq!(o.content(0), Some(&b"line1\nline2"[..]));
        // a non-content-indexed doc returns None
        o.apply_record(&WalRecord::Upsert {
            path: "/d".to_string(),
            meta: meta(0),
            content: None,
        });
        assert_eq!(o.content(1), None);
    }

    #[test]
    fn content_regex_hits_scans_live_docs() {
        let mut o = Overlay::default();
        o.apply_record(&upsert("/a.txt", "foo123bar"));
        o.apply_record(&upsert("/b.txt", "no digits here"));
        let re = regex::bytes::Regex::new("[0-9]+").unwrap();
        let hits = o.content_regex_hits(&re, None);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].0, "/a.txt");
    }
}
