// SPDX-License-Identifier: MIT
//! ASCII lowercase fold for byte slices (A-Z → a-z). Used by both the shard
//! builder (over content bytes) and the query verifier, so trigram keys and
//! substring matches agree byte-for-byte. Non-ASCII bytes are unchanged (CJK has
//! no case; matches the byte-trigram model).

#[inline]
pub fn fold_in_place(bytes: &mut [u8]) {
    for b in bytes {
        if b.is_ascii_uppercase() {
            *b |= 0x20;
        }
    }
}

/// Owned, folded copy.
pub fn fold(bytes: &[u8]) -> Vec<u8> {
    let mut out = bytes.to_vec();
    fold_in_place(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_ascii_upper() {
        assert_eq!(fold(b"AbC \xC3\xA9"), b"abc \xC3\xA9");
    }
}
