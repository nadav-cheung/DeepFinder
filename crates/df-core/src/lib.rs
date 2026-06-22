// SPDX-License-Identifier: MIT
//! df-core — pure trigram-index DB format, TurboPFor codec, and query algorithm.
//!
//! Purity rule (REVIEW §5 / §7.0): this crate performs NO filesystem or network
//! I/O. All query and codec logic operates against the [`DbSource`] trait, which
//! callers implement — `&File` + pread in the daemon (low RSS), or `&[u8]` in
//! tests. This keeps the engine unit-testable and benchmarkable without a real
//! DB on disk.

pub mod boolquery;
pub mod db;
pub mod db_source;
pub mod error;
pub mod meta;
pub mod query;
pub mod trigram;
pub mod turbopfor;
pub mod varint;

pub use db::{DbBuilder, DbReader};
pub use db_source::DbSource;
pub use error::{CoreError, Result};
pub use meta::LiteMeta;
pub use query::query;
