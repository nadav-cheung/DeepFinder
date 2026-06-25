// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Searches via the daemon; falls back to `--direct`
//! online scan when the daemon is down.

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use df_core::LiteMeta;
use df_ipc::proto::{
    CaseControl, IndexRequest, LayerMask, LineHit, MatchKind, PathMode, ResponseFrame,
    SearchOptions, SearchRequest, SortMode,
};
use df_ipc::{
    data_dir, decode_frame, default_db, default_socket, encode_index_request, encode_request,
    framed, home,
};
use futures::{SinkExt, StreamExt};
use tokio::net::UnixStream;

mod launchd;

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
        /// Build in-process in the foreground instead of submitting a background
        /// build to the daemon (also implied by --no-content). Default: submit.
        #[arg(long)]
        foreground: bool,
    },
    /// Run the resident daemon.
    Daemon,
    /// Daemon health + DB stats.
    Status,
    /// Self-diagnostic (Full Disk Access check + guidance).
    Doctor,
    /// Manage named DBs (build/remove/list named roots).
    Db {
        #[command(subcommand)]
        action: DbAction,
    },
    /// Install a user LaunchAgent so the daemon auto-starts at login (macOS).
    Install {
        /// Do not enable df-watch incremental hot-swap in the agent.
        #[arg(long)]
        no_watch: bool,
    },
    /// Uninstall the LaunchAgent (stops the daemon + removes the plist).
    Uninstall,
    /// Search the index (falls back to --direct if the daemon is down).
    Search {
        /// Search query (required; --expr, if given, acts as an additional post-filter).
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
        /// bfs/find-style expression, e.g. `--expr='-name *.rs -size +1k'`.
        /// Supports: -name PAT, -path PAT, -size [+|-]N[unit], -newer FILE,
        /// ! / -not / -a / -o / parens. Use `=` (--expr='...') to keep the
        /// expression as a single argument across shell word-splitting.
        #[arg(long = "expr", value_name = "EXPR", verbatim_doc_comment)]
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
            foreground,
        } => {
            cmd_index(
                &root,
                force,
                skip,
                max_file_size,
                no_content,
                one_file_system,
                hidden,
                foreground,
            )
            .await
        }
        Cmd::Daemon => cmd_daemon().await,
        Cmd::Status => cmd_status().await,
        Cmd::Doctor => cmd_doctor(),
        Cmd::Db { action } => cmd_db(action),
        Cmd::Install { no_watch } => cmd_install(!no_watch),
        Cmd::Uninstall => cmd_uninstall(),
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

#[allow(clippy::too_many_arguments)] // 8 fields passed straight off the clap Cmd::Index destructure.
async fn cmd_index(
    root: &Path,
    force: bool,
    mut skip: Vec<String>,
    max_file_size: u64,
    no_content: bool,
    one_file_system: bool,
    hidden: bool,
    foreground: bool,
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

    // Submit a background build to the daemon unless --foreground (or
    // --no-content, which the background path doesn't serve). Falls back to an
    // in-process build if the daemon is unreachable — mirroring `deepfind
    // search`'s --direct fallback so the user is never blocked.
    if !foreground && !no_content {
        match daemon_index_submit(root, &skip, max_file_size, one_file_system, hidden).await {
            Ok((_accepted, message)) => {
                println!("{message}");
                return;
            }
            Err(e) => {
                let msg = e.to_string();
                if is_daemon_unreachable(&msg) {
                    eprintln!("(daemon unavailable: {msg}; building in foreground)");
                } else {
                    eprintln!("error: {msg}");
                    std::process::exit(1);
                }
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

fn cmd_install(watch: bool) {
    let exe = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("install: cannot resolve current executable: {e}");
            std::process::exit(1);
        }
    };
    // If no DB is registered yet, auto-register $HOME as a watched DB named
    // "home". We do NOT build here — the daemon's background-build job (P2.3)
    // indexes it on start. db_path/content_dir mirror `db add`'s convention.
    let home = home();
    if let Some((name, root)) = ensure_default_root(&home) {
        let data = data_dir();
        let db_dir = data.join("db").join(&name);
        let db_path = db_dir.join("index.dfdb");
        let content_dir = db_dir.join("content");
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
            "No DB registered — auto-registered '{name}' → {} (the daemon will index it on start).",
            root.display()
        );
    }
    if let Err(e) = launchd::install(&home, &exe, watch, true) {
        eprintln!("install failed: {e}");
        std::process::exit(1);
    }
    println!(
        "Installed LaunchAgent {label} (auto-start at login, KeepAlive on).",
        label = launchd::LABEL
    );
    if watch {
        println!("df-watch incremental hot-swap is enabled in the agent.");
    }
    println!();
    println!("The daemon starts shortly. Index a root once so searches hit the index:");
    println!("  deepfind index --root <path>");
    println!();
    println!("Status: deepfind status");
    println!("Stop:   deepfind uninstall");
}

fn cmd_uninstall() {
    if let Err(e) = launchd::uninstall(&home(), true) {
        eprintln!("uninstall failed: {e}");
        std::process::exit(1);
    }
    println!("Uninstalled LaunchAgent {label}.", label = launchd::LABEL);
}

/// At daemon start, warn once if Full Disk Access is missing. No GUI — the
/// daemon must not pop System Settings. Guides the user to `deepfind doctor`.
fn warn_if_no_fda() {
    if matches!(df_index::fda_state(), df_index::FdaState::Denied) {
        tracing::warn!(
            "Full Disk Access not granted; protected dirs (~/Library/Mail, Messages, …) \
             will be skipped. Run `deepfind doctor`."
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
    warn_if_no_fda();
    if let Err(e) = deepfindd::serve(&default_socket(), &default_db()).await {
        eprintln!("daemon error: {e}");
        std::process::exit(1);
    }
}

/// One-word FDA status for the `status` line.
fn fda_status_word(state: df_index::FdaState) -> &'static str {
    match state {
        df_index::FdaState::Granted => "granted",
        df_index::FdaState::Denied => "missing",
        df_index::FdaState::Unknown => "unknown",
    }
}

/// Whether `doctor` should auto-open the Full Disk Access settings pane — only
/// when FDA is missing AND stdout is an interactive terminal (don't pop System
/// Settings from scripts/CI).
fn should_open_panel(state: df_index::FdaState, is_tty: bool) -> bool {
    matches!(state, df_index::FdaState::Denied) && is_tty
}

async fn cmd_status() {
    let sock = default_socket();
    match UnixStream::connect(&sock).await {
        Ok(_) => println!("daemon: reachable ({})", sock.display()),
        Err(_) => println!("daemon: NOT reachable ({})", sock.display()),
    }
    println!(
        "full disk access: {}",
        fda_status_word(df_index::fda_state())
    );
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

    // Per-DB index freshness: the default DB plus every registered DB.
    println!("db default: {}   ({})", db_state_line(&db), db.display());
    let reg = df_index::Registry::load(&data_dir());
    for r in &reg.records {
        println!(
            "db {}: {}   ({})",
            r.name,
            db_state_line(&r.db_path),
            r.db_path.display()
        );
    }
}

/// Self-diagnostic. Today: Full Disk Access probe + guidance.
fn cmd_doctor() {
    let state = df_index::fda_state();
    match state {
        df_index::FdaState::Granted => println!("✅ Full Disk Access: {}", fda_status_word(state)),
        df_index::FdaState::Denied => {
            println!("❌ Full Disk Access: {}", fda_status_word(state));
            println!();
            println!(
                "Without it, protected dirs (~/Library/Mail, Messages, Safari, …) are skipped."
            );
            let exe = std::env::current_exe()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "deepfind (run `which deepfind` to locate)".to_string());
            println!("Binary to authorize: {exe}");
            if should_open_panel(state, std::io::stdout().is_terminal()) {
                println!("Opening Full Disk Access settings…");
                let _ = std::process::Command::new("open")
                    .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    .status();
            } else {
                println!("Open: System Settings → Privacy & Security → Full Disk Access");
            }
            println!();
            println!("After granting, restart the daemon:");
            println!("    launchctl kickstart -k gui/$(id -u)/{}", launchd::LABEL);
        }
        df_index::FdaState::Unknown => {
            println!("❓ Full Disk Access: {}", fda_status_word(state));
            println!("If searches miss files under ~/Library, grant Full Disk Access.");
        }
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
    // Try the daemon unless --direct. If the daemon is down (connection
    // refused / socket missing) fall back to --direct. Application errors
    // (bad regex, unknown --db name, etc.) are fatal — falling back to
    // --direct would silently ignore the --db flag and other daemon-only opts.
    let results = if !opts.direct {
        warn_if_stale(&default_db());
        match daemon_search(query, limit, scope.clone(), opts.clone(), db.clone()).await {
            Ok(r) => Some(r),
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("Connection refused")
                    || msg.contains("No such file")
                    || msg.contains("connect")
                {
                    eprintln!("(daemon unavailable: {e}; falling back to --direct)");
                    None
                } else {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
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
            ResponseFrame::IndexAck { .. } => return Err("unexpected IndexAck".into()),
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

/// Classify a daemon IPC error as "daemon unreachable" (down / no socket) so
/// `cmd_index` can fall back to an in-process build. Mirrors the inline check
/// in `cmd_search`'s fallback.
fn is_daemon_unreachable(msg: &str) -> bool {
    msg.contains("Connection refused") || msg.contains("No such file") || msg.contains("connect")
}

/// Submit a background index build to the daemon over the socket (P2.3).
/// Returns the daemon's `(accepted, message)` ack. A connection error (daemon
/// down) propagates as an `Err` so the caller can fall back to an in-process
/// build.
async fn daemon_index_submit(
    root: &Path,
    skip: &[String],
    max_file_size: u64,
    one_file_system: bool,
    hidden: bool,
) -> Result<(bool, String), Box<dyn std::error::Error + Send + Sync>> {
    let stream = UnixStream::connect(default_socket()).await?;
    let mut f = framed(stream);
    let req = IndexRequest {
        root: Some(root.to_path_buf()),
        skip: skip.to_vec(),
        max_file_size,
        one_file_system,
        hidden,
        db: None,
    };
    f.send(encode_index_request(&req)?).await?;
    let frame = f.next().await.ok_or("daemon closed without ack")??;
    match decode_frame(&frame)? {
        ResponseFrame::IndexAck { accepted, message } => Ok((accepted, message)),
        ResponseFrame::Error { message } => Err(message.into()),
        other => Err(format!("unexpected response frame: {other:?}").into()),
    }
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

/// If no DB is registered yet, suggest registering `$HOME` as a watched DB
/// named "home" so the daemon's background-build job (P2.3) indexes it on
/// start. Returns `None` once any DB exists.
fn ensure_default_root(home: &Path) -> Option<(String, PathBuf)> {
    let reg = df_index::Registry::load(&home.join(".deep-finder"));
    if reg.records.is_empty() {
        Some(("home".into(), home.to_path_buf()))
    } else {
        None
    }
}

/// Per-DB index freshness for `deepfind status`. Returns one of:
/// `"indexing"` (background build in flight), `"missing"` (no index file),
/// `"fresh"` (mtime within 24h), or `"stale"` (older).
fn index_state(db_path: &Path) -> &'static str {
    if deepfindd::index_job::is_indexing(db_path) {
        return "indexing";
    }
    let Ok(meta) = std::fs::metadata(db_path) else {
        return "missing";
    };
    let Ok(mtime) = meta.modified() else {
        return "stale";
    };
    let age = SystemTime::now().duration_since(mtime).unwrap_or_default();
    if age < std::time::Duration::from_secs(24 * 60 * 60) {
        "fresh"
    } else {
        "stale"
    }
}

/// `deepfind status` per-DB line: the [`index_state`], but when a build is in
/// flight it appends the live progress (files / MB / shards) that the daemon's
/// reporter writes to the `.indexing` marker.
fn db_state_line(db_path: &Path) -> String {
    match index_state(db_path) {
        "indexing" => match deepfindd::index_job::read_progress(db_path) {
            Some(p) => format!("indexing: {p}"),
            None => "indexing".to_string(),
        },
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_default_root_home_when_no_dbs() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        // No dbs.toml yet → suggest registering $HOME.
        assert_eq!(
            ensure_default_root(&home),
            Some(("home".into(), home.clone()))
        );
        // After registering one DB, it returns None.
        let data = home.join(".deep-finder");
        std::fs::create_dir_all(&data).unwrap();
        let mut reg = df_index::Registry::load(&data);
        reg.upsert(df_index::DbRecord {
            name: "x".into(),
            root: home.clone(),
            db_path: home.join("x.dfdb"),
            content_dir: home.join("xc"),
        });
        reg.save().unwrap();
        assert_eq!(ensure_default_root(&home), None);
    }

    #[test]
    fn index_state_missing_when_no_file() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(index_state(&tmp.path().join("index.dfdb")), "missing");
    }

    #[test]
    fn daemon_unreachable_error_classification() {
        // Socket present but nothing listening / no socket file at all.
        assert!(is_daemon_unreachable("Connection refused (os error 61)"));
        assert!(is_daemon_unreachable(
            "No such file or directory (os error 2)"
        ));
        assert!(is_daemon_unreachable("failed to connect to socket"));
        // Application errors are NOT unreachable ⇒ no fallback (fatal instead).
        assert!(!is_daemon_unreachable("bad regex: *"));
        assert!(!is_daemon_unreachable("unexpected IndexAck"));
    }

    #[test]
    fn db_state_line_shows_progress_when_marker_has_content() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        // Matches index_job::marker: db_path.with_extension("indexing").
        std::fs::write(
            db.with_extension("indexing"),
            b"42 files \xc2\xb7 0.1 MB \xc2\xb7 1 shards",
        )
        .unwrap();
        assert_eq!(db_state_line(&db), "indexing: 42 files · 0.1 MB · 1 shards");
    }

    #[test]
    fn db_state_line_bare_indexing_when_marker_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(db.with_extension("indexing"), b"").unwrap();
        assert_eq!(db_state_line(&db), "indexing");
    }

    #[test]
    fn index_state_indexing_when_marker_present() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(&db, b"x").unwrap();
        // Matches index_job::marker: db_path.with_extension("indexing").
        std::fs::write(db.with_extension("indexing"), b"").unwrap();
        assert_eq!(index_state(&db), "indexing");
    }

    #[test]
    fn index_state_fresh_when_recent() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(&db, b"x").unwrap();
        assert_eq!(index_state(&db), "fresh");
    }

    #[test]
    fn index_state_stale_when_old() {
        let tmp = tempfile::tempdir().unwrap();
        let db = tmp.path().join("index.dfdb");
        std::fs::write(&db, b"x").unwrap();
        // Backdate mtime by >24h via `touch -t` (no extra crate needed).
        // CCYYMMDDhhmm — 2000-01-01 00:00 is well past the 24h freshness window.
        let st = std::process::Command::new("touch")
            .arg("-t")
            .arg("200001010000")
            .arg(&db)
            .status()
            .unwrap();
        assert!(st.success(), "touch -t failed");
        assert_eq!(index_state(&db), "stale");
    }

    #[test]
    fn fda_status_word_maps_states() {
        assert_eq!(fda_status_word(df_index::FdaState::Granted), "granted");
        assert_eq!(fda_status_word(df_index::FdaState::Denied), "missing");
        assert_eq!(fda_status_word(df_index::FdaState::Unknown), "unknown");
    }

    #[test]
    fn should_open_panel_only_when_denied_and_tty() {
        assert!(should_open_panel(df_index::FdaState::Denied, true));
        assert!(!should_open_panel(df_index::FdaState::Denied, false));
        assert!(!should_open_panel(df_index::FdaState::Granted, true));
        assert!(!should_open_panel(df_index::FdaState::Unknown, true));
    }
}
