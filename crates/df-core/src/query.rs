// SPDX-License-Identifier: MIT
//! Query entry point. Dispatches to the fast single-term path, or to the
//! boolean evaluator ([`crate::boolquery`]) when the query contains
//! `AND`/`OR`/`NOT`/parens or multiple terms.
//!
//! [`query_docids`] is the primary engine call (returns DocIDs); [`query`]
//! resolves those to paths. The daemon uses `query_docids` so it can resolve
//! metadata, apply scope filtering, and stream results itself.

use crate::boolquery::{boolean_docids, parse, Node};
use crate::{trigram::trigrams, DbReader, DbSource, Result};

/// Matching DocIDs for `q`, optionally capped at `limit`. Supports boolean
/// operators (uppercase `AND`/`OR`/`NOT`, parentheses, implicit AND).
pub fn query_docids<S: DbSource>(
    db: &DbReader<S>,
    q: &str,
    limit: Option<u32>,
) -> Result<Vec<u32>> {
    if q.is_empty() {
        return Ok(Vec::new());
    }
    match parse(q) {
        Some(Node::Term(_)) => single_docids(db, q, limit),
        Some(node) => boolean_docids(db, &node, limit),
        None => single_docids(db, q, limit), // malformed → raw substring
    }
}

/// Return matching paths for `q`, optionally capped at `limit`. (Resolves
/// [`query_docids`] to path strings.)
pub fn query<S: DbSource>(db: &DbReader<S>, q: &str, limit: Option<u32>) -> Result<Vec<String>> {
    let docids = query_docids(db, q, limit)?;
    let mut out = Vec::with_capacity(docids.len());
    for d in docids {
        out.push(db.doc_path(d)?);
    }
    Ok(out)
}

/// Fast single-substring path: rarest query trigram → posting list → substring
/// verify. Short queries (<3 bytes) fall back to a linear scan.
fn single_docids<S: DbSource>(db: &DbReader<S>, q: &str, limit: Option<u32>) -> Result<Vec<u32>> {
    let q_lower = q.to_lowercase();
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let needle = q_lower.as_str();

    if q_lower.len() < 3 {
        return scan_docids(db, needle, cap);
    }

    let qtris = trigrams(q_lower.as_bytes());
    let mut best: Option<Vec<u32>> = None;
    for t in &qtris {
        match db.posting(*t)? {
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
    for d in cands {
        if out.len() >= cap {
            break;
        }
        let p = db.doc_path(d)?;
        if p.to_lowercase().contains(needle) {
            out.push(d);
        }
    }
    Ok(out)
}

fn scan_docids<S: DbSource>(db: &DbReader<S>, needle: &str, cap: usize) -> Result<Vec<u32>> {
    let mut out = Vec::new();
    for d in 0..db.num_docs() {
        if out.len() >= cap {
            break;
        }
        let p = db.doc_path(d)?;
        if p.to_lowercase().contains(needle) {
            out.push(d);
        }
    }
    Ok(out)
}
