// SPDX-License-Identifier: MIT
//! df-content — content substring index: mmap-able `.dfcs` shard builder/reader
//! + substring verify. Pure over borrowed byte slices (the daemon owns the mmap
//!   and lends `&[u8]`). No filesystem I/O of its own.

pub mod fold;
pub mod regex_query;
pub mod shard;

pub use shard::{ShardBuilder, ShardReader};
