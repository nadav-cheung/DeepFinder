// SPDX-License-Identifier: MIT
//! WAL persistence for the hot overlay ([`df_content::Overlay`]). The daemon
//! appends one [`WalRecord`] per changed file (serialized under a `Mutex`),
//! fsyncs at batch / compaction boundaries, and truncates when a compaction
//! subsumes the log. Startup recovery = read the file + `decode_records`.
//!
//! This is the only place the overlay touches the filesystem; the pure overlay
//! logic lives in `df-content`.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use df_content::{decode_records, encode_record, WalRecord};

use crate::{IndexError, Result};

/// Append-only WAL backing one DB's overlay. One per `DbEntry`.
pub struct OverlayStore {
    path: PathBuf,
    file: Mutex<File>,
}

impl OverlayStore {
    /// Open (creating if absent) the WAL at `path`.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .read(true)
            .open(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            file: Mutex::new(file),
        })
    }

    /// Append a record. Not fsynced — call [`OverlayStore::sync`] at the end of
    /// a debounced batch (crash loses at most one batch window; the safety-net
    /// rebuild backstops it).
    pub fn append(&self, rec: &WalRecord) -> Result<()> {
        let bytes = encode_record(rec).map_err(|e| IndexError::Other(e.to_string()))?;
        let mut f = self.file.lock().expect("overlay store lock poisoned");
        f.write_all(&bytes)?;
        Ok(())
    }

    /// Flush + fsync the WAL (durability at batch / compaction boundaries).
    pub fn sync(&self) -> Result<()> {
        let mut f = self.file.lock().expect("overlay store lock poisoned");
        f.flush()?;
        f.sync_data()?;
        Ok(())
    }

    /// Truncate the WAL to empty (after a compaction rebuild subsumes it).
    pub fn truncate(&self) -> Result<()> {
        let mut f = self.file.lock().expect("overlay store lock poisoned");
        f.set_len(0)?;
        f.seek(SeekFrom::Start(0))?;
        Ok(())
    }

    /// WAL file path (status / diagnostics).
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Read + decode a WAL file into replay records (startup recovery). A missing
/// file is an empty replay (fresh overlay, no changes since the last compaction).
pub fn replay(path: &Path) -> Result<Vec<WalRecord>> {
    let mut f = match File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    let mut bytes = Vec::new();
    f.read_to_end(&mut bytes)?;
    Ok(decode_records(&bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use df_content::Overlay;
    use df_core::LiteMeta;
    use tempfile::tempdir;

    fn upsert(path: &str, content: &str) -> WalRecord {
        WalRecord::Upsert {
            path: path.to_string(),
            meta: LiteMeta {
                is_dir: false,
                size: content.len() as i64,
                mtime: 0,
            },
            content: Some(content.as_bytes().to_vec()),
        }
    }

    #[test]
    fn append_and_replay_roundtrip() {
        let tmp = tempdir().unwrap();
        let wal = tmp.path().join("overlay.wal");
        let store = OverlayStore::open(&wal).unwrap();
        store.append(&upsert("/a.txt", "hello")).unwrap();
        store.append(&upsert("/b.txt", "world")).unwrap();
        store.sync().unwrap();

        let recs = replay(&wal).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[0], upsert("/a.txt", "hello"));
        assert_eq!(recs[1], upsert("/b.txt", "world"));
    }

    #[test]
    fn replay_missing_file_is_empty() {
        let tmp = tempdir().unwrap();
        let recs = replay(&tmp.path().join("nope.wal")).unwrap();
        assert!(recs.is_empty());
    }

    #[test]
    fn truncate_clears_wal() {
        let tmp = tempdir().unwrap();
        let wal = tmp.path().join("overlay.wal");
        let store = OverlayStore::open(&wal).unwrap();
        store.append(&upsert("/a.txt", "hello")).unwrap();
        store.sync().unwrap();
        assert_eq!(replay(&wal).unwrap().len(), 1);

        store.truncate().unwrap();
        assert!(replay(&wal).unwrap().is_empty());
        // appends after truncate start fresh
        store.append(&upsert("/c.txt", "again")).unwrap();
        let recs = replay(&wal).unwrap();
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0], upsert("/c.txt", "again"));
    }

    #[test]
    fn replay_preserves_order_and_applies_to_overlay() {
        let tmp = tempdir().unwrap();
        let wal = tmp.path().join("overlay.wal");
        let store = OverlayStore::open(&wal).unwrap();
        store.append(&upsert("/a.txt", "hello world")).unwrap();
        store.append(&upsert("/a.txt", "goodbye")).unwrap(); // replace
        let _ = store.append(&WalRecord::Delete {
            path: "/b.txt".to_string(),
        });
        store.sync().unwrap();

        let recs = replay(&wal).unwrap();
        assert_eq!(recs.len(), 3);
        // Applying the replayed stream yields the expected overlay state.
        let mut o = Overlay::default();
        o.apply_records(&recs);
        assert!(o.content_query(b"hello", b"hello", false, None).is_empty());
        assert_eq!(
            o.content_query(b"goodbye", b"goodbye", false, None).len(),
            1
        );
        assert!(o.tombstones().contains("/b.txt"));
    }

    #[test]
    fn append_without_sync_is_readable_in_process() {
        // write_all lands in the kernel page cache; a same-process read sees it
        // even without fsync. (Cross-crash durability is backstopped elsewhere.)
        let tmp = tempdir().unwrap();
        let wal = tmp.path().join("overlay.wal");
        let store = OverlayStore::open(&wal).unwrap();
        store.append(&upsert("/a.txt", "hello")).unwrap();
        assert_eq!(replay(&wal).unwrap().len(), 1);
    }
}
