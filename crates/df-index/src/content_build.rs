// SPDX-License-Identifier: MIT
//! Streaming full-disk content build: walk → text-gate → dual builders → shard flush.

use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use crossbeam_channel::bounded;
use df_content::ShardBuilder;
use df_core::db::DbBuilder;
use ignore::{WalkBuilder, WalkState};

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
}

impl Default for ContentBuildOptions {
    fn default() -> Self {
        Self {
            max_file_size: DEFAULT_MAX_FILE_SIZE,
            extra_skip: Vec::new(),
            one_file_system: false,
            hidden: false,
        }
    }
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

/// Build the filename DB (`out_db`) AND the content shard set (`content_dir`)
/// in one streaming pass. Writes `content_dir/MANIFEST`. Full-rebuild.
pub fn build_content_index(
    root: &Path,
    out_db: &Path,
    content_dir: &Path,
    opts: &ContentBuildOptions,
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

    let (tx, rx) = bounded::<BuildRec>(CHANNEL_CAP);
    let build_time = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Consumer owns both builders; flushes shards as it goes.
    let content_dir = content_dir.to_path_buf();
    let manifest_dir = content_dir.clone();
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
        Box::new(move |result| {
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
                    ContentDecision::Text(b) => Some(b),
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
}
