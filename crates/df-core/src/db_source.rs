// SPDX-License-Identifier: MIT
//! Byte-range reader over an indexed DB.

use std::io;

/// Read a byte range from the indexed DB. Implementations:
/// - daemon: `&File` + `pread` — never holds the whole DB (low RSS, plocate-style)
/// - tests: `&[u8]` (in-memory)
pub trait DbSource {
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>>;
}

impl DbSource for &[u8] {
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>> {
        let start = usize::try_from(off)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "offset overflow"))?;
        let end = start
            .checked_add(len)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "len overflow"))?;
        if end > self.len() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "read beyond DB end",
            ));
        }
        Ok(self[start..end].to_vec())
    }
}
