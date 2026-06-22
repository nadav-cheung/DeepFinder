// SPDX-License-Identifier: MIT
//! deepfind — thin CLI client. Connects to the daemon over a Unix socket; falls
//! back to `--direct` online scan when the daemon is unavailable or stale.
//!
//! Stub scaffold; IPC client + --direct land in Step 4.

use clap::Parser;

#[derive(Debug, Parser)]
#[command(name = "deepfind", version, about = "Fast local file search (Rust)")]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Debug, clap::Subcommand)]
enum Cmd {
    /// Build / rebuild the index DB.
    Index,
    /// Run the resident daemon.
    Daemon,
    /// Daemon health + DB stats.
    Status,
}

fn main() {
    let cli = Cli::parse();
    eprintln!("deepfind — Step 0 scaffold; subcommand = {:?}", cli.cmd);
}
