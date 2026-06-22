// SPDX-License-Identifier: MIT
//! df-ipc — Unix-domain-socket protocol: length-framed request + streamed response.
//!
//! Stub scaffold; wire framing lands in Step 3.

pub mod error;
pub mod proto;

pub use error::{IpcError, Result};
pub use proto::{ResponseFrame, SearchOptions, SearchRequest};
