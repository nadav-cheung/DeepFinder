// SPDX-License-Identifier: MIT
//! Adversarial edge-case roundtrip tests for the TurboPFor codec.
//!
//! Each case asserts `decode(encode(d), d.len()) == d`. Run with:
//!   cargo test -p df-core --test turbopfor_edges

use df_core::turbopfor::{decode, encode};

/// Assert a full roundtrip and report the failing case on mismatch.
fn roundtrip(label: &str, d: &[u32]) {
    let enc = encode(d);
    let dec = decode(&enc, d.len());
    assert_eq!(dec, d, "roundtrip failed for {label} (len={})", d.len());
}

#[test]
fn empty_slice() {
    let d: Vec<u32> = vec![];
    roundtrip("empty", &d);
    // Header only: version (1B) + delta_count (4B) = 5 bytes.
    let enc = encode(&d);
    assert!(
        enc.len() <= 8,
        "encode([]) should be header-only (<=8B), got {}",
        enc.len()
    );
    // Decoding an empty buffer must yield [].
    let dec = decode(&enc, 0);
    assert!(dec.is_empty(), "decode(encode([]), 0) must be empty");
}

#[test]
fn single_zero() {
    roundtrip("single [0]", &[0]);
}

#[test]
fn single_one() {
    roundtrip("single [1]", &[1]);
}

#[test]
fn single_u32_max() {
    roundtrip("single [u32::MAX]", &[u32::MAX]);
}

#[test]
fn full_block_u32_max() {
    // 128 values all at the maximum — forces b=32, zero exceptions.
    let d = vec![u32::MAX; 128];
    roundtrip("128x u32::MAX", &d);
}

#[test]
fn full_block_zeros() {
    // 128 zeros — b=1, zero exceptions.
    let d = vec![0u32; 128];
    roundtrip("128x 0", &d);
}

#[test]
fn block_129_zeros() {
    // Straddles a block boundary: 128 + 1.
    let d = vec![0u32; 129];
    roundtrip("129x 0", &d);
}

#[test]
fn block_every_value_exception() {
    // A full block where EVERY value is an exception (distinct, >= 1<<28),
    // so none fit in any b < 32 and all must be stored as exceptions.
    let d: Vec<u32> = (0..128u32).map(|i| (1u32 << 28) + i).collect();
    roundtrip("128 all-exceptions (distinct, >= 1<<28)", &d);
}

#[test]
fn block_exactly_one_exception() {
    // 127 small values that fit in b, plus one value that forces an exception.
    let mut d: Vec<u32> = vec![1u32; 127];
    d.push(u32::MAX);
    assert_eq!(d.len(), 128);
    roundtrip("128 with exactly one exception", &d);
}

#[test]
fn block_alternating_tiny_huge() {
    // 128 values alternating between tiny (1) and huge (u32::MAX).
    // Stresses exception packing under a non-contiguous layout.
    let d: Vec<u32> = (0..128)
        .map(|i| if i % 2 == 0 { 1 } else { u32::MAX })
        .collect();
    assert_eq!(d.len(), 128);
    roundtrip("128 alternating tiny/huge", &d);
}

#[test]
fn seq_255() {
    // 255 sequential values — two blocks: full 128 + remainder 127.
    let d: Vec<u32> = (1..=255).collect();
    assert_eq!(d.len(), 255);
    roundtrip("255 sequential", &d);
}

#[test]
fn powers_of_two_256() {
    // 256 powers of two — every value is a single-bit value; the block
    // includes values from 1<<0 up to 1<<255 (wrapping u32), covering all
    // bit widths across two blocks.
    let d: Vec<u32> = (0..256).map(|i| 1u32.wrapping_shl(i % 32)).collect();
    assert_eq!(d.len(), 256);
    roundtrip("256 powers of two", &d);
}
