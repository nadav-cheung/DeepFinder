// SPDX-License-Identifier: MIT
use thiserror::Error;

pub type Result<T> = std::result::Result<T, IndexError>;

#[derive(Debug, Error)]
pub enum IndexError {
    #[error("index io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("index error: {0}")]
    Other(String),
}
