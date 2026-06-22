// SPDX-License-Identifier: MIT
//! Shared result metadata (used by df-ipc response frames).

use serde::{Deserialize, Serialize};

/// Lightweight per-file metadata returned with each match.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LiteMeta {
    pub is_dir: bool,
    pub size: i64,
    /// Modification time, unix seconds.
    pub mtime: i64,
}
