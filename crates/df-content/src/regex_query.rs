// SPDX-License-Identifier: MIT
//! Engine-level content regex: the longest literal atom of the regex drives
//! rarest-trigram candidate generation (case-insensitive superset); the compiled
//! regex is the authoritative verifier over the mmap'd content bytes. Mirrors the
//! filename-regex path (`df_ipc::filter::longest_literal_atom` + `regex.is_match`).
//!
//! Pure over a borrowed `ShardReader` (the daemon owns the mmap). No I/O.

use crate::shard::ShardReader;
use df_core::candidate::candidates;

/// Local docids in `reader` whose content matches `re`. `atom_folded` is the
/// case-folded longest literal atom of the regex — it only *prefilters*
/// candidates (always a superset), so candidate gen stays case-insensitive;
/// `re` decides authoritatively. Capped at `limit`.
pub fn content_regex_docids<'a>(
    reader: &ShardReader<'a>,
    atom_folded: &[u8],
    re: &regex::bytes::Regex,
    limit: Option<u32>,
) -> df_core::Result<Vec<u32>> {
    // Candidate gen is case-insensitive: the atom is a prefilter only (a folded
    // superset), so case mode never affects the trigram/posting stage — it is
    // encoded into `re` (smart-case `(?i)` is applied by the caller before this).
    let cands = candidates(reader, atom_folded, atom_folded, false, limit)?;
    let mut out = Vec::new();
    for d in cands {
        if re.is_match(reader.content(d)?) {
            out.push(d);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{fold, shard::ShardBuilder};

    fn one_shard(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut b = ShardBuilder::new(0, 0);
        for (p, c) in files {
            b.add_file(p, false, c.len() as i64, 0, c);
        }
        b.finish(0)
    }

    #[test]
    fn regex_matches_like_grep_e() {
        // Three files; only the first two contain "fn" followed (later) by "main".
        let bytes = one_shard(&[
            ("a.rs", b"fn main() { }"),
            ("b.rs", b"async fn main() -> u32 { 0 }"),
            ("c.rs", b"struct Foo; // no main here"),
        ]);
        let r = ShardReader::open(&bytes).unwrap();
        let re = regex::bytes::Regex::new("fn.*main").unwrap(); // case-sensitive
        // atom = "fn" (the longest literal run in "fn.*main"), folded.
        let atom_folded = fold::fold(b"fn");
        let ds = content_regex_docids(&r, &atom_folded, &re, None).unwrap();
        assert_eq!(ds, vec![0, 1]); // a.rs, b.rs; NOT c.rs
    }

    #[test]
    fn regex_respects_limit() {
        let bytes = one_shard(&[
            ("a.rs", b"fn main() {}"),
            ("b.rs", b"fn main() {}"),
            ("c.rs", b"fn main() {}"),
        ]);
        let r = ShardReader::open(&bytes).unwrap();
        let re = regex::bytes::Regex::new("main").unwrap();
        let atom_folded = fold::fold(b"main");
        let ds = content_regex_docids(&r, &atom_folded, &re, Some(2)).unwrap();
        assert_eq!(ds.len(), 2);
    }
}
