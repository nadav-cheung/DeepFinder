// SPDX-License-Identifier: MIT
//! Robin Hood hash table correctness: present/absent lookups + scale.

use df_core::db::{DbBuilder, DbReader};
use df_core::query::query;
use df_core::trigram::trigrams;

#[test]
fn present_and_absent_lookups() {
    let mut b = DbBuilder::new();
    let words = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    ];
    for i in 0..400 {
        b.insert(&format!("/u/x/{}/f{:04}", words[i % words.len()], i));
    }
    let bytes = b.finish();
    let r = DbReader::open(bytes.as_slice()).unwrap();

    // A present trigram resolves to a posting list.
    let present = trigrams(b"alph")[1]; // "lph" — appears in "alpha"
    assert!(r.posting(present).unwrap().is_some());
    // An absent trigram returns None (without scanning the whole table).
    assert!(r.posting(trigrams(b"zzz")[0]).unwrap().is_none());

    // Query counts: 400 paths / 8 words = 50 each.
    for w in &words {
        assert_eq!(query(&r, w, None).unwrap().len(), 50, "word {w}");
    }
}

#[test]
fn scale_distinct_trigrams() {
    let mut b = DbBuilder::new();
    for i in 0..3000 {
        // Distinct 6-hex token → thousands of distinct trigrams → many collisions.
        let tok = format!("{:06x}", (i as u32).wrapping_mul(2654435761) & 0x00FF_FFFF);
        b.insert(&format!("/d/{}/x{}", tok, i));
    }
    let bytes = b.finish();
    let r = DbReader::open(bytes.as_slice()).unwrap();
    assert_eq!(r.num_docs(), 3000);

    // Each sampled token's own path must be findable.
    for i in 0..50 {
        let tok = format!("{:06x}", (i as u32).wrapping_mul(2654435761) & 0x00FF_FFFF);
        assert!(
            query(&r, &tok, None)
                .unwrap()
                .iter()
                .any(|p| p.contains(&tok)),
            "token {tok} (i={i}) not found"
        );
    }
}
