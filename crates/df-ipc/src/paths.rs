// SPDX-License-Identifier: MIT
//! Default runtime paths (Docker-style dot-dir under `$HOME`).

use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
}

/// Root data directory: `~/.deep-find`.
pub fn data_dir() -> PathBuf {
    home().join(".deep-find")
}

/// Unix domain socket: `~/.deep-find/daemon.sock`.
pub fn default_socket() -> PathBuf {
    data_dir().join("daemon.sock")
}

/// Default index DB: `~/.deep-find/db/index.dfdb`.
pub fn default_db() -> PathBuf {
    data_dir().join("db").join("index.dfdb")
}
