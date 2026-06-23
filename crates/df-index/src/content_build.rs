// SPDX-License-Identifier: MIT
//! Streaming full-disk content build: walk → text-gate → dual builders → shard flush.
//! (The streaming pipeline lands in M4b; this file currently holds the text-gate.)

use std::path::Path;

/// What the text-gate decided about a file's content.
pub enum ContentDecision {
    /// Text; these (size-capped) bytes should be indexed.
    Text(Vec<u8>),
    /// Binary (NUL byte or excessive trigram diversity) — filename only.
    Binary,
    /// Larger than the size cap — filename only.
    TooLarge,
    /// Unreadable / vanished / not a regular file — filename only.
    Unreadable,
}

const NUL_SCAN_BYTES: usize = 8 * 1024;
const TRIGRAM_MAX: usize = 20_000;

/// Read up to `max_file_size` bytes of `path` and classify it. Files larger than
/// the cap are TooLarge (no content). NUL in the first 8 KB, or more than
/// `TRIGRAM_MAX` distinct byte trigrams ⇒ Binary.
pub fn classify(path: &Path, max_file_size: u64) -> ContentDecision {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return ContentDecision::Unreadable,
    };
    if !meta.is_file() {
        return ContentDecision::Unreadable;
    }
    if meta.len() > max_file_size {
        return ContentDecision::TooLarge;
    }
    let mut bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => return ContentDecision::Unreadable,
    };
    bytes.truncate(max_file_size as usize);
    let scan = bytes.len().min(NUL_SCAN_BYTES);
    if bytes[..scan].contains(&0u8) {
        return ContentDecision::Binary;
    }
    if bytes.len() >= 3 && distinct_trigrams(&bytes) > TRIGRAM_MAX {
        return ContentDecision::Binary;
    }
    ContentDecision::Text(bytes)
}

/// Count distinct byte trigrams (lowercased) — the binary/minified heuristic.
fn distinct_trigrams(bytes: &[u8]) -> usize {
    let mut folded = bytes.to_vec();
    for b in &mut folded {
        if b.is_ascii_uppercase() {
            *b |= 0x20;
        }
    }
    let mut set = std::collections::HashSet::new();
    for w in folded.windows(3) {
        set.insert((w[0], w[1], w[2]));
    }
    set.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_file_is_text() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("a.txt");
        std::fs::write(&p, b"fn main() { hello world }").unwrap();
        assert!(matches!(
            classify(&p, 1024 * 1024),
            ContentDecision::Text(_)
        ));
    }

    #[test]
    fn nul_byte_is_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("b.bin");
        std::fs::write(&p, b"abc\x00def").unwrap();
        assert!(matches!(classify(&p, 1024 * 1024), ContentDecision::Binary));
    }

    #[test]
    fn oversized_is_too_large() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("big.txt");
        std::fs::write(&p, vec![b'a'; 10]).unwrap();
        assert!(matches!(classify(&p, 5), ContentDecision::TooLarge));
    }

    #[test]
    fn missing_file_is_unreadable() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("nope.txt");
        assert!(matches!(
            classify(&p, 1024 * 1024),
            ContentDecision::Unreadable
        ));
    }
}
