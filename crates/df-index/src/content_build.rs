// SPDX-License-Identifier: MIT
//! Streaming full-disk content build: walk → text-gate → dual builders → shard flush.

use std::path::Path;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;

use crossbeam_channel::bounded;
use df_content::ShardBuilder;
use df_core::db::DbBuilder;
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::{Match, WalkBuilder, WalkState};

use crate::manifest::{Manifest, ShardEntry};
use crate::{atomic_write_public, DEFAULT_SKIP};

/// What the text-gate decided about a file's content.
pub enum ContentDecision {
    /// Text; these (size-capped) bytes should be indexed.
    Text(Vec<u8>),
    /// Binary (NUL byte or excessive trigram diversity) — filename only.
    Binary,
    /// Larger than the size cap — filename only.
    TooLarge,
    /// Unreadable / vanished / not a regular file — filename only.
    Unreadable,
}

const NUL_SCAN_BYTES: usize = 8 * 1024;
const TRIGRAM_MAX: usize = 20_000;

/// Read up to `max_file_size` bytes of `path` and classify it. Files larger than
/// the cap are TooLarge (no content). NUL in the first 8 KB, or more than
/// `TRIGRAM_MAX` distinct byte trigrams ⇒ Binary.
pub fn classify(path: &Path, max_file_size: u64) -> ContentDecision {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return ContentDecision::Unreadable,
    };
    if !meta.is_file() {
        return ContentDecision::Unreadable;
    }
    if meta.len() > max_file_size {
        return ContentDecision::TooLarge;
    }
    let mut bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(_) => return ContentDecision::Unreadable,
    };
    bytes.truncate(max_file_size as usize);
    let scan = bytes.len().min(NUL_SCAN_BYTES);
    if bytes[..scan].contains(&0u8) {
        return ContentDecision::Binary;
    }
    if bytes.len() >= 3 && distinct_trigrams(&bytes) > TRIGRAM_MAX {
        return ContentDecision::Binary;
    }
    ContentDecision::Text(bytes)
}

/// Count distinct byte trigrams (lowercased) — the binary/minified heuristic.
fn distinct_trigrams(bytes: &[u8]) -> usize {
    let mut folded = bytes.to_vec();
    for b in &mut folded {
        if b.is_ascii_uppercase() {
            *b |= 0x20;
        }
    }
    let mut set = std::collections::HashSet::new();
    for w in folded.windows(3) {
        set.insert((w[0], w[1], w[2]));
    }
    set.len()
}

/// Shard flush threshold (contentCorpus bytes).
const SHARD_FLUSH_BYTES: usize = 128 * 1024 * 1024;
/// Bounded channel capacity (records in flight).
const CHANNEL_CAP: usize = 64;
const DEFAULT_MAX_FILE_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Clone)]
pub struct ContentBuildOptions {
    pub max_file_size: u64,
    pub extra_skip: Vec<String>,
    pub one_file_system: bool,
    /// Index hidden files (dotfiles) too. Off by default.
    pub hidden: bool,
    /// gitignore-glob patterns (from `settings.json`) to skip in addition to the
    /// built-in skip-list and the `ignore` crate's `standard_filters`. Compiled
    /// once per walk into an in-memory matcher; matched against each entry's
    /// full path.
    pub ignore_patterns: Vec<String>,
}

impl Default for ContentBuildOptions {
    fn default() -> Self {
        Self {
            max_file_size: DEFAULT_MAX_FILE_SIZE,
            extra_skip: Vec::new(),
            one_file_system: false,
            hidden: false,
            ignore_patterns: Vec::new(),
        }
    }
}

/// Compile `patterns` (gitignore-globs from `settings.json`) rooted at `root`
/// into a single in-memory matcher. Each pattern is validated before being
/// added; a bad/empty/malformed glob is warned-and-skipped (the rest still
/// apply). Empty input ⇒ `None` (no matcher, so no per-entry cost).
///
/// **Absolute-path patterns.** The spec advertises filesystem-absolute forms
/// like `/Users/x/Secret`. The `ignore` crate treats a leading `/` as
/// gitignore "anchored relative to the matcher root", NOT as a filesystem-
/// absolute path — so feeding `/Users/x/Secret` verbatim would silently match
/// nothing (a false sense of security). An absolute path that lies UNDER `root`
/// is therefore translated to its root-relative anchored form (`/Secret`); one
/// that is NOT under `root` cannot match anything the walker visits (the walker
/// stays under `root`) and is skipped with a warning.
pub fn compile_ignore_matcher(root: &Path, patterns: &[String]) -> Option<Gitignore> {
    if patterns.is_empty() {
        return None;
    }
    let mut b = GitignoreBuilder::new(root);
    for line in patterns {
        let Some(normalized) = normalize_pattern(root, line) else {
            tracing::warn!(
                pattern = %line,
                "settings ignore: skipping pattern (absolute path not under build root, or malformed/empty)"
            );
            continue;
        };
        if let Err(e) = b.add_line(None, &normalized) {
            tracing::warn!(pattern = %line, error = %e, "settings ignore: skipping bad glob");
        }
    }
    match b.build() {
        Ok(gi) => Some(gi),
        Err(e) => {
            tracing::warn!(error = %e, "settings ignore matcher build failed; ignoring all patterns");
            None
        }
    }
}

/// Normalize one settings pattern for the gitignore matcher rooted at `root`.
/// Returns the string to feed `add_line`, or `None` to skip+warn.
///
/// - Trims surrounding whitespace; empty/whitespace-only ⇒ skip (matches
///   nothing, would only pollute the matcher).
/// - An absolute filesystem path (`Path::new(line).is_absolute()`):
///     - under `root` ⇒ the root-relative anchored form (`/` + rel), which the
///       gitignore matcher anchors correctly (e.g. `/Users/x/Secret` with root
///       `/Users/x` ⇒ `/Secret`).
///     - not under `root` ⇒ `None` (cannot match anything the walker visits).
/// - Anything else (relative globs, bare names) is returned verbatim.
fn normalize_pattern(root: &Path, line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Negation patterns (`!foo`) are relative globs; leave them to add_line.
    let body = trimmed.strip_prefix('!').unwrap_or(trimmed);
    if Path::new(body).is_absolute() {
        let abs = Path::new(body);
        return match abs.strip_prefix(root) {
            // Under root: emit the root-relative anchored form. A leading `/`
            // makes gitignore anchor relative to the matcher root (= `root`),
            // so `/Secret` matches `<root>/Secret` exactly.
            Ok(rel) if rel.as_os_str().is_empty() => {
                // Pattern IS the root itself — anchor to "/" (matches root dir).
                Some("/".to_string())
            }
            Ok(rel) => Some(format!("/{}", rel.to_string_lossy())),
            Err(_) => None, // absolute path outside root: cannot match here
        };
    }
    Some(trimmed.to_string())
}

/// True if `path` is ignored by `matcher`. `is_dir` selects gitignore dir
/// semantics (so a pattern like `secret` with no slash matches a directory).
pub fn is_ignored(matcher: &Gitignore, path: &Path, is_dir: bool) -> bool {
    matches!(matcher.matched(path, is_dir), Match::Ignore(_))
}

#[derive(Debug, Clone, Copy)]
pub struct ContentReport {
    pub filename_docs: u32,
    pub content_docs: u32,
    pub shards: u32,
    pub denied: u32,
    pub content_skipped_binary: u32,
    pub content_skipped_large: u32,
}

/// One record streamed from a walk worker to the consumer.
struct BuildRec {
    path: String,
    is_dir: bool,
    size: i64,
    mtime: i64,
    content: Option<Vec<u8>>, // None ⇒ filename-only (binary/large/dir)
}

struct ConsumerOut {
    fn_bytes: Vec<u8>,
    content_docs: u32,
    shard_entries: Vec<ShardEntry>,
    filename_docs: u32,
}

/// Live progress counters for a streaming build. The daemon's background-build
/// job holds one and polls [`IndexProgress::snapshot`] from another thread so
/// `deepfind status` can report indexing progress. Mirrors the existing
/// `denied`/`skipped` atomic-counter idiom: workers + the consumer thread bump
/// these under `Relaxed` ordering. All-atomic ⇒ `&IndexProgress` is `Sync` and
/// cheaply shareable across the parallel walker + consumer.
#[derive(Debug, Default)]
pub struct IndexProgress {
    pub files_scanned: AtomicU64,
    pub content_bytes: AtomicU64,
    pub shards_written: AtomicU64,
}

/// A point-in-time read of an [`IndexProgress`].
#[derive(Debug, Clone, Copy, Default)]
pub struct Snapshot {
    pub files_scanned: u64,
    pub content_bytes: u64,
    pub shards_written: u64,
}

impl IndexProgress {
    /// Point-in-time read of all counters.
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            files_scanned: self.files_scanned.load(Ordering::Relaxed),
            content_bytes: self.content_bytes.load(Ordering::Relaxed),
            shards_written: self.shards_written.load(Ordering::Relaxed),
        }
    }
}

/// Build the filename DB (`out_db`) AND the content shard set (`content_dir`)
/// in one streaming pass. Writes `content_dir/MANIFEST`. Full-rebuild.
///
/// Convenience wrapper that discards live progress; use
/// [`build_content_index_with_progress`] to observe counters during the build.
pub fn build_content_index(
    root: &Path,
    out_db: &Path,
    content_dir: &Path,
    opts: &ContentBuildOptions,
) -> crate::Result<ContentReport> {
    build_content_index_with_progress(
        root,
        out_db,
        content_dir,
        opts,
        Arc::new(IndexProgress::default()),
    )
}

/// Like [`build_content_index`] but reports live progress through `progress`
/// (files scanned / content bytes / shards written) so a caller on another
/// thread can surface indexing progress (e.g. `deepfind status`).
pub fn build_content_index_with_progress(
    root: &Path,
    out_db: &Path,
    content_dir: &Path,
    opts: &ContentBuildOptions,
    progress: Arc<IndexProgress>,
) -> crate::Result<ContentReport> {
    let mut skip: Vec<&str> = DEFAULT_SKIP.to_vec();
    for e in &opts.extra_skip {
        if !e.is_empty() && !skip.contains(&e.as_str()) {
            skip.push(e.as_str());
        }
    }
    // `ignore`'s parallel walker invokes the outer closure once per worker
    // thread; each thread needs its own `skip`. Wrap in Arc and clone per
    // worker (cheap: the inner closure holds an Arc, not the Vec).
    let skip = Arc::new(skip);

    // Settings.json ignore patterns: compiled ONCE into an in-memory matcher
    // (rooted at `root`) and shared across workers via Arc. One filter covers
    // both the filename and content layers — this single walk feeds both.
    let ignore_matcher = Arc::new(compile_ignore_matcher(root, &opts.ignore_patterns));

    let (tx, rx) = bounded::<BuildRec>(CHANNEL_CAP);
    let build_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Consumer owns both builders; flushes shards as it goes.
    let content_dir = content_dir.to_path_buf();
    let manifest_dir = content_dir.clone();
    // Consumer + walker run on their own threads (`'static`); hand each an owned
    // `Arc<IndexProgress>` clone. The caller keeps its own clone to poll.
    let walker_progress = Arc::clone(&progress);
    let consumer = std::thread::spawn(move || -> crate::Result<ConsumerOut> {
        let mut fnb = DbBuilder::new();
        fnb.set_build_time(build_time);
        std::fs::create_dir_all(&content_dir)?;
        let mut shard_id = 0u32;
        let mut base_docid = 0u32;
        let mut shard = ShardBuilder::new(shard_id, base_docid);
        let mut content_docs = 0u32;
        let mut shard_entries: Vec<ShardEntry> = Vec::new();

        while let Ok(rec) = rx.recv() {
            fnb.insert_with(&rec.path, rec.is_dir, rec.size, rec.mtime);
            if let Some(bytes) = rec.content {
                shard.add_file(&rec.path, rec.is_dir, rec.size, rec.mtime, &bytes);
                content_docs += 1;
                if shard.content_bytes() >= SHARD_FLUSH_BYTES {
                    let n = shard.doc_count();
                    let sbytes = shard.finish(build_time);
                    let fname = format!("shard-{shard_id:05}.dfcs");
                    atomic_write_public(&content_dir.join(&fname), &sbytes)?;
                    progress.shards_written.fetch_add(1, Ordering::Relaxed);
                    shard_entries.push(ShardEntry {
                        shard_id,
                        base_docid,
                        num_docs: n,
                        file: fname,
                    });
                    shard_id += 1;
                    base_docid += n;
                    shard = ShardBuilder::new(shard_id, base_docid);
                }
            }
        }
        // final partial shard (if any docs)
        if shard.doc_count() > 0 {
            let n = shard.doc_count();
            let sbytes = shard.finish(build_time);
            let fname = format!("shard-{shard_id:05}.dfcs");
            atomic_write_public(&content_dir.join(&fname), &sbytes)?;
            progress.shards_written.fetch_add(1, Ordering::Relaxed);
            shard_entries.push(ShardEntry {
                shard_id,
                base_docid,
                num_docs: n,
                file: fname,
            });
        }
        let filename_docs = fnb.doc_count();
        let fn_bytes = fnb.finish();
        Ok(ConsumerOut {
            fn_bytes,
            content_docs,
            shard_entries,
            filename_docs,
        })
    });

    let denied = Arc::new(AtomicU32::new(0));
    let skipped_binary = Arc::new(AtomicU32::new(0));
    let skipped_large = Arc::new(AtomicU32::new(0));

    let mut walker = WalkBuilder::new(root);
    walker
        .standard_filters(true)
        .hidden(!opts.hidden)
        .same_file_system(opts.one_file_system);
    let tx2 = tx.clone();
    let d2 = denied.clone();
    let sb2 = skipped_binary.clone();
    let sl2 = skipped_large.clone();
    let mfs = opts.max_file_size;
    walker.build_parallel().run(move || {
        let tx = tx2.clone();
        let d = d2.clone();
        let sb = sb2.clone();
        let sl = sl2.clone();
        let skip = skip.clone();
        let ignore_matcher = Arc::clone(&ignore_matcher);
        let progress = Arc::clone(&walker_progress);
        Box::new(move |result| {
            progress.files_scanned.fetch_add(1, Ordering::Relaxed);
            let entry = match result {
                Ok(e) => e,
                Err(e) => {
                    if e.io_error()
                        .is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied)
                    {
                        d.fetch_add(1, Ordering::Relaxed);
                    }
                    return WalkState::Continue;
                }
            };
            let name = entry.file_name().to_string_lossy();
            if entry.file_type().is_some_and(|t| t.is_dir()) && skip.iter().any(|s| name == *s) {
                return WalkState::Skip;
            }
            let Some(path_str) = entry.path().to_str() else {
                return WalkState::Continue;
            };
            let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
            // settings.json ignore patterns (union with the name-skip above).
            // A matching directory is pruned (don't descend); a matching file
            // is simply not sent to the consumer (skips both layers at once).
            if let Some(m) = ignore_matcher.as_ref() {
                if is_ignored(m, entry.path(), is_dir) {
                    return if is_dir {
                        WalkState::Skip
                    } else {
                        WalkState::Continue
                    };
                }
            }
            let (size, mtime) = match entry.metadata() {
                Ok(md) => (
                    md.len() as i64,
                    md.modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|x| x.as_secs() as i64)
                        .unwrap_or(0),
                ),
                Err(_) => (0, 0),
            };
            let content = if is_dir {
                None
            } else {
                match classify(entry.path(), mfs) {
                    ContentDecision::Text(b) => {
                        progress
                            .content_bytes
                            .fetch_add(b.len() as u64, Ordering::Relaxed);
                        Some(b)
                    }
                    ContentDecision::Binary => {
                        sb.fetch_add(1, Ordering::Relaxed);
                        None
                    }
                    ContentDecision::TooLarge => {
                        sl.fetch_add(1, Ordering::Relaxed);
                        None
                    }
                    ContentDecision::Unreadable => None,
                }
            };
            if tx
                .send(BuildRec {
                    path: path_str.to_string(),
                    is_dir,
                    size,
                    mtime,
                    content,
                })
                .is_err()
            {
                return WalkState::Quit;
            }
            WalkState::Continue
        })
    });
    drop(tx); // close last sender → consumer's recv() returns Err → finalize

    let out = consumer.join().expect("consumer thread panicked")?;
    atomic_write_public(out_db, &out.fn_bytes)?;

    let manifest = Manifest {
        build_time,
        total_content_docs: out.content_docs,
        shards: out.shard_entries,
    };
    atomic_write_public(&manifest_dir.join("MANIFEST"), &manifest.encode())?;

    Ok(ContentReport {
        filename_docs: out.filename_docs,
        content_docs: out.content_docs,
        shards: manifest.shards.len() as u32,
        denied: denied.load(Ordering::Relaxed),
        content_skipped_binary: skipped_binary.load(Ordering::Relaxed),
        content_skipped_large: skipped_large.load(Ordering::Relaxed),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_file_is_text() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("a.txt");
        std::fs::write(&p, b"fn main() { hello world }").unwrap();
        assert!(matches!(
            classify(&p, 1024 * 1024),
            ContentDecision::Text(_)
        ));
    }

    #[test]
    fn nul_byte_is_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("b.bin");
        std::fs::write(&p, b"abc\x00def").unwrap();
        assert!(matches!(classify(&p, 1024 * 1024), ContentDecision::Binary));
    }

    #[test]
    fn oversized_is_too_large() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("big.txt");
        std::fs::write(&p, vec![b'a'; 10]).unwrap();
        assert!(matches!(classify(&p, 5), ContentDecision::TooLarge));
    }

    #[test]
    fn missing_file_is_unreadable() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join("nope.txt");
        assert!(matches!(
            classify(&p, 1024 * 1024),
            ContentDecision::Unreadable
        ));
    }

    #[test]
    fn build_with_progress_populates_counters() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        std::fs::write(root.join("a.txt"), b"hello world").unwrap();
        std::fs::write(root.join("b.txt"), b"second file content").unwrap();

        let db = tmp.path().join("index.dfdb");
        let content_dir = tmp.path().join("content");
        let progress = Arc::new(IndexProgress::default());
        let report = build_content_index_with_progress(
            root,
            &db,
            &content_dir,
            &ContentBuildOptions::default(),
            Arc::clone(&progress),
        )
        .unwrap();
        let snap = progress.snapshot();

        // Walker yields the root dir + 2 files ⇒ ≥3 scanned entries.
        assert!(
            snap.files_scanned >= 3,
            "files_scanned={}",
            snap.files_scanned
        );
        // Both files are text under the size cap ⇒ 11 + 19 = 30 content bytes.
        assert!(
            snap.content_bytes >= 30,
            "content_bytes={}",
            snap.content_bytes
        );
        // Every flushed shard (including the final partial) is counted.
        assert_eq!(snap.shards_written, report.shards as u64, "shards mismatch");
    }

    // --- settings ignore matcher ---

    /// Helper: compile a matcher rooted at `root` from `patterns`, then ask
    /// whether `cand` (an absolute path under root) is ignored.
    fn ignored(root: &Path, patterns: &[&str], cand: &Path, is_dir: bool) -> bool {
        let m = compile_ignore_matcher(
            root,
            &patterns.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        )
        .expect("non-empty patterns ⇒ Some(matcher)");
        is_ignored(&m, cand, is_dir)
    }

    #[test]
    fn glob_pattern_matches_file_under_root() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        assert!(ignored(root, &["*.log"], &root.join("noise.log"), false));
        assert!(!ignored(root, &["*.log"], &root.join("keep.rs"), false));
    }

    #[test]
    fn bare_name_matches_directory_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        // `secret` (no slash) matches the directory entry — the walker then
        // prunes the subtree, so nested files never reach the matcher.
        assert!(ignored(root, &["secret"], &root.join("secret"), true));
        assert!(!ignored(root, &["secret"], &root.join("keep.rs"), false));
    }

    // edge-1: an absolute-path pattern that points at a path UNDER the build
    // root must ignore it (the spec advertises `/Users/x/Secret`). The naive
    // gitignore form fails because the matcher anchors a leading-slash pattern
    // relative to the build root, not as a filesystem-absolute path.
    #[test]
    fn absolute_path_pattern_under_root_ignores_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let secret = root.join("Secret");
        std::fs::create_dir_all(&secret).unwrap();
        // The spec's motivating example: an absolute FS path equal to the
        // walker entry path. Must ignore the dir (and thus prune it).
        let pat = secret.to_string_lossy().into_owned();
        assert!(
            ignored(root, &[pat.as_str()], &secret, true),
            "absolute path under root must be ignored"
        );
    }

    // edge-1: an absolute-path pattern that is NOT under the build root cannot
    // match anything the walker visits (the walker stays under root). It is a
    // no-op for this build root — it must not spuriously ignore local paths.
    #[test]
    fn absolute_path_pattern_not_under_root_is_noop() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let other = tempfile::tempdir().unwrap();
        let pat = other.path().join("Secret").to_string_lossy().into_owned();
        // A local file must NOT be ignored by an absolute pattern elsewhere.
        assert!(
            !ignored(root, &[pat.as_str()], &root.join("keep.rs"), false),
            "absolute path outside root must not match local files"
        );
    }

    // edge-2: a malformed glob the `ignore` crate silently accepts (returns
    // Ok from add_line) must still be warned-and-skipped per spec §8. These
    // patterns match nothing when retained, so skipping them changes nothing
    // functionally — but the spec and the in-code doc comment promise a warn.
    // We assert the matcher still compiles (Some) and the OTHER patterns still
    // apply (the bad one is dropped, not retained to poison the matcher).
    #[test]
    fn malformed_glob_does_not_poison_matcher() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        // `[` is a malformed glob the ignore crate accepts silently. A valid
        // pattern alongside it must still match.
        let m = compile_ignore_matcher(
            root,
            &[
                "[".to_string(),
                "*.log".to_string(),
                "".to_string(),
                "   ".to_string(),
            ],
        )
        .expect("matcher builds from the surviving valid pattern");
        assert!(is_ignored(&m, &root.join("noise.log"), false));
        assert!(!is_ignored(&m, &root.join("keep.rs"), false));
    }
}
