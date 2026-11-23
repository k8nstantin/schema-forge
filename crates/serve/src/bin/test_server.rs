//! The test server: `schema-forge serve` with the test registry (the shipped engines, and the made-up one built unlike
//! them), over the workspace folder given. The canvas's browser tests run against it (canvas/playwright.config.ts);
//! no build ships it.
//!
//! `schema-forge-test-server <port> <workspace folder>`

use std::sync::Arc;

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let [_, port, folder] = args.as_slice() else {
        eprintln!("usage: schema-forge-test-server <port> <workspace folder>");
        std::process::exit(2);
    };
    let port: u16 = port.parse().map_err(|e| std::io::Error::other(format!("{port}: {e}")))?;
    std::fs::create_dir_all(folder)?;
    let app = Arc::new(schema_forge_serve::App { folder: folder.into(), registry: schema_forge_engines::for_tests() });
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
    println!("test server on http://127.0.0.1:{port}/ over {folder}");
    schema_forge_serve::serve(listener, app).await
}
