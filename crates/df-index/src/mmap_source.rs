// SPDX-License-Identifier-Identifier: MIT
//! mmap-backed [`DbSource`] (MAP_SHARED, read-only). The content daemon holds
//! these for the process lifetime; shards are write-once so there is no
//! SIGBUS-from-write risk.

use std::fs::File;
use std::io;
use std::path::Path;

use df_core::DbSource;

/// Owns the `File` (kept alive) + its read-only mmap.
pub struct MmapSource {
    _file: File,
    mmap: memmap2::Mmap,
}

impl MmapSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        // SAFETY: map after open; the file is treated as immutable for the
        // mapping's lifetime (shards are write-once; rebuilds swap files).
        let mmap = unsafe { memmap2::Mmap::map(&file) }?;
        Ok(Self { _file: file, mmap })
    }

    /// Borrow the underlying bytes (zero-copy).
    pub fn as_slice(&self) -> &[u8] {
        &self.mmap[..]
    }
}

impl DbSource for MmapSource {
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>> {
        let start = usize::try_from(off)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "offset overflow"))?;
        let end = start
            .checked_add(len)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "len overflow"))?;
        if end > self.mmap.len() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "read past mmap end",
            ));
        }
        Ok(self.mmap[start..end].to_vec())
    }
}
