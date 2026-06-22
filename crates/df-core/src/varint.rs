// SPDX-License-Identifier: MIT
//! LEB128 varint codec (slice's varint encoding).
//!
//! Step 1 posting format: sorted-unique DocIDs delta-encoded, each delta as a
//! varint. Replaced by TurboPFor in Step 5; the varint codec stays as a
//! reference + fallback.

/// Encode `v` as a LEB128 varint, appending to `out`.
pub fn encode_u32(mut v: u32, out: &mut Vec<u8>) {
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
            out.push(b);
        } else {
            out.push(b);
            return;
        }
    }
}

/// Decode one varint at `*pos`, advancing `*pos`. Returns `None` on truncation.
pub fn decode_u32(buf: &[u8], pos: &mut usize) -> Option<u32> {
    let mut result = 0u32;
    let mut shift = 0u32;
    loop {
        if *pos >= buf.len() {
            return None;
        }
        let b = buf[*pos];
        *pos += 1;
        result |= ((b & 0x7f) as u32) << shift;
        if b & 0x80 == 0 {
            return Some(result);
        }
        shift += 7;
        if shift >= 35 {
            return None; // overflow / malformed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        for &v in &[
            0u32,
            1,
            127,
            128,
            16383,
            16384,
            0xdead_beef,
            u32::MAX / 4,
            u32::MAX,
        ] {
            let mut buf = Vec::new();
            encode_u32(v, &mut buf);
            let mut pos = 0;
            assert_eq!(decode_u32(&buf, &mut pos), Some(v), "v={v}");
            assert_eq!(pos, buf.len(), "v={v}");
        }
    }

    #[test]
    fn sequence() {
        let vals = [3u32, 300, 0, 1_000_000, 42];
        let mut buf = Vec::new();
        for v in vals {
            encode_u32(v, &mut buf);
        }
        let mut pos = 0;
        for v in vals {
            assert_eq!(decode_u32(&buf, &mut pos), Some(v));
        }
        assert_eq!(pos, buf.len());
    }

    #[test]
    fn truncated() {
        let mut buf = Vec::new();
        encode_u32(300, &mut buf); // 0xAC 0x02
        let mut pos = 0;
        assert_eq!(decode_u32(&buf[..1], &mut pos), None);
    }
}
