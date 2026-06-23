// SPDX-License-Identifier: MIT
//! Protocol messages (serde + bincode on the wire; framing added in Step 3).

use std::path::PathBuf;

use df_core::LiteMeta;
use serde::{Deserialize, Serialize};

/// How a result matched: by filename, content, or both.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum MatchKind {
    Filename,
    Content,
    Both,
}

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
    #[serde(default)]
    pub direct: bool,
    /// `-e`: keep only these extensions (no leading dot), e.g. ["rs","md"].
    #[serde(default)]
    pub extensions: Vec<String>,
    /// `-t`: keep only these type categories, e.g. ["code","docs"].
    #[serde(default)]
    pub types: Vec<String>,
    /// `-E`: exclude glob patterns (matched against the full path).
    #[serde(default)]
    pub excludes: Vec<String>,
}

/// One frame of the streamed response. The daemon sends `Batch`* then exactly
/// one terminal `Done` (or `Error`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ResponseFrame {
    Batch {
        paths: Vec<String>,
        meta: Vec<LiteMeta>,
        kind: Vec<MatchKind>,
    },
    Done {
        total: u32,
    },
    Error {
        message: String,
    },
}
