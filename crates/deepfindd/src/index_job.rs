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

/// Build `root` → `db_path`/`content_dir` in the background, then reload the
/// whole DbSet from disk and atomically swap it in. Errors are logged; the
/// daemon keeps serving whatever it had. No-op (returns without spawning) if
/// `db_path` already exists.
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
        tracing::info!(root = ?root, "background-indexing");
        let res = df_index::build_content_index(&root, &db_path, &content_dir, &Default::default());
        let _ = std::fs::remove_file(marker(&db_path));
        match res {
            Ok(_) => {
                dbset.store(Arc::new(DbSet::open(&default_db_path)));
                tracing::info!(root = ?root, "background-indexing complete; DbSet hot-swapped");
            }
            Err(e) => tracing::warn!(error = %e, root = ?root, "background-indexing failed"),
        }
    });
}

/// True while a build for `db_path` is in flight (used by `deepfind status`).
pub fn is_indexing(db_path: &Path) -> bool {
    marker(db_path).exists()
}
