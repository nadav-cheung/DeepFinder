// SPDX-License-Identifier: MIT
//! Query entry point. Dispatches to the fast single-term path, or to the
//! boolean evaluator ([`crate::boolquery`]) when the query contains
//! `AND`/`OR`/`NOT`/parens or multiple terms.

use crate::boolquery::{boolean_query, parse, Node};
use crate::{trigram::trigrams, DbReader, DbSource, Result};

/// Return matching paths for `q`, optionally capped at `limit`. Supports boolean
/// operators (uppercase `AND`/`OR`/`NOT`, parentheses, implicit AND).
pub fn query<S: DbSource>(db: &DbReader<S>, q: &str, limit: Option<u32>) -> Result<Vec<String>> {
    if q.is_empty() {
        return Ok(Vec::new());
    }
    match parse(q) {
        Some(Node::Term(_)) => single(db, q, limit),
        Some(node) => boolean_query(db, &node, limit),
        None => single(db, q, limit), // malformed → treat the raw string as one substring
    }
}

/// Fast single-substring path: rarest query trigram → posting list → substring
/// verify. Short queries (<3 bytes) fall back to a linear scan.
fn single<S: DbSource>(db: &DbReader<S>, q: &str, limit: Option<u32>) -> Result<Vec<String>> {
    let q_lower = q.to_lowercase();
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let needle = q_lower.as_str();

    if q_lower.len() < 3 {
        return scan(db, needle, cap);
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
