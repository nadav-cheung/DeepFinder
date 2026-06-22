// SPDX-License-Identifier: MIT
//! Query entry point. Dispatches to the fast single-term path, or to the
//! boolean evaluator ([`crate::boolquery`]) when the query contains
//! `AND`/`OR`/`NOT`/parens or multiple terms.
//!
//! [`query_docids`] is the primary engine call (returns DocIDs); [`query`]
//! resolves those to paths. The daemon uses `query_docids` so it can resolve
//! metadata, apply scope filtering, and stream results itself.

use crate::boolquery::{boolean_docids, parse, Node};
use crate::{DbReader, DbSource, Result};

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
    let folded = q.to_lowercase();
    crate::candidate::candidates(db, folded.as_bytes(), limit)
}
