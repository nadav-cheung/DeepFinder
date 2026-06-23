// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Searches via the daemon; falls back to `--direct`
//! online scan when the daemon is down.

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use df_core::LiteMeta;
use df_ipc::proto::{MatchKind, ResponseFrame, SearchOptions, SearchRequest};
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
        /// Max file size (bytes) to index content of (default 1MB).
        #[arg(long, default_value_t = 1024 * 1024)]
        max_file_size: u64,
        /// Build filename index only (skip content).
        #[arg(long)]
        no_content: bool,
        /// Don't cross mount/filesystem boundaries.
        #[arg(long)]
        one_file_system: bool,
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
        /// Keep only these extensions (no leading dot). Repeatable. (-e rs -e md)
        #[arg(short = 'e', long = "extension")]
        extension: Vec<String>,
        /// Keep only these type categories: code/docs/config/web/archive/media.
        /// Repeatable. (-t code -t docs)
        #[arg(short = 't', long = "type")]
        types: Vec<String>,
        /// Exclude glob patterns (matched against the full path). Repeatable.
        #[arg(short = 'E', long = "exclude")]
        exclude: Vec<String>,
        /// Inclusive glob — a path must match at least one. Repeatable.
        #[arg(short = 'g', long = "glob")]
        glob: Vec<String>,
        /// Max path depth (separator count from the index root).
        #[arg(short = 'd', long = "max-depth")]
        max_depth: Option<u32>,
        /// Colorize output: always | never | auto (auto = only on a TTY).
        #[arg(long, default_value = "auto")]
        color: String,
        /// Treat the query as a regex matched against paths (filename-regex mode).
        #[arg(long, short = 'r')]
        regex: bool,
        /// Execute a command for each result. `{}` is replaced by the path
        /// (e.g. -x 'wc -l {}'). If set, results are not printed.
        #[arg(short = 'x', long = "exec")]
        exec: Option<String>,
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
        Cmd::Index {
            root,
            force,
            skip,
            max_file_size,
            no_content,
            one_file_system,
        } => cmd_index(
            &root,
            force,
            skip,
            max_file_size,
            no_content,
            one_file_system,
        ),
        Cmd::Daemon => cmd_daemon().await,
        Cmd::Status => cmd_status().await,
        Cmd::Search {
            query,
            limit,
            scope,
            extension,
            types,
            exclude,
            glob,
            max_depth,
            exec,
            color,
            regex,
            long,
            direct,
        } => {
            let opts = SearchOptions {
                direct,
                extensions: extension,
                types,
                excludes: exclude,
                globs: glob,
                max_depth,
                regex: regex.then(|| query.clone()),
            };
            cmd_search(&query, limit, scope, long, opts, exec, color).await
        }
    }
}

/// An index built within this window is considered "fresh" (manual re-index is
/// skipped unless `--force`).
const FRESH_THRESHOLD_SECS: u64 = 60;
/// An index older than this is "stale" — searches warn so results aren't
/// silently out of date (REVIEW §6.2).
const STALE_THRESHOLD_SECS: u64 = 7 * 86_400;

fn cmd_index(
    root: &Path,
    force: bool,
    mut skip: Vec<String>,
    max_file_size: u64,
    no_content: bool,
    one_file_system: bool,
) {
    let db = default_db();
    if !force {
        if let Some(age) = index_build_age(&db) {
            if age < FRESH_THRESHOLD_SECS {
                println!("index is fresh (built {age}s ago), skipping. Use --force to rebuild.");
                return;
            }
        }
    }
    if let Ok(v) = std::env::var("DEEPFIND_SKIP") {
        for s in v.split(':') {
            let t = s.trim();
            if !t.is_empty() {
                skip.push(t.to_string());
            }
        }
    }

    if no_content {
        match df_index::build_index_with(root, &db, &skip) {
            Ok(n) => println!("indexed {n} entries (filename only) -> {}", db.display()),
            Err(e) => {
                eprintln!("index failed: {e}");
                std::process::exit(1);
            }
        }
        return;
    }

    let content_dir = db.parent().expect("db has parent").join("content");
    let opts = df_index::ContentBuildOptions {
        max_file_size,
        extra_skip: skip,
        one_file_system,
    };
    match df_index::build_content_index(root, &db, &content_dir, &opts) {
        Ok(r) => {
            println!(
                "indexed {} entries ({} content docs, {} shards) -> {}",
                r.filename_docs,
                r.content_docs,
                r.shards,
                db.display()
            );
            if r.denied > 0 {
                eprintln!(
                    "warning: {} entries skipped (permission denied). Grant Full Disk Access in System Settings → Privacy & Security.",
                    r.denied
                );
            }
            if r.content_skipped_binary + r.content_skipped_large > 0 {
                eprintln!(
                    "note: {} files content-skipped (binary), {} (oversized).",
                    r.content_skipped_binary, r.content_skipped_large
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
    opts: SearchOptions,
    exec: Option<String>,
    color: String,
) {
    // Try the daemon unless --direct; fall back to --direct on failure.
    let results = if !opts.direct {
        warn_if_stale(&default_db());
        match daemon_search(query, limit, scope.clone(), opts.clone()).await {
            Ok(r) => Some(r),
            Err(e) => {
                eprintln!("(daemon unavailable: {e}; falling back to --direct)");
                None
            }
        }
    } else {
        None
    };
    let results = match results {
        Some(r) => r,
        None => match direct_scan(query, limit, scope, opts).await {
            Ok(r) => r,
            Err(e) => {
                eprintln!("direct scan failed: {e}");
                std::process::exit(1);
            }
        },
    };

    if let Some(template) = exec {
        exec_on(&results, &template);
    } else {
        let color_on = match color.as_str() {
            "always" => true,
            "never" => false,
            _ => std::io::stdout().is_terminal(),
        };
        print_results(results, long, query, color_on);
    }
}

/// Run `template` (with `{}` → path) via `sh -c` for each result.
fn exec_on(results: &[(String, LiteMeta, MatchKind)], template: &str) {
    for (path, _, _) in results {
        let cmd = template.replace("{}", path);
        match std::process::Command::new("sh")
            .arg("-c")
            .arg(&cmd)
            .status()
        {
            Ok(s) if !s.success() => eprintln!("deepfind: command failed: {cmd}"),
            Err(e) => eprintln!("deepfind: could not run {cmd}: {e}"),
            _ => {}
        }
    }
}

fn print_results(
    results: Vec<(String, LiteMeta, MatchKind)>,
    long: bool,
    query: &str,
    color: bool,
) {
    let q = query.to_lowercase();
    for (path, meta, kind) in results {
        let shown = highlight(&path, &q, color);
        if long {
            let dir = if meta.is_dir { "/" } else { "" };
            let km = match kind {
                MatchKind::Filename => "[f]",
                MatchKind::Content => "[c]",
                MatchKind::Both => "[b]",
            };
            println!("{km}\t{}\t{}{}", humansize(meta.size), shown, dir);
        } else {
            println!("{shown}");
        }
    }
}

const C_MATCH: &str = "\x1b[1;31m"; // bold red
const C_RESET: &str = "\x1b[0m";

/// Return the path with the first (case-insensitive) query occurrence
/// highlighted. Byte offsets are only safe when lowercasing is length-preserving
/// (ASCII and most text); otherwise return the path unchanged.
fn highlight(path: &str, q_lower: &str, color: bool) -> String {
    if !color || q_lower.is_empty() {
        return path.to_string();
    }
    let pl = path.to_lowercase();
    if pl.len() != path.len() {
        return path.to_string();
    }
    match pl.find(q_lower) {
        Some(i) => {
            let end = i + q_lower.len();
            format!(
                "{}{C_MATCH}{}{C_RESET}{}",
                &path[..i],
                &path[i..end],
                &path[end..]
            )
        }
        None => path.to_string(),
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
    opts: SearchOptions,
) -> Result<Vec<(String, LiteMeta, MatchKind)>, Box<dyn std::error::Error + Send + Sync>> {
    let stream = UnixStream::connect(default_socket()).await?;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: query.to_string(),
        scope,
        limit,
        opts,
    };
    f.send(encode_request(&req)?).await?;
    let mut out = Vec::new();
    let mut done_total: Option<u32> = None;
    while let Some(frame) = f.next().await {
        match decode_frame(&frame?)? {
            ResponseFrame::Batch { paths, meta, kind } => {
                let mut meta = meta.into_iter();
                let mut kind = kind.into_iter();
                for p in paths {
                    let m = meta.next().unwrap_or_default();
                    let k = kind.next().unwrap_or(MatchKind::Filename);
                    out.push((p, m, k));
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
    opts: SearchOptions,
) -> Result<Vec<(String, LiteMeta, MatchKind)>, Box<dyn std::error::Error + Send + Sync>> {
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
            if s.to_lowercase().contains(q.as_str()) && df_ipc::filter::passes(s, &opts) {
                let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
                out.push((
                    s.to_string(),
                    LiteMeta {
                        is_dir,
                        size: 0,
                        mtime: 0,
                    },
                    MatchKind::Filename,
                ));
            }
        }
    }
    Ok(out)
}
