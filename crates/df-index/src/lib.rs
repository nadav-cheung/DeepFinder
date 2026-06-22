// SPDX-License-Identifier: MIT
//! df-index — indexer: `ignore` parallel traversal → build DB → atomic write.
//!
//! Stub scaffold; traversal + df-core serialization land in Step 2.

use std::path::Path;

pub mod error;

pub use error::{IndexError, Result};

/// Build (or rebuild) the index DB for `root`, writing atomically to `out_db`
/// (tmp → fsync → rename).
///
/// TODO(step2): `ignore::WalkParallel` traversal + file-level trigram extraction
/// + df-core serialization (TurboPFor postings, Robin Hood table, zstd blocks).
pub fn build_index(_root: &Path, _out_db: &Path) -> Result<()> {
    Err(IndexError::NotImplemented("build_index".into()))
}
