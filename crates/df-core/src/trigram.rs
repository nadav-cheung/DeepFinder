// SPDX-License-Identifier: MIT
//! Byte-level trigram extraction.
//!
//! Trigrams are byte windows over an **already-lowercased** byte slice. Each
//! 3-byte window packs into the low 24 bits of a `u32` (big-endian within the
//! trigram). Byte trigrams make CJK "just work" — a CJK char is 3 UTF-8 bytes,
//! so it forms trigrams natively with no tokenizer (matches the finding in the
//! old `CTrigramIndex.h`).

/// Sorted, de-duplicated trigram keys of `lowercased`. Empty if fewer than 3 bytes
/// (the caller handles the short-query fallback).
pub fn trigrams(lowercased: &[u8]) -> Vec<u32> {
    if lowercased.len() < 3 {
        return Vec::new();
    }
    let mut out: Vec<u32> = Vec::with_capacity(lowercased.len() - 2);
    for w in lowercased.windows(3) {
        out.push((w[0] as u32) << 16 | (w[1] as u32) << 8 | w[2] as u32);
    }
    out.sort_unstable();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(a: u8, b: u8, c: u8) -> u32 {
        (a as u32) << 16 | (b as u32) << 8 | c as u32
    }

    #[test]
    fn basic() {
        assert_eq!(
            trigrams(b"abcd"),
            vec![key(b'a', b'b', b'c'), key(b'b', b'c', b'd')]
        );
        assert!(trigrams(b"ab").is_empty());
        assert!(trigrams(b"").is_empty());
    }

    #[test]
    fn dedup_and_sorted() {
        // "ababa" → windows: aba, bab, aba → unique {aba, bab}
        let t = trigrams(b"ababa");
        assert_eq!(t, vec![key(b'a', b'b', b'a'), key(b'b', b'a', b'b')]);
    }
}
