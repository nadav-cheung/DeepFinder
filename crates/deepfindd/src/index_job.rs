// SPDX-License-Identifier: MIT
//! Background index builder. Two entry points share one build + hot-swap path:
//!   - [`spawn_if_missing`]: daemon startup / registry-watch rebuild a
//!     registered DB whose index is absent.
//!   - [`spawn_build`]: on-demand rebuild triggered by `deepfind index` over
//!     the socket (P2.3). Always rebuilds — the freshness skip is client-side.
//!
//! Both build off the hot path, then atomically hot-swap the whole DbSet so
//! in-flight queries (which pin a snapshot via `Arc`) are never interrupted.
//! Live counters are written to the `.indexing` marker so `deepfind status` can
//! report progress (`is_indexing` + [`read_progress`]).

use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;

use df_index::ContentBuildOptions;

use crate::DbSet;

/// Marker file written while a build is in flight (so `deepfind status` can
/// report `indexing` + live progress). Lives beside the DB's index.dfdb.
fn marker(db_path: &Path) -> PathBuf {
    db_path.with_extension("indexing")
}

/// Drop-guard that removes the `.indexing` marker when it goes out of scope —
/// whether the build closure returns `Ok`, returns `Err`, or panics mid-build.
/// Without it, a panic (or thread kill) would leave the marker on disk and
/// `deepfind status` would report `indexing` forever (holistic-review I2).
struct MarkerGuard<'a>(&'a Path);

impl Drop for MarkerGuard<'_> {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0);
    }
}

/// Progress-reporter tick (sleep granularity so it notices `stop` quickly).
const PROGRESS_TICK: Duration = Duration::from_millis(10);
/// Write a progress snapshot every this many ticks (25 × 10ms = 250ms).
const PROGRESS_INTERVAL_TICKS: u32 = 25;

/// Build `root` → `db_path`/`content_dir` in the background, then reload the
/// whole DbSet from disk and atomically swap it in. Returns `false` (without
/// spawning) if a build for `db_path` is already in flight — the `.indexing`
/// marker is the atomic guard (`create_new`), so two concurrent builds of the
/// same DB can never interleave shard writes. Errors are logged; the daemon
/// keeps serving whatever it had.
///
/// On success the freshly-built DB is **also attached to df-watch** (when
/// enabled): watchers attach only to DBs that had an index when their loop
/// started, so a DB that was just built would otherwise never be watched
/// (holistic-review I1).
pub(crate) fn spawn_build(
    root: PathBuf,
    db_path: PathBuf,
    content_dir: PathBuf,
    opts: ContentBuildOptions,
    dbset: Arc<ArcSwap<DbSet>>,
    default_db_path: PathBuf,
) -> bool {
    let marker_path = marker(&db_path);
    // Ensure the DB's directory exists (first-time named-DB builds have no dir
    // yet); best-effort — the build itself also creates the content dir.
    if let Some(parent) = marker_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Atomic guard: create_new succeeds for exactly one winner. AlreadyExists ⇒
    // another build holds the marker; don't start a second.
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&marker_path)
    {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return false,
        Err(e) => {
            tracing::warn!(error = %e, db = ?db_path, "index_job: cannot create marker");
            return false;
        }
    }

    std::thread::spawn(move || {
        let _guard = MarkerGuard(marker_path.as_path());
        tracing::info!(root = ?root, "background-indexing");

        let progress = Arc::new(df_index::IndexProgress::default());
        // Reporter: periodically snapshot the counters into the marker file so
        // `deepfind status` can show live progress. Stops when `stop` is set.
        let stop = Arc::new(AtomicBool::new(false));
        let reporter = {
            let progress = Arc::clone(&progress);
            let stop = Arc::clone(&stop);
            let marker_path = marker_path.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let snap = progress.snapshot();
                    let line = format!(
                        "{} files · {:.1} MB · {} shards",
                        snap.files_scanned,
                        snap.content_bytes as f64 / 1_048_576.0,
                        snap.shards_written
                    );
                    let _ = std::fs::write(&marker_path, line);
                    for _ in 0..PROGRESS_INTERVAL_TICKS {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        std::thread::sleep(PROGRESS_TICK);
                    }
                }
            })
        };

        let res = df_index::build_content_index_with_progress(
            &root,
            &db_path,
            &content_dir,
            &opts,
            Arc::clone(&progress),
        );
        // Stop the reporter before the swap so status never shows mid-swap
        // progress; the MarkerGuard removes the marker on drop.
        stop.store(true, Ordering::Relaxed);
        let _ = reporter.join();

        match res {
            Ok(_) => {
                dbset.store(Arc::new(DbSet::open(&default_db_path)));
                tracing::info!(root = ?root, "background-indexing complete; DbSet hot-swapped");
                // Attach df-watch to the freshly-built DB (only when the env
                // gate is set, mirroring serve()'s startup loop). The entry is
                // found by matching `db_path` in the post-swap snapshot; the
                // watcher shares this entry's `Arc<ContentShards>`, so its
                // `rebuild_and_swap` → `shards.reload()` updates the same shards
                // queries read.
                if std::env::var("DEEPFIND_WATCH").is_ok() {
                    let snap = dbset.load_full();
                    if let Some(entry) = snap.entries.iter().find(|e| e.db_path == db_path) {
                        if let Some(watch_root) = &entry.root {
                            crate::watch::spawn(
                                watch_root.clone(),
                                entry.db_path.clone(),
                                entry.shards.content_dir().to_path_buf(),
                                entry.shards.clone(),
                            );
                        }
                    }
                }
            }
            Err(e) => tracing::warn!(error = %e, root = ?root, "background-indexing failed"),
        }
    });
    true
}

/// Build a registered DB whose index is missing (daemon startup /
/// registry-watch). No-op (returns without spawning) if `db_path` already
/// exists. Thin wrapper over [`spawn_build`] with default options.
pub(crate) fn spawn_if_missing(
    root: PathBuf,
    db_path: PathBuf,
    content_dir: PathBuf,
    dbset: Arc<ArcSwap<DbSet>>,
    default_db_path: PathBuf,
) {
    if db_path.is_file() {
        return;
    }
    spawn_build(
        root,
        db_path,
        content_dir,
        ContentBuildOptions::default(),
        dbset,
        default_db_path,
    );
}

/// True while a build for `db_path` is in flight (used by `deepfind status`).
pub fn is_indexing(db_path: &Path) -> bool {
    marker(db_path).exists()
}

/// Live progress line for an in-flight build of `db_path` (written to the
/// marker by the reporter), or `None` if no marker / empty / unreadable. Used
/// by `deepfind status` to show files / MB / shards while indexing.
pub fn read_progress(db_path: &Path) -> Option<String> {
    let s = String::from_utf8(std::fs::read(marker(db_path)).ok()?).ok()?;
    let s = s.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_progress_none_without_marker() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        assert!(read_progress(&db).is_none());
    }

    #[test]
    fn read_progress_none_when_marker_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(marker(&db), b"").unwrap();
        assert!(read_progress(&db).is_none());
    }

    #[test]
    fn read_progress_some_when_marker_has_content() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(
            marker(&db),
            b"  123 files \xc2\xb7 0.5 MB \xc2\xb7 1 shards  ",
        )
        .unwrap();
        assert_eq!(
            read_progress(&db).as_deref(),
            Some("123 files · 0.5 MB · 1 shards")
        );
    }

    #[test]
    fn spawn_build_rejects_when_marker_present() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        let db = tmp.path().join("index.dfdb");
        // Pre-create the marker ⇒ spawn_build must refuse without spawning.
        std::fs::write(marker(&db), b"busy").unwrap();
        let dbset = Arc::new(ArcSwap::from_pointee(DbSet::open(&db)));
        let accepted = spawn_build(
            root,
            db.clone(),
            tmp.path().join("content"),
            ContentBuildOptions::default(),
            dbset,
            db,
        );
        assert!(!accepted, "spawn_build must reject when marker present");
    }
}
