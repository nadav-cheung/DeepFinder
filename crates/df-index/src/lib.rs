// SPDX-License-Identifier: MIT
//! df-index — indexer: `ignore` parallel traversal → build DB → atomic write.
//!
//! Also provides [`FileSource`], a pread-backed [`DbSource`] for low-RSS reads
//! (used by the daemon in Step 4).

use std::error::Error;
use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use df_core::db::DbBuilder;
use df_core::DbSource;
use ignore::{WalkBuilder, WalkState};

pub mod error;

pub use error::{IndexError, Result};

/// Default skip-list (on top of `.gitignore` + hidden), per REVIEW §8.1 #3.
pub const DEFAULT_SKIP: &[&str] = &[
    "node_modules",
    "target",
    "build",
    "dist",
    ".next",
    "__pycache__",
    ".venv",
];

/// A collected path plus the per-file metadata stored in the DB META section.
#[derive(Debug)]
struct DocRec {
    path: String,
    is_dir: bool,
    size: i64,
    mtime: i64,
}

/// Outcome of an index build: indexed doc count plus permission-denied entries.
#[derive(Debug, Clone, Copy)]
pub struct IndexReport {
    pub docs: u32,
    pub denied: u32,
}

/// Build (or rebuild) the index DB for `root` with the default skip-list,
/// writing atomically to `out_db`. Returns the number of indexed entries.
pub fn build_index(root: &Path, out_db: &Path) -> Result<u32> {
    Ok(build_index_report(root, out_db, &[])?.docs)
}

/// Like [`build_index`] but with `extra_skip` directory names pruned in addition
/// to [`DEFAULT_SKIP`] (REVIEW §8.1 #3: configurable skip-list). Extras are
/// deduped against the defaults.
pub fn build_index_with(root: &Path, out_db: &Path, extra_skip: &[String]) -> Result<u32> {
    Ok(build_index_report(root, out_db, extra_skip)?.docs)
}

/// Build and return a full [`IndexReport`] (doc count + permission-denied count
/// — the latter drives Full Disk Access guidance, REVIEW §8.2).
pub fn build_index_report(
    root: &Path,
    out_db: &Path,
    extra_skip: &[String],
) -> Result<IndexReport> {
    let mut skip: Vec<&str> = DEFAULT_SKIP.to_vec();
    for e in extra_skip {
        if !e.is_empty() && !skip.contains(&e.as_str()) {
            skip.push(e.as_str());
        }
    }
    let (recs, denied) = collect_records(root, &skip)?;
    let mut builder = DbBuilder::new();
    builder.set_build_time(now_secs());
    for r in &recs {
        builder.insert_with(&r.path, r.is_dir, r.size, r.mtime);
    }
    let docs = builder.doc_count();
    let bytes = builder.finish();
    atomic_write(out_db, &bytes)?;
    Ok(IndexReport { docs, denied })
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// True if the error chain contains a permission-denied I/O error (macOS TCC
/// denials surface as EPERM/EACCES → `PermissionDenied`).
fn is_permission_denied(e: &ignore::Error) -> bool {
    let mut cur: Option<&(dyn Error + 'static)> = Some(e);
    while let Some(c) = cur {
        if let Some(io) = c.downcast_ref::<io::Error>() {
            if io.kind() == io::ErrorKind::PermissionDenied {
                return true;
            }
        }
        cur = c.source();
    }
    false
}

/// Walk `root` in parallel (gitignore + hidden + `skip` dir names), returning
/// sorted-unique, valid-UTF-8 records with per-file metadata, plus a count of
/// permission-denied entries (FDA signal).
fn collect_records(root: &Path, skip: &[&str]) -> Result<(Vec<DocRec>, u32)> {
    let mut walker = WalkBuilder::new(root);
    walker.standard_filters(true).hidden(true);

    let collected: Arc<Mutex<Vec<DocRec>>> = Arc::new(Mutex::new(Vec::new()));
    let denied: Arc<AtomicU32> = Arc::new(AtomicU32::new(0));
    let sink = collected.clone();
    let denied_c = denied.clone();
    walker.build_parallel().run(move || {
        let sink = sink.clone();
        let denied_c = denied_c.clone();
        Box::new(move |result| {
            let entry = match result {
                Ok(e) => e,
                Err(e) => {
                    if is_permission_denied(&e) {
                        denied_c.fetch_add(1, Ordering::Relaxed);
                    }
                    return WalkState::Continue;
                }
            };
            // Prune build/cache dirs (don't descend), per REVIEW §8.1 #3.
            let name = entry.file_name().to_string_lossy();
            if entry.file_type().is_some_and(|t| t.is_dir())
                && skip.iter().any(|s| name == *s)
            {
                return WalkState::Skip;
            }
            if let Some(s) = entry.path().to_str() {
                let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
                let (size, mtime) = match entry.metadata() {
                    Ok(md) => (
                        md.len() as i64,
                        md.modified()
                            .ok()
                            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                            .map(|d| d.as_secs() as i64)
                            .unwrap_or(0),
                    ),
                    Err(_) => (0, 0),
                };
                sink.lock()
                    .expect("collector lock poisoned")
                    .push(DocRec {
                        path: s.to_string(),
                        is_dir,
                        size,
                        mtime,
                    });
            }
            WalkState::Continue
        })
    });

    let mut recs = Arc::try_unwrap(collected)
        .expect("walker threads did not release the collector")
        .into_inner()
        .expect("collector lock poisoned");
    recs.sort_by(|a, b| a.path.cmp(&b.path));
    recs.dedup_by(|a, b| a.path == b.path);
    let denied = denied.load(Ordering::Relaxed);
    Ok((recs, denied))
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
