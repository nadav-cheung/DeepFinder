// SPDX-License-Identifier: MIT
//! mmap-backed [`DbSource`] (MAP_SHARED, read-only). The content daemon holds
//! these for the process lifetime. Shards are write-once and replaced by atomic
//! rename on rebuild, never mutated in place.

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
        // SAFETY: a MAP_SHARED read-only mapping is sound as long as the file's
        // length does not decrease and its contents are not hole-punched for the
        // lifetime of every `&[u8]` borrowed from `as_slice` — otherwise reads
        // of the now-unmapped pages SIGBUS. The daemon upholds this: shards are
        // write-once at build, and a rebuild writes NEW files + swaps the
        // ShardSet atomically; the mapped file is never truncated/ftruncate'd.
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
