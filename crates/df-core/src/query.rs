// SPDX-License-Identifier: MIT
//! Query algorithm over a [`DbReader`].
//!
//! plocate-style: for queries with ≥3 bytes, pick the **rarest** query trigram
//! (all query trigrams must be present — if any is absent, no path can contain
//! the query), decode its posting list, then verify each candidate is an actual
//! case-insensitive substring. Short queries (<3 bytes) fall back to a linear
//! scan.

use crate::{trigram::trigrams, DbReader, DbSource, Result};

/// Return matching paths for `q`, optionally capped at `limit`.
pub fn query<S: DbSource>(db: &DbReader<S>, q: &str, limit: Option<u32>) -> Result<Vec<String>> {
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let q_lower = q.to_lowercase();
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let needle = q_lower.as_str();

    // Short query: no trigrams → linear scan over all docs.
    if q_lower.len() < 3 {
        return scan(db, needle, cap);
    }

    // Trigram path: every query trigram must be indexed; pick the rarest.
    let qtris = trigrams(q_lower.as_bytes());
    let mut best: Option<&Vec<u32>> = None;
    for t in &qtris {
        match db.posting(*t) {
            Some(post) => {
                best = Some(match best {
                    None => post,
                    Some(b) if post.len() < b.len() => post,
                    Some(b) => b,
                });
            }
            // A query trigram absent from the index ⇒ the query can't be a
            // substring of any indexed path.
            None => return Ok(Vec::new()),
        }
    }
    let Some(cands) = best else {
        return Ok(Vec::new());
    };

    let mut out = Vec::new();
    for &d in cands {
        let p = db.doc_path(d)?;
        if p.to_lowercase().contains(needle) {
            out.push(p);
            if out.len() >= cap {
                break;
            }
        }
    }
    Ok(out)
}

fn scan<S: DbSource>(db: &DbReader<S>, needle: &str, cap: usize) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for d in 0..db.num_docs() {
        let p = db.doc_path(d)?;
        if p.to_lowercase().contains(needle) {
            out.push(p);
            if out.len() >= cap {
                break;
            }
        }
    }
    Ok(out)
}
