// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Searches via the daemon; falls back to `--direct`
//! online scan when the daemon is down.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use df_core::LiteMeta;
use df_ipc::proto::{ResponseFrame, SearchOptions, SearchRequest};
use df_ipc::{decode_frame, default_db, default_socket, encode_request, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::UnixStream;

#[derive(Parser)]
#[command(name = "deepfind", version, about = "Fast local file search")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Build / rebuild the index DB.
    Index {
        #[arg(long, default_value = ".")]
        root: PathBuf,
        /// Rebuild even if the index is fresh (< 60s old).
        #[arg(long)]
        force: bool,
        /// Extra directory name(s) to skip (on top of the defaults). Repeatable.
        /// Also read from the DEEPFIND_SKIP env var (colon-separated).
        #[arg(long = "skip", value_name = "NAME")]
        skip: Vec<String>,
    },
    /// Run the resident daemon.
    Daemon,
    /// Daemon health + DB stats.
    Status,
    /// Search the index (falls back to --direct if the daemon is down).
    Search {
        query: String,
        #[arg(long)]
        limit: Option<u32>,
        /// Restrict matches to a subtree (path prefix).
        #[arg(long)]
        scope: Option<PathBuf>,
        /// Long listing: show size and a directory marker.
        #[arg(short = 'l', long)]
        long: bool,
        /// Force online scan (skip the daemon/index).
        #[arg(long)]
        direct: bool,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Index { root, force, skip } => cmd_index(&root, force, skip),
        Cmd::Daemon => cmd_daemon().await,
        Cmd::Status => cmd_status().await,
        Cmd::Search {
            query,
            limit,
            scope,
            long,
            direct,
        } => cmd_search(&query, limit, scope, long, direct).await,
    }
}

/// An index built within this window is considered "fresh" (manual re-index is
/// skipped unless `--force`).
const FRESH_THRESHOLD_SECS: u64 = 60;
/// An index older than this is "stale" — searches warn so results aren't
/// silently out of date (REVIEW §6.2).
const STALE_THRESHOLD_SECS: u64 = 7 * 86_400;

fn cmd_index(root: &Path, force: bool, mut skip: Vec<String>) {
    let db = default_db();
    if !force {
        if let Some(age) = index_build_age(&db) {
            if age < FRESH_THRESHOLD_SECS {
                println!("index is fresh (built {age}s ago), skipping. Use --force to rebuild.");
                return;
            }
        }
    }
    // DEEPFIND_SKIP=foo:bar adds extra skip names (REVIEW §8.1 #3).
    if let Ok(v) = std::env::var("DEEPFIND_SKIP") {
        for s in v.split(':') {
            let t = s.trim();
            if !t.is_empty() {
                skip.push(t.to_string());
            }
        }
    }
    match df_index::build_index_report(root, &db, &skip) {
        Ok(report) => {
            println!("indexed {} entries -> {}", report.docs, db.display());
            // REVIEW §8.2: surface Full Disk Access denials (can't be granted
            // programmatically — only detected and guided).
            if report.denied > 0 {
                eprintln!(
                    "warning: {} entr{} skipped due to permission errors.",
                    report.denied,
                    if report.denied == 1 { "y" } else { "ies" }
                );
                eprintln!(
                    "  To index protected locations, grant Full Disk Access to this\n  \
                     binary in System Settings → Privacy & Security → Full Disk Access."
                );
            }
        }
        Err(e) => {
            eprintln!("index failed: {e}");
            std::process::exit(1);
        }
    }
}

/// Open the on-disk DB read-only (None if missing/unreadable/not yet built).
fn open_reader(path: &Path) -> Option<df_core::DbReader<df_index::FileSource>> {
    let src = df_index::FileSource::open(path).ok()?;
    df_core::DbReader::open(src).ok()
}

/// Seconds since the index was built, or None if unknown/missing.
fn index_build_age(db_path: &Path) -> Option<u64> {
    let r = open_reader(db_path)?;
    let bt = r.build_time();
    if bt == 0 {
        return None;
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
    Some(now.saturating_sub(bt))
}

/// Warn on stderr when the index is stale, so results are never silently
/// out of date (REVIEW §6.2).
fn warn_if_stale(db_path: &Path) {
    let Some(age) = index_build_age(db_path) else {
        return;
    };
    if age > STALE_THRESHOLD_SECS {
        let days = age / 86_400;
        eprintln!(
            "warning: index is {days} days old; results may be stale. Run 'deepfind index' to refresh."
        );
    }
}

async fn cmd_daemon() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    if let Err(e) = deepfindd::serve(&default_socket(), &default_db()).await {
        eprintln!("daemon error: {e}");
        std::process::exit(1);
    }
}

async fn cmd_status() {
    let sock = default_socket();
    match UnixStream::connect(&sock).await {
        Ok(_) => println!("daemon: reachable ({})", sock.display()),
        Err(_) => println!("daemon: NOT reachable ({})", sock.display()),
    }
    let db = default_db();
    match open_reader(&db) {
        Some(r) => {
            let age = match index_build_age(&db) {
                Some(s) => format!("{s}s ago"),
                None => "unknown".into(),
            };
            println!(
                "db: {} | {} docs | built {}",
                db.display(),
                r.num_docs(),
                age
            );
        }
        None => println!("db: {} (missing/unreadable)", db.display()),
    }
}

async fn cmd_search(
    query: &str,
    limit: Option<u32>,
    scope: Option<PathBuf>,
    long: bool,
    direct: bool,
) {
    if !direct {
        warn_if_stale(&default_db());
        match daemon_search(query, limit, scope.clone()).await {
            Ok(results) => {
                print_results(results, long);
                return;
            }
            Err(e) => eprintln!("(daemon unavailable: {e}; falling back to --direct)"),
        }
    }
    match direct_scan(query, limit, scope).await {
        Ok(results) => print_results(results, long),
        Err(e) => {
            eprintln!("direct scan failed: {e}");
            std::process::exit(1);
        }
    }
}

fn print_results(results: Vec<(String, LiteMeta)>, long: bool) {
    for (path, meta) in results {
        if long {
            let dir = if meta.is_dir { "/" } else { "" };
            println!("{}\t{}{}", humansize(meta.size), path, dir);
        } else {
            println!("{path}");
        }
    }
}

/// Format a byte count compactly (no external dep).
fn humansize(n: i64) -> String {
    let n = n.max(0) as u64;
    const UNITS: &[&str] = &["B", "K", "M", "G", "T"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i + 1 < UNITS.len() {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n}{}", UNITS[i])
    } else {
        format!("{:.1}{}", v, UNITS[i])
    }
}

async fn daemon_search(
    query: &str,
    limit: Option<u32>,
    scope: Option<PathBuf>,
) -> Result<Vec<(String, LiteMeta)>, Box<dyn std::error::Error + Send + Sync>> {
    let stream = UnixStream::connect(default_socket()).await?;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: query.to_string(),
        scope,
        limit,
        opts: SearchOptions::default(),
    };
    f.send(encode_request(&req)?).await?;
    let mut out = Vec::new();
    let mut done_total: Option<u32> = None;
    while let Some(frame) = f.next().await {
        match decode_frame(&frame?)? {
            ResponseFrame::Batch { paths, meta } => {
                let mut meta = meta.into_iter();
                for p in paths {
                    let m = meta.next().unwrap_or_default();
                    out.push((p, m));
                }
            }
            ResponseFrame::Done { total } => {
                done_total = Some(total);
                break;
            }
            ResponseFrame::Error { message } => return Err(message.into()),
        }
    }
    match done_total {
        // Stream ended without Done (daemon crash / socket reset): fall back to
        // --direct so the user gets complete results, not silent partial ones.
        None => return Err("daemon stream ended early".into()),
        Some(total) if (total as usize) != out.len() => {
            eprintln!(
                "warning: daemon reported {total} results but delivered {}",
                out.len()
            );
        }
        _ => {}
    }
    Ok(out)
}

async fn direct_scan(
    query: &str,
    limit: Option<u32>,
    scope: Option<PathBuf>,
) -> Result<Vec<(String, LiteMeta)>, Box<dyn std::error::Error + Send + Sync>> {
    let q = query.to_lowercase();
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let root = scope.unwrap_or_else(|| PathBuf::from("."));
    let mut out = Vec::new();
    for result in ignore::Walk::new(&root) {
        if out.len() >= cap {
            break;
        }
        let entry = result?;
        if let Some(s) = entry.path().to_str() {
            if s.to_lowercase().contains(q.as_str()) {
                let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
                out.push((
                    s.to_string(),
                    LiteMeta {
                        is_dir,
                        size: 0,
                        mtime: 0,
                    },
                ));
            }
        }
    }
    Ok(out)
}
