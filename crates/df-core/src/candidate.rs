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
