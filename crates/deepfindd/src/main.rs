// SPDX-License-Identifier: MIT
//! deepfindd — resident daemon binary.

use df_ipc::{default_db, default_socket};

#[tokio::main]
async fn main() -> std::io::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    deepfindd::serve(&default_socket(), &default_db()).await
}
