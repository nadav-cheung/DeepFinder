// SPDX-License-Identifier: MIT
//! df-index — indexer: `ignore` parallel traversal → build DB → atomic write.
//!
//! Also provides [`FileSource`], a pread-backed [`DbSource`] for low-RSS reads
//! (used by the daemon in Step 4).

use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::{Arc, Mutex};

use df_core::db::DbBuilder;
use df_core::DbSource;
use ignore::{WalkBuilder, WalkState};

pub mod error;

pub use error::{IndexError, Result};

/// Default skip-list (on top of `.gitignore` + hidden), per REVIEW §8.1 #3.
const DEFAULT_SKIP: &[&str] = &[
    "node_modules",
    "target",
    "build",
    "dist",
    ".next",
    "__pycache__",
    ".venv",
];

/// Build (or rebuild) the index DB for `root`, writing atomically to `out_db`
/// (tmp → fsync → rename). Returns the number of indexed entries.
pub fn build_index(root: &Path, out_db: &Path) -> Result<u32> {
    let paths = collect_paths(root)?;
    let mut builder = DbBuilder::new();
    for p in &paths {
        builder.insert(p);
    }
    let count = builder.doc_count();
    let bytes = builder.finish();
    atomic_write(out_db, &bytes)?;
    Ok(count)
}

/// Walk `root` in parallel (gitignore + hidden + default skip-list), returning
/// sorted-unique, valid-UTF-8 path strings.
fn collect_paths(root: &Path) -> Result<Vec<String>> {
    let mut walker = WalkBuilder::new(root);
    walker.standard_filters(true).hidden(true);

    let collected: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let sink = collected.clone();
    walker.build_parallel().run(move || {
        let sink = sink.clone();
        Box::new(move |result| {
            let entry = match result {
                Ok(e) => e,
                Err(_) => return WalkState::Continue,
            };
            // Prune build/cache dirs (don't descend), per REVIEW §8.1 #3.
            let name = entry.file_name().to_string_lossy();
            if entry.file_type().is_some_and(|t| t.is_dir())
                && DEFAULT_SKIP.iter().any(|s| name == *s)
            {
                return WalkState::Skip;
            }
            if let Some(s) = entry.path().to_str() {
                sink.lock()
                    .expect("collector lock poisoned")
                    .push(s.to_string());
            }
            WalkState::Continue
        })
    });

    let mut paths = Arc::try_unwrap(collected)
        .expect("walker threads did not release the collector")
        .into_inner()
        .expect("collector lock poisoned");
    paths.sort();
    paths.dedup();
    Ok(paths)
}

/// Write `data` to `path` atomically: create parent, write `<name>.tmp`, fsync,
/// rename over the target.
fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let file_name = path.file_name().ok_or_else(|| {
        IndexError::Io(io::Error::new(
            io::ErrorKind::InvalidInput,
            "out_db has no file name",
        ))
    })?;
    let tmp = path.with_file_name(format!("{}.tmp", file_name.to_string_lossy()));
    {
        let mut f = File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// File-backed [`DbSource`] using `pread` (`FileExt::read_at`). Low RSS: the
/// daemon never mmaps or holds the whole DB.
pub struct FileSource(File);

impl FileSource {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self(File::open(path)?))
    }
}

impl DbSource for FileSource {
    fn read_at(&self, off: u64, len: usize) -> io::Result<Vec<u8>> {
        let mut buf = vec![0u8; len];
        let mut read = 0usize;
        while read < len {
            let n = self.0.read_at(&mut buf[read..], off + read as u64)?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "pread hit EOF before filling request",
                ));
            }
            read += n;
        }
        Ok(buf)
    }
}
