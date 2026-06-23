// SPDX-License-Identifier: MIT
//! Shared rarest-trigram candidate generation. Both the filename layer
//! (`DbReader`) and the content layer (`df_content::ShardReader`) implement
//! [`CandidateSource`], so the same `candidates()` algorithm drives both.

use crate::{trigram::trigrams, Result};

/// A source over which rarest-trigram candidate generation + per-doc verify runs.
pub trait CandidateSource {
    /// Postings (docids) for a trigram key, or `None` if absent.
    fn cs_posting(&self, trig: u32) -> Result<Option<Vec<u32>>>;
    /// True if `docid` contains `needle`.
    /// - `case_sensitive = true`  ⇒ exact bytes (`needle` is the raw query).
    /// - `case_sensitive = false` ⇒ case-folded (`needle` is pre-folded; the
    ///   impl folds the document bytes to match it).
    fn cs_verify(&self, docid: u32, needle: &[u8], case_sensitive: bool) -> Result<bool>;
    /// Total docs in this source.
    fn cs_num_docs(&self) -> u32;
}

/// Rarest-trigram candidate generation. Returns verified docids. Queries with no
/// trigram (<3 bytes) fall back to scanning all docs. Capped at `limit`.
///
/// `folded` (the case-folded query) drives trigram candidate generation: the
/// index is folded, so it is always a correct over-approximation regardless of
/// case mode. `original` (the raw query) is used for exact-case verify when
/// `case_sensitive`; otherwise `folded` is verified.
pub fn candidates<S: CandidateSource + ?Sized>(
    src: &S,
    folded: &[u8],
    original: &[u8],
    case_sensitive: bool,
    limit: Option<u32>,
) -> Result<Vec<u32>> {
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let needle: &[u8] = if case_sensitive { original } else { folded };
    let mut out = Vec::new();

    if folded.len() < 3 {
        for d in 0..src.cs_num_docs() {
            if out.len() >= cap {
                break;
            }
            if src.cs_verify(d, needle, case_sensitive)? {
                out.push(d);
            }
        }
        return Ok(out);
    }

    let qtris = trigrams(folded);
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
        if src.cs_verify(d, needle, case_sensitive)? {
            out.push(d);
        }
    }
    Ok(out)
}
