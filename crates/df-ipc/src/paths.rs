// SPDX-License-Identifier: MIT
//! Default runtime paths (Docker-style dot-dir under `$HOME`).

use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
}

/// Root data directory: `~/.deep-finder`.
pub fn data_dir() -> PathBuf {
    home().join(".deep-finder")
}

/// Unix domain socket: `~/.deep-finder/daemon.sock`.
pub fn default_socket() -> PathBuf {
    data_dir().join("daemon.sock")
}

/// Default index DB: `~/.deep-finder/db/index.dfdb`.
pub fn default_db() -> PathBuf {
    data_dir().join("db").join("index.dfdb")
}
