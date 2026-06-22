// SPDX-License-Identifier: MIT
use thiserror::Error;

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("DB format error: {0}")]
    DbFormat(String),
    #[error("codec error: {0}")]
    Codec(String),
    #[error("query error: {0}")]
    Query(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
