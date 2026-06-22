// SPDX-License-Identifier: MIT
use thiserror::Error;

pub type Result<T> = std::result::Result<T, IpcError>;

#[derive(Debug, Error)]
pub enum IpcError {
    #[error("ipc error: {0}")]
    Other(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
