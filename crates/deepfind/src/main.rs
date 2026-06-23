// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Searches via the daemon; falls back to `--direct`
//! online scan when the daemon is down.

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use df_core::LiteMeta;
use df_ipc::proto::{
    CaseControl, LayerMask, LineHit, MatchKind, PathMode, ResponseFrame, SearchOptions,
    SearchRequest, SortMode,
};
use df_ipc::{data_dir, decode_frame, default_db, default_socket, encode_request, framed};
use futures::{SinkExt, StreamExt};
use tokio::net::UnixStream;

#[derive(Parser)]
#[command(name = "deepfind", version, about = "Fast local file search")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

/// How to render results (bundled so cmd_search stays under the arg-count lint).
struct Output {
    long: bool,
    color: String,
    null: bool,
    count: bool,
    line_number: bool,
    context: Option<u32>,
    case_sensitive: bool,
}

#[derive(Subcommand)]
#[allow(clippy::large_enum_variant)] // clap subcommand enum; one instance exists transiently at parse time.
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
        /// Index hidden files (dotfiles) too. Off by default.
        #[arg(short = 'H', long)]
        hidden: bool,
    },
    /// Run the resident daemon.
    Daemon,
    /// Daemon health + DB stats.
    Status,
    /// Manage named DBs (build/remove/list named roots).
    Db {
        #[command(subcommand)]
        action: DbAction,
    },
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
        /// Print paths NUL-separated (for `xargs -0`); ignores -l/--color.
        #[arg(short = '0', long = "null")]
        null: bool,
        /// Print only the count of matches (no paths).
        #[arg(long)]
        count: bool,
        /// Show content matches with line numbers (`path:line:text`).
        #[arg(short = 'n', long = "line-number")]
        line_number: bool,
        /// Show N lines of context around each content match.
        #[arg(short = 'C', long = "context")]
        context: Option<u32>,
        /// Search only the content layer (exclude filename matches).
        #[arg(long, conflicts_with = "filename")]
        content: bool,
        /// Search only the filename layer (exclude content matches).
        #[arg(long, conflicts_with = "content")]
        filename: bool,
        /// Match the full path (default).
        #[arg(short = 'p', long = "full-path")]
        full_path: bool,
        /// Match the file's base name only.
        #[arg(short = 'b', long = "basename")]
        basename: bool,
        /// Include hidden files (affects --direct; indexed search reflects the build).
        #[arg(short = 'H', long = "hidden")]
        hidden: bool,
        /// Stop after N results (alias for --limit with early exit).
        #[arg(long = "max-results", value_name = "N")]
        max_results: Option<u32>,
        /// Sort order: default | path | kind | none.
        #[arg(long, value_name = "MODE")]
        sort: Option<String>,
        /// bfs/find-style expression, e.g. `-name '*.rs' -size +100c`.
        #[arg(long = "expr", value_name = "EXPR")]
        expr: Option<String>,
        /// Restrict the query to one registered named DB.
        #[arg(long, value_name = "NAME")]
        db: Option<String>,
        /// Force online scan (skip the daemon/index).
        #[arg(long)]
        direct: bool,
        /// Case-insensitive search (disables the smart-case default).
        #[arg(short = 'i', long = "ignore-case", conflicts_with = "case_sensitive")]
        ignore_case: bool,
        /// Case-sensitive search (disables the smart-case default).
        #[arg(short = 's', long = "case-sensitive", conflicts_with = "ignore_case")]
        case_sensitive: bool,
    },
}

#[derive(Subcommand)]
enum DbAction {
    /// Build a named DB for <root> and register it.
    Add {
        name: String,
        root: PathBuf,
        /// Max file size (bytes) to index content of (default 1MB).
        #[arg(long, default_value_t = 1024 * 1024)]
        max_file_size: u64,
    },
    /// Remove a named DB (registry + on-disk index).
    Remove { name: String },
    /// List registered named DBs.
    List,
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
            hidden,
        } => cmd_index(
            &root,
            force,
            skip,
            max_file_size,
            no_content,
            one_file_system,
            hidden,
        ),
        Cmd::Daemon => cmd_daemon().await,
        Cmd::Status => cmd_status().await,
        Cmd::Db { action } => cmd_db(action),
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
            null,
            count,
            line_number,
            context,
            content,
            filename,
            full_path,
            basename,
            hidden,
            max_results,
            sort,
            expr,
            db,
            direct,
            ignore_case,
            case_sensitive,
        } => {
            let case = if case_sensitive {
                CaseControl::Sensitive
            } else if ignore_case {
                CaseControl::Insensitive
            } else {
                CaseControl::Smart
            };
            // Layer select: default both; --content / --filename restrict to one.
            let layers = LayerMask {
                filename: !content || filename,
                content: !filename || content,
            };
            let path_mode = if basename {
                PathMode::Basename
            } else {
                PathMode::Full
            };
            let sort_mode = match sort.as_deref() {
                Some("path") => SortMode::Path,
                Some("kind") => SortMode::Kind,
                Some("none") => SortMode::None,
                _ => SortMode::Default,
            };
            let _ = full_path; // -p is the default (Full); kept for CLI parity.
            let opts = SearchOptions {
                direct,
                extensions: extension,
                types,
                excludes: exclude,
                globs: glob,
                max_depth,
                regex: regex.then(|| query.clone()),
                case,
                line_numbers: line_number,
                context,
                layers,
                path_mode,
                hidden,
                sort: sort_mode,
                expr,
            };
            let limit = max_results.or(limit);
            let out = Output {
                long,
                color,
                null,
                count,
                line_number,
                context,
                case_sensitive: case.sensitive(&query),
            };
            cmd_search(&query, limit, scope, opts, db, exec, out).await
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
    hidden: bool,
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
        match df_index::build_index_with(root, &db, &skip, hidden) {
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
        hidden,
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

/// `deepfind db add/remove/list` — manage named DBs under `~/.deep-finder/`.
fn cmd_db(action: DbAction) {
    let data = data_dir();
    match action {
        DbAction::Add {
            name,
            root,
            max_file_size,
        } => {
            let db_dir = data.join("db").join(&name);
            let db_path = db_dir.join("index.dfdb");
            let content_dir = db_dir.join("content");
            let opts = df_index::ContentBuildOptions {
                max_file_size,
                extra_skip: Vec::new(),
                one_file_system: false,
                hidden: false,
            };
            match df_index::build_content_index(&root, &db_path, &content_dir, &opts) {
                Ok(r) => {
                    let mut reg = df_index::Registry::load(&data);
                    reg.upsert(df_index::DbRecord {
                        name: name.clone(),
                        root: root.clone(),
                        db_path: db_path.clone(),
                        content_dir: content_dir.clone(),
                    });
                    if let Err(e) = reg.save() {
                        eprintln!("warning: could not save registry: {e}");
                    }
                    println!(
                        "db '{name}': {} filename / {} content docs -> {}",
                        r.filename_docs,
                        r.content_docs,
                        db_path.display()
                    );
                }
                Err(e) => {
                    eprintln!("db add failed: {e}");
                    std::process::exit(1);
                }
            }
        }
        DbAction::Remove { name } => {
            let mut reg = df_index::Registry::load(&data);
            if reg.remove(&name) {
                let _ = reg.save();
                let _ = std::fs::remove_dir_all(data.join("db").join(&name));
                println!("removed db '{name}'");
            } else {
                eprintln!("no such db: {name}");
                std::process::exit(1);
            }
        }
        DbAction::List => {
            let reg = df_index::Registry::load(&data);
            if reg.records.is_empty() {
                println!("(no named DBs registered)");
            }
            for r in &reg.records {
                println!("{}\t{}\t{}", r.name, r.root.display(), r.db_path.display());
            }
        }
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
    opts: SearchOptions,
    db: Option<String>,
    exec: Option<String>,
    out: Output,
) {
    // Try the daemon unless --direct; fall back to --direct on failure.
    let results = if !opts.direct {
        warn_if_stale(&default_db());
        match daemon_search(query, limit, scope.clone(), opts.clone(), db.clone()).await {
            Ok(r) => Some(r),
            Err(e) => {
                eprintln!("(daemon unavailable: {e}; falling back to --direct)");
                None
            }
        }
    } else {
        None
    };
    let (results, lines) = match results {
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
        print_results(&results, &lines, &out, query);
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
    results: &[(String, LiteMeta, MatchKind)],
    lines: &[LineHit],
    out: &Output,
    query: &str,
) {
    // Line-number / context mode (`-n` / `-C`): render content matches as
    // `path:line:text` (requires the daemon's content index; `--direct` fallback
    // produces no line hits). With `-C`, each line of the context block is
    // numbered and printed with a `path-line:` prefix (grep/ripgrep-style).
    if (out.line_number || out.context.is_some()) && !lines.is_empty() {
        if out.count {
            println!("{}", lines.len());
            return;
        }
        let mut sorted: Vec<&LineHit> = lines.iter().collect();
        sorted.sort_by_key(|h| (h.path.clone(), h.line_no));
        let context_mode = out.context.is_some();
        for h in sorted {
            let body = h.text.trim_end_matches('\n');
            for (i, line) in body.split('\n').enumerate() {
                let sep = if context_mode { '-' } else { ':' };
                println!("{}{}{}:{}", h.path, sep, h.line_no + i as u32, line);
            }
        }
        return;
    }
    if out.count {
        println!("{}", results.len());
        return;
    }
    if out.null {
        for (path, _, _) in results {
            print!("{path}\0");
        }
        return;
    }
    let color_on = match out.color.as_str() {
        "always" => true,
        "never" => false,
        _ => std::io::stdout().is_terminal(),
    };
    let q = query.to_lowercase();
    for (path, meta, kind) in results {
        let shown = highlight(path, &q, query, out.case_sensitive, color_on);
        if out.long {
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

/// Return the path with the first query occurrence highlighted. When
/// `case_sensitive`, the exact-case query is located directly; otherwise the
/// lowercased query is matched against the lowercased path (byte offsets are
/// only safe when lowercasing is length-preserving — ASCII and most text).
fn highlight(path: &str, q_lower: &str, query: &str, case_sensitive: bool, color: bool) -> String {
    if !color || query.is_empty() {
        return path.to_string();
    }
    let (idx, qlen) = if case_sensitive {
        (path.find(query), query.len())
    } else {
        let pl = path.to_lowercase();
        if pl.len() != path.len() {
            return path.to_string();
        }
        (pl.find(q_lower), q_lower.len())
    };
    match idx {
        Some(i) => {
            let end = i + qlen;
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
    db: Option<String>,
) -> Result<
    (Vec<(String, LiteMeta, MatchKind)>, Vec<LineHit>),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let stream = UnixStream::connect(default_socket()).await?;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: query.to_string(),
        scope,
        limit,
        opts,
        db,
    };
    f.send(encode_request(&req)?).await?;
    let mut out = Vec::new();
    let mut lines = Vec::new();
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
            ResponseFrame::Lines { hits } => lines.extend(hits),
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
        Some(total) if (total as usize) != out.len() && (total as usize) != lines.len() => {
            eprintln!(
                "warning: daemon reported {total} results but delivered {} paths / {} lines",
                out.len(),
                lines.len()
            );
        }
        _ => {}
    }
    Ok((out, lines))
}

async fn direct_scan(
    query: &str,
    limit: Option<u32>,
    scope: Option<PathBuf>,
    opts: SearchOptions,
) -> Result<
    (Vec<(String, LiteMeta, MatchKind)>, Vec<LineHit>),
    Box<dyn std::error::Error + Send + Sync>,
> {
    let q = query.to_lowercase();
    let case_sensitive = opts.case.sensitive(query);
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let root = scope.unwrap_or_else(|| PathBuf::from("."));
    let mut out = Vec::new();
    // `-H` includes hidden files in the online scan; default skips them.
    let walker = ignore::WalkBuilder::new(&root)
        .standard_filters(true)
        .hidden(!opts.hidden)
        .build();
    for result in walker {
        if out.len() >= cap {
            break;
        }
        let entry = result?;
        if let Some(s) = entry.path().to_str() {
            let hit = if case_sensitive {
                s.contains(query)
            } else {
                s.to_lowercase().contains(q.as_str())
            };
            if hit && df_ipc::filter::passes(s, &opts) {
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
    Ok((out, Vec::new()))
}
