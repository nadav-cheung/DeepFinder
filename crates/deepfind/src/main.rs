// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Searches via the daemon; falls back to `--direct`
//! online scan when the daemon is down.

use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
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
        #[arg(long)]
        direct: bool,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Index { root } => cmd_index(&root),
        Cmd::Daemon => cmd_daemon().await,
        Cmd::Status => cmd_status().await,
        Cmd::Search {
            query,
            limit,
            direct,
        } => cmd_search(&query, limit, direct).await,
    }
}

fn cmd_index(root: &Path) {
    let db = default_db();
    match df_index::build_index(root, &db) {
        Ok(n) => println!("indexed {n} entries -> {}", db.display()),
        Err(e) => {
            eprintln!("index failed: {e}");
            std::process::exit(1);
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
        Ok(_) => println!("daemon reachable: {}", sock.display()),
        Err(e) => println!("daemon NOT reachable: {} ({e})", sock.display()),
    }
    let db = default_db();
    println!("db: {} (exists={})", db.display(), db.exists());
}

async fn cmd_search(query: &str, limit: Option<u32>, direct: bool) {
    if !direct {
        match daemon_search(query, limit).await {
            Ok(paths) => {
                for p in paths {
                    println!("{p}");
                }
                return;
            }
            Err(e) => eprintln!("(daemon unavailable: {e}; falling back to --direct)"),
        }
    }
    match direct_scan(query, limit).await {
        Ok(paths) => {
            for p in paths {
                println!("{p}");
            }
        }
        Err(e) => {
            eprintln!("direct scan failed: {e}");
            std::process::exit(1);
        }
    }
}

async fn daemon_search(
    query: &str,
    limit: Option<u32>,
) -> Result<Vec<String>, Box<dyn std::error::Error + Send + Sync>> {
    let stream = UnixStream::connect(default_socket()).await?;
    let mut f = framed(stream);
    let req = SearchRequest {
        query: query.to_string(),
        scope: None,
        limit,
        opts: SearchOptions::default(),
    };
    f.send(encode_request(&req)?).await?;
    let mut out = Vec::new();
    while let Some(frame) = f.next().await {
        match decode_frame(&frame?)? {
            ResponseFrame::Batch { paths, .. } => out.extend(paths),
            ResponseFrame::Done { .. } => break,
            ResponseFrame::Error { message } => return Err(message.into()),
        }
    }
    Ok(out)
}

async fn direct_scan(
    query: &str,
    limit: Option<u32>,
) -> Result<Vec<String>, Box<dyn std::error::Error + Send + Sync>> {
    let q = query.to_lowercase();
    let cap = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    let mut out = Vec::new();
    for result in ignore::Walk::new(".") {
        let entry = result?;
        if let Some(s) = entry.path().to_str() {
            if s.to_lowercase().contains(q.as_str()) {
                out.push(s.to_string());
                if out.len() >= cap {
                    break;
                }
            }
        }
    }
    Ok(out)
}
