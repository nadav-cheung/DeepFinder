// SPDX-License-Identifier: MIT
//! Protocol messages (serde + bincode on the wire; framing added in Step 3).

use std::path::PathBuf;

use df_core::LiteMeta;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchRequest {
    pub query: String,
    /// Restrict search to a subtree.
    pub scope: Option<PathBuf>,
    pub limit: Option<u32>,
    pub opts: SearchOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchOptions {
    /// Force online `--direct` scan (skip the daemon/index).
    pub direct: bool,
}

/// One frame of the streamed response. The daemon sends `Batch`* then exactly
/// one terminal `Done` (or `Error`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ResponseFrame {
    Batch {
        paths: Vec<String>,
        meta: Vec<LiteMeta>,
    },
    Done {
        total: u32,
    },
    Error {
        message: String,
    },
}
