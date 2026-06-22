// SPDX-License-Identifier: MIT
use thiserror::Error;

pub type Result<T> = std::result::Result<T, IndexError>;

#[derive(Debug, Error)]
pub enum IndexError {
    #[error("not implemented yet: {0}")]
    NotImplemented(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
