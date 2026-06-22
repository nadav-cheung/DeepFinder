// SPDX-License-Identifier: MIT
//! PFor-delta (Patched Frame-of-Reference) posting codec, TurboPFor-style.
//!
//! Postings are sorted-unique u32 DocIDs; the caller delta-encodes them before
//! handing the deltas to [`encode`]. Block size is 128.
//!
//! # Block layout
//! For each block of up to 128 deltas:
//! - `b: u8` — chosen bit-width (1..=32; 0 is unused)
//! - `exc_count: u16 LE` — number of exceptions in this block
//! - packed frame: `block_len * b` bits, transposed/interleaved bit-plane
//!   layout (see below), holding the low `b` bits of every value
//! - exceptions: `exc_count` × (`pos: u16 LE`, `value: u32 LE`)
//!
//! Whole-buffer prefix: `version:u8 = 1` then `delta_count:u32 LE`.
//!
//! # Bit-plane (transposed) layout
//! The `block_len * b` packed bits are laid out one bit-plane at a time, so
//! that all bits of plane 0 come first, then plane 1, etc. Within a plane the
//! bit for value `i` is at bit `i` of that plane. This is the layout TurboPFor
//! uses because it lets a SIMD decoder load contiguous runs of one plane; a
//! scalar decoder reads it back just as easily. We pack planes byte-by-byte,
//! little-endian within each plane (bit 0 of byte 0 is value 0's plane-bit).

const BLOCK: usize = 128;
const VERSION: u8 = 1;

/// Encode a slice of deltas into a self-describing buffer.
pub fn encode(deltas: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + deltas.len() / 2);
    out.push(VERSION);
    out.extend_from_slice(&(deltas.len() as u32).to_le_bytes());

    for chunk in deltas.chunks(BLOCK) {
        encode_block(&mut out, chunk);
    }
    out
}

/// Decode exactly `count` deltas from `buf` (the output of [`encode`]).
pub fn decode(buf: &[u8], count: usize) -> Vec<u32> {
    let mut out = Vec::with_capacity(count);
    if count == 0 {
        return out;
    }
    // Skip version (1B) + delta_count (4B).
    let mut pos = 5usize;
    let mut remaining = count;
    while remaining > 0 {
        let take = remaining.min(BLOCK);
        decode_block(buf, &mut pos, take, &mut out);
        remaining -= take;
    }
    out
}

fn encode_block(out: &mut Vec<u8>, vals: &[u32]) {
    let n = vals.len();
    debug_assert!(n > 0 && n <= BLOCK);

    // Choose b in 1..=32 minimizing cost = n*b + exc_count*32.
    let mut best_b = 32u32;
    let mut best_cost = u64::MAX;
    let mut best_exc = 0usize;
    // Precompute max bit-length needed across the block.
    let mut max_bits = 1u32;
    for &v in vals {
        let bits = if v == 0 { 1 } else { 32 - v.leading_zeros() };
        if bits > max_bits {
            max_bits = bits;
        }
    }
    // Candidate widths to evaluate: 1..=max_bits plus 32 (always a valid fallback).
    let mut bs: Vec<u32> = (1..=max_bits).collect();
    if !bs.contains(&32) {
        bs.push(32);
    }
    for b in bs {
        let mut exc = 0usize;
        for &v in vals {
            // b is at most 32; a u32 right-shift by 32 would overflow, so guard it.
            let needs_more = b < 32 && (v >> b) != 0;
            if needs_more {
                exc += 1;
            }
        }
        let cost = n as u64 * b as u64 + exc as u64 * 32;
        if cost < best_cost {
            best_cost = cost;
            best_b = b;
            best_exc = exc;
        }
    }

    let b = best_b;
    let exc_count = best_exc;

    out.push(b as u8);
    out.extend_from_slice(&(exc_count as u16).to_le_bytes());

    // Packed frame: n*b bits, transposed by bit-plane.
    let total_bits = n * b as usize;
    let frame_bytes = total_bits.div_ceil(8);
    let frame_start = out.len();
    out.resize(frame_start + frame_bytes, 0u8);

    // For each bit-plane p in 0..b, write bit p of each value at position p*n + i.
    for p in 0..b as usize {
        for (i, &v) in vals.iter().enumerate().take(n) {
            let bit = (v >> p) & 1;
            if bit == 1 {
                let bit_index = p * n + i;
                let byte_index = frame_start + bit_index / 8;
                let bit_in_byte = bit_index % 8;
                out[byte_index] |= 1u8 << bit_in_byte;
            }
        }
    }

    // Exceptions: (pos:u16, value:u32) for each value not fitting in b bits.
    for (i, &v) in vals.iter().enumerate() {
        if b < 32 && (v >> b) != 0 {
            out.extend_from_slice(&(i as u16).to_le_bytes());
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
}

fn decode_block(buf: &[u8], pos: &mut usize, n: usize, out: &mut Vec<u32>) {
    let b = buf[*pos] as usize;
    *pos += 1;
    let exc_count = u16::from_le_bytes(buf[*pos..*pos + 2].try_into().unwrap()) as usize;
    *pos += 2;

    let total_bits = n * b;
    let frame_bytes = total_bits.div_ceil(8);
    let frame = &buf[*pos..*pos + frame_bytes];
    *pos += frame_bytes;

    // Reconstruct each value: gather bit p of value i from bit_index p*n + i.
    let mut vals = vec![0u32; n];
    for p in 0..b {
        for (i, val) in vals.iter_mut().enumerate().take(n) {
            let bit_index = p * n + i;
            let bit = (frame[bit_index / 8] >> (bit_index % 8)) & 1;
            if bit == 1 {
                *val |= 1u32 << p;
            }
        }
    }

    // Apply exceptions: overwrite the low-bits value with the full value.
    for _ in 0..exc_count {
        let p = u16::from_le_bytes(buf[*pos..*pos + 2].try_into().unwrap()) as usize;
        *pos += 2;
        let v = u32::from_le_bytes(buf[*pos..*pos + 4].try_into().unwrap());
        *pos += 4;
        vals[p] = v;
    }

    out.extend_from_slice(&vals);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn docids_to_deltas(ids: &[u32]) -> Vec<u32> {
        let mut prev = 0u32;
        let mut out = Vec::with_capacity(ids.len());
        for &d in ids {
            out.push(d - prev);
            prev = d;
        }
        out
    }

    fn check_roundtrip(deltas: &[u32]) {
        let enc = encode(deltas);
        let dec = decode(&enc, deltas.len());
        assert_eq!(dec, deltas, "deltas len={}", deltas.len());
    }

    #[test]
    fn empty() {
        let enc = encode(&[]);
        assert_eq!(enc[0], VERSION);
        let dec = decode(&enc, 0);
        assert!(dec.is_empty());
    }

    #[test]
    fn one() {
        check_roundtrip(&[42]);
        check_roundtrip(&[0]);
        check_roundtrip(&[u32::MAX]);
    }

    #[test]
    fn block_128() {
        // A full block of small, distinct deltas.
        let deltas: Vec<u32> = (1..=128).collect();
        check_roundtrip(&deltas);
    }

    #[test]
    fn block_129() {
        let mut deltas: Vec<u32> = (1..=129).collect();
        // Insert a couple of large exceptions.
        deltas[50] = 1u32 << 30;
        deltas[120] = u32::MAX;
        check_roundtrip(&deltas);
    }

    #[test]
    fn block_300() {
        let mut deltas = Vec::with_capacity(300);
        let mut rng = 12345u32;
        for i in 0..300 {
            // LCG for deterministic pseudo-random deltas.
            rng = rng.wrapping_mul(1664525).wrapping_add(1013904223);
            let d = (rng % (1 << ((i % 20) + 1))).max(1);
            deltas.push(d);
        }
        check_roundtrip(&deltas);
    }

    #[test]
    fn docid_sequence_roundtrip() {
        // Mimic real posting usage: sorted-unique docids delta-encoded.
        let docids: Vec<u32> = vec![0, 1, 2, 5, 9, 200, 1000, 10_000, u32::MAX];
        let deltas = docids_to_deltas(&docids);
        let enc = encode(&deltas);
        let dec = decode(&enc, deltas.len());
        // Prefix-sum back to docids.
        let mut prev = 0u32;
        let mut recovered = Vec::with_capacity(dec.len());
        for d in dec {
            prev += d;
            recovered.push(prev);
        }
        assert_eq!(recovered, docids);
    }
}
