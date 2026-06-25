// SPDX-License-Identifier: MIT
//! df-ipc — Unix-domain-socket protocol: length-framed request + streamed response.
//!
//! Messages ([`crate::proto`]) are bincode-encoded; the transport wraps a duplex
//! stream with [`tokio_util::codec::LengthDelimitedCodec`] (4-byte prefix) via
//! [`framed`]. The daemon sends a sequence of `ResponseFrame`s (Batch* then Done).

pub mod bfs;
pub mod error;
pub mod filter;
pub mod paths;
pub mod proto;
pub mod wire;

pub use error::{IpcError, Result};
pub use paths::{data_dir, default_db, default_socket, home};
pub use proto::{IndexRequest, MatchKind, Request, ResponseFrame, SearchOptions, SearchRequest};
pub use wire::{
    decode_frame, decode_request, encode_frame, encode_index_request, encode_request, framed,
};
