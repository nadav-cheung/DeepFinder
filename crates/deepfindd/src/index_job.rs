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
//!
//! **Concurrency:** [`try_acquire`] is the single atomic guard (`create_new` on
//! the marker) used by `spawn_build`, df-watch's `compact_and_swap`, and the
//! safety-net's `rebuild_and_swap`, so two builds of the same DB — on-demand vs
//! df-watch vs safety-net vs startup — can never interleave writes to the same
//! shard names. A daemon killed mid-build
//! (SIGKILL) leaks the marker; [`sweep_stale_markers`] at startup recovers it.

use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;

use df_index::ContentBuildOptions;

use crate::DbSet;

/// The `.indexing` marker file written beside a DB's index.dfdb while a build is
/// in flight (so `deepfind status` can report `indexing` + live progress).
fn marker(db_path: &Path) -> PathBuf {
    db_path.with_extension("indexing")
}

/// Drop-guard that removes the `.indexing` marker when dropped — whether the
/// build returns `Ok`, `Err`, or panics. Owns its path so it is `Send` and can
/// be moved into a worker thread. (A process SIGKILL still leaks the marker;
/// [`sweep_stale_markers`] at daemon startup recovers those.)
pub(crate) struct MarkerGuard {
    path: PathBuf,
}

impl Drop for MarkerGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Atomically acquire the build marker for `db_path` (`OpenOptions::create_new`
/// ⇒ exactly one winner). Returns a [`MarkerGuard`] whose `Drop` removes the
/// marker, or `None` if a build is already in flight (or the marker can't be
/// created) — so two builds of the same DB never run concurrently. Used by
/// [`spawn_build`] (on-demand / startup), df-watch's `compact_and_swap`, and the
/// safety-net's `rebuild_and_swap`.
pub(crate) fn try_acquire(db_path: &Path) -> Option<MarkerGuard> {
    let m = marker(db_path);
    if let Some(parent) = m.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    match OpenOptions::new().write(true).create_new(true).open(&m) {
        Ok(_) => Some(MarkerGuard { path: m }),
        Err(_) => None,
    }
}

/// Remove leftover `.indexing` markers under `db_dir` from a previous daemon
/// killed mid-build. Call at daemon startup, where no build is in flight in this
/// process — so any marker on disk is stale. Leaves non-marker files untouched.
pub fn sweep_stale_markers(db_dir: &Path) {
    for entry in std::fs::read_dir(db_dir).into_iter().flatten().flatten() {
        let p = entry.path();
        if p.is_dir() {
            for inner in std::fs::read_dir(&p).into_iter().flatten().flatten() {
                let ip = inner.path();
                if is_marker(&ip) {
                    let _ = std::fs::remove_file(&ip);
                }
            }
        } else if is_marker(&p) {
            let _ = std::fs::remove_file(&p);
        }
    }
}

fn is_marker(p: &Path) -> bool {
    p.extension().is_some_and(|x| x == "indexing")
}

/// Progress-reporter tick (sleep granularity so it notices `stop` quickly).
const PROGRESS_TICK: Duration = Duration::from_millis(10);
/// Write a progress snapshot every this many ticks (25 × 10ms = 250ms).
const PROGRESS_INTERVAL_TICKS: u32 = 25;

/// Run a streaming content build with a live-progress reporter that snapshots
/// [`df_index::IndexProgress`] into the `.indexing` marker every 250ms, so
/// `deepfind status` can show files / MB / shards while indexing. The caller
/// MUST already hold the marker guard ([`try_acquire`]) — this fn only builds +
/// reports. Shared by [`spawn_build`] (on-demand / startup), df-watch compaction
/// (`compact_and_swap`), and the safety-net (`rebuild_and_swap`) so every build
/// path surfaces progress.
pub(crate) fn tracked_build(
    root: &Path,
    db_path: &Path,
    content_dir: &Path,
    opts: &ContentBuildOptions,
) -> df_index::Result<df_index::ContentReport> {
    let marker_path = marker(db_path);
    let progress = Arc::new(df_index::IndexProgress::default());
    // Reporter: periodically snapshot the counters into the marker file. Stops
    // when `stop` is set (build done).
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
        root,
        db_path,
        content_dir,
        opts,
        Arc::clone(&progress),
    );
    stop.store(true, Ordering::Relaxed);
    let _ = reporter.join();
    res
}

/// Build `root` → `db_path`/`content_dir` in the background, then reload the
/// whole DbSet from disk and atomically swap it in. Returns `false` (without
/// spawning) if a build for `db_path` is already in flight — [`try_acquire`] is
/// the atomic guard, so two concurrent builds of the same DB can never
/// interleave shard writes. Errors are logged; the daemon keeps serving whatever
/// it had.
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
    let Some(guard) = try_acquire(&db_path) else {
        tracing::info!(db = ?db_path, "index_job: build already in flight; not starting a second");
        return false;
    };
    std::thread::spawn(move || {
        let _guard = guard; // MarkerGuard: removes the marker on drop
        tracing::info!(root = ?root, "background-indexing");
        match tracked_build(&root, &db_path, &content_dir, &opts) {
            Ok(_) => {
                dbset.store(Arc::new(DbSet::open(&default_db_path)));
                tracing::info!(root = ?root, "background-indexing complete; DbSet hot-swapped");
                // Attach df-watch to the freshly-built DB (only when the env
                // gate is set, mirroring serve()'s startup loop). The entry is
                // found by matching `db_path` in the post-swap snapshot; the
                // watcher shares this entry's `Arc<ContentShards>` + overlay
                // handle, so its overlay updates and `compact_and_swap`
                // (`shards.reload()`) hit the same state queries read.
                if std::env::var("DEEPFIND_WATCH").is_ok() {
                    let snap = dbset.load_full();
                    if let Some(entry) = snap.entries.iter().find(|e| e.db_path == db_path) {
                        if let Some(watch_root) = &entry.root {
                            crate::watch::spawn(
                                watch_root.clone(),
                                entry.db_path.clone(),
                                entry.shards.content_dir().to_path_buf(),
                                entry.shards.clone(),
                                entry.overlay.clone(),
                                df_index::ContentBuildOptions::default().max_file_size,
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
    fn try_acquire_is_exclusive() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        let g1 = try_acquire(&db).expect("first acquire succeeds");
        assert!(
            try_acquire(&db).is_none(),
            "second acquire must be rejected while the first holds the marker"
        );
        drop(g1);
        assert!(
            try_acquire(&db).is_some(),
            "re-acquire must succeed after the guard drops"
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

    #[test]
    fn sweep_stale_markers_removes_leftover() {
        let tmp = tempfile::tempdir().unwrap();
        let db_dir = tmp.path().join("db");
        std::fs::create_dir_all(db_dir.join("w")).unwrap();
        // Stale markers (default DB + a named DB) left by a killed previous daemon.
        std::fs::write(db_dir.join("index.indexing"), b"").unwrap();
        std::fs::write(db_dir.join("w").join("index.indexing"), b"").unwrap();
        // A real DB + an unrelated file must be left alone.
        std::fs::write(db_dir.join("index.dfdb"), b"real db").unwrap();
        std::fs::write(db_dir.join("w").join("index.dfdb"), b"real named db").unwrap();

        sweep_stale_markers(&db_dir);

        assert!(
            !db_dir.join("index.indexing").exists(),
            "default marker removed"
        );
        assert!(
            !db_dir.join("w").join("index.indexing").exists(),
            "named-DB marker removed"
        );
        assert!(
            db_dir.join("index.dfdb").exists(),
            "sweep must not touch real DBs"
        );
        assert!(
            db_dir.join("w").join("index.dfdb").exists(),
            "sweep must not touch named-DB files"
        );
    }
}
