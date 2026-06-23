// SPDX-License-Identifier: MIT
//! Pure grep-style line helpers: given content bytes and a match byte offset,
//! compute the 1-based line number, the line text, and a `-C N` context block.
//! Pure over `&[u8]` — the daemon assembles the wire `LineHit` from these.

use crate::fold::fold;

/// All byte offsets where `needle` occurs in `content` (literal matching).
/// `needle` is the verify needle (raw if `case_sensitive`, ASCII-folded
/// otherwise); the content is folded internally when not case-sensitive so the
/// offsets line up with the folded needle.
pub fn literal_match_offsets(content: &[u8], needle: &[u8], case_sensitive: bool) -> Vec<usize> {
    if needle.is_empty() {
        return Vec::new();
    }
    if case_sensitive {
        memchr::memmem::find_iter(content, needle).collect()
    } else {
        let folded = fold(content);
        memchr::memmem::find_iter(&folded, needle).collect()
    }
}

/// 1-based line number of the line containing `byte_off`.
pub fn line_number(content: &[u8], byte_off: usize) -> u32 {
    let up = byte_off.min(content.len());
    content[..up].iter().filter(|&&b| b == b'\n').count() as u32 + 1
}

/// The full line text (no trailing newline) containing `byte_off`.
pub fn line_text(content: &[u8], byte_off: usize) -> String {
    let up = byte_off.min(content.len());
    let start = content[..up]
        .iter()
        .rposition(|&b| b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    let end = content[up..]
        .iter()
        .position(|&b| b == b'\n')
        .map(|i| up + i)
        .unwrap_or(content.len());
    String::from_utf8_lossy(&content[start..end]).into_owned()
}

/// `-C n`: up to `n` lines before + the match line + up to `n` lines after,
/// joined by `\n`. Returns (first_line_no, joined_text) — a grep-style block.
pub fn context_block(content: &[u8], byte_off: usize, n: u32) -> (u32, String) {
    let up = byte_off.min(content.len());
    let line_start = content[..up]
        .iter()
        .rposition(|&b| b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    // End of the match line: just past its trailing newline (or EOF).
    let line_end = content[up..]
        .iter()
        .position(|&b| b == b'\n')
        .map(|i| up + i + 1)
        .unwrap_or(content.len());

    // Walk back n lines: block_start = start of the n-th preceding line. Search
    // strictly before the newline that precedes `block_start`, so each step
    // crosses exactly one line boundary.
    let mut block_start = line_start;
    for _ in 0..n {
        if block_start == 0 {
            break;
        }
        match content[..block_start - 1].iter().rposition(|&b| b == b'\n') {
            Some(i) => block_start = i + 1,
            None => {
                block_start = 0;
                break;
            }
        }
    }
    // Walk forward n lines: block_end = end of the n-th following line.
    let mut block_end = line_end;
    for _ in 0..n {
        if block_end >= content.len() {
            break;
        }
        match content[block_end..].iter().position(|&b| b == b'\n') {
            Some(i) => block_end += i + 1,
            None => {
                block_end = content.len();
                break;
            }
        }
    }
    let first_no = content[..block_start]
        .iter()
        .filter(|&&b| b == b'\n')
        .count() as u32
        + 1;
    (
        first_no,
        String::from_utf8_lossy(&content[block_start..block_end]).into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &[u8] = b"alpha\nbeta\nGAMMA\ndelta\nepsilon\n";

    #[test]
    fn line_number_is_one_based() {
        assert_eq!(line_number(SAMPLE, 0), 1); // 'a' of alpha
        assert_eq!(line_number(SAMPLE, 6), 2); // 'b' of beta (after \n at 5)
        assert_eq!(line_number(SAMPLE, 11), 3); // 'G' of GAMMA
    }

    #[test]
    fn line_text_excludes_newline() {
        assert_eq!(line_text(SAMPLE, 0), "alpha");
        assert_eq!(line_text(SAMPLE, 11), "GAMMA");
    }

    #[test]
    fn context_block_matches_grep_c1() {
        // grep -C1 around line 3 (GAMMA) → lines 2..4 = beta / GAMMA / delta.
        let (no, block) = context_block(SAMPLE, 11, 1);
        assert_eq!(no, 2);
        assert_eq!(block, "beta\nGAMMA\ndelta\n");
    }

    #[test]
    fn context_block_at_start_clamps() {
        // -C1 at line 1 clamps: no line before → block is alpha/beta.
        let (no, block) = context_block(SAMPLE, 0, 1);
        assert_eq!(no, 1);
        assert_eq!(block, "alpha\nbeta\n");
    }
}
