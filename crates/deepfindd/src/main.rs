// SPDX-License-Identifier: MIT
//! deepfindd — resident daemon. Holds the pread DB handle, serves the Unix socket.
//!
//! Stub scaffold; socket server + query pool land in Step 4.

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    tracing::info!("deepfindd — Step 0 scaffold (no socket yet)");
}
