// SPDX-License-Identifier: MIT
//! Background initial-index builder. For a registered DB whose index is missing
//! at daemon startup, build it off the hot path, then hot-swap the DbSet so
//! queries see it — no restart, no offline window.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use arc_swap::ArcSwap;

use crate::DbSet;

/// Marker file written while a build is in flight (so `deepfind status` can
/// report `indexing`). Lives beside the DB's index.dfdb.
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

/// Build `root` → `db_path`/`content_dir` in the background, then reload the
/// whole DbSet from disk and atomically swap it in. Errors are logged; the
/// daemon keeps serving whatever it had. No-op (returns without spawning) if
/// `db_path` already exists.
///
/// On a successful build, the freshly-built DB is **also attached to df-watch**
/// (when enabled): `serve()`'s startup df-watch loop only watches DBs that had
/// an index at startup, so a DB that was just background-built would otherwise
/// never be watched — breaking live updates for the primary `deepfind install`
/// path (`$HOME` auto-registers with no index). Holistic-review I1.
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
    std::thread::spawn(move || {
        let _ = std::fs::write(marker(&db_path), b"");
        let marker_path = marker(&db_path);
        let _guard = MarkerGuard(marker_path.as_path());
        tracing::info!(root = ?root, "background-indexing");
        let res = df_index::build_content_index(&root, &db_path, &content_dir, &Default::default());
        match res {
            Ok(_) => {
                dbset.store(Arc::new(DbSet::open(&default_db_path)));
                tracing::info!(root = ?root, "background-indexing complete; DbSet hot-swapped");
                // Attach df-watch to the freshly-built DB. Only when the env
                // gate is set (mirrors serve()'s startup loop). The entry is
                // found by matching `db_path` in the post-swap snapshot. The
                // watcher shares this entry's `Arc<ContentShards>`, so its
                // `rebuild_and_swap` → `shards.reload()` updates the same
                // shards queries read.
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
}

/// True while a build for `db_path` is in flight (used by `deepfind status`).
pub fn is_indexing(db_path: &Path) -> bool {
    marker(db_path).exists()
}
