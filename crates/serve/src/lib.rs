//! `schema-forge serve`: one local process that keeps the workspace and serves the canvas and its data, as
//! docs/api.md sets out. It asks the registry for each schema's engine and never names a database itself.

pub mod api;

use std::path::PathBuf;
use std::sync::Arc;

use axum::Router;
use axum::http::{Method, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{MethodFilter, MethodRouter, on};
use rust_embed::RustEmbed;
use schema_forge_engine::Registry;

/// Every route the server answers, as docs/api.md lists them: the one list the router is built from, and the one the
/// contract test holds against the document.
pub const ROUTES: &[(&str, &str)] = &[
    ("GET", "/api/engines"),
    ("GET", "/api/workspace"),
    ("GET", "/api/browse"),
    ("GET", "/api/schemas"),
    ("POST", "/api/schemas/import"),
    ("POST", "/api/schemas/live"),
    ("GET", "/api/schemas/{name}"),
    ("DELETE", "/api/schemas/{name}"),
    ("GET", "/api/schemas/{name}/report"),
    ("GET", "/api/schemas/{name}/definition/{object}"),
    ("GET", "/api/schemas/{name}/sql"),
    ("GET", "/api/connections"),
    ("PUT", "/api/connections/{name}"),
    ("DELETE", "/api/connections/{name}"),
    ("POST", "/api/connections/test"),
];

/// What the server holds: the workspace folder and the engines.
pub struct App {
    pub folder: PathBuf,
    pub registry: Registry,
}

type Shared = Arc<App>;

/// The handler of one route of [`ROUTES`].
///
/// # Panics
/// For a route that is not in [`ROUTES`]: a build mistake the contract test finds.
fn handler(method: &str, path: &str) -> MethodRouter<Shared> {
    let filter = match method {
        "GET" => MethodFilter::GET,
        "POST" => MethodFilter::POST,
        "PUT" => MethodFilter::PUT,
        "DELETE" => MethodFilter::DELETE,
        other => panic!("{other} {path}: not a method the API uses"),
    };
    assert!(ROUTES.contains(&(method, path)), "{method} {path} is not in ROUTES");
    // The handlers come with the server itself: until then each route says so.
    on(filter, || async { failed(StatusCode::NOT_IMPLEMENTED, "not built yet") })
}

/// The routes, over `app`.
pub fn router(app: Shared) -> Router {
    let mut paths: Vec<&str> = ROUTES.iter().map(|(_, p)| *p).collect();
    paths.dedup();
    let mut router = Router::new();
    for path in paths {
        let methods = ROUTES
            .iter()
            .filter(|(_, p)| *p == path)
            .map(|(m, _)| handler(m, path))
            .reduce(MethodRouter::merge)
            .expect("a path of ROUTES has a method");
        router = router.route(path, methods);
    }
    router.fallback(canvas).layer(axum::middleware::from_fn(local_only)).with_state(app)
}

/// Serves `app` on `listener` until the process ends.
///
/// # Errors
/// When the listener fails.
pub async fn serve(listener: tokio::net::TcpListener, app: Shared) -> std::io::Result<()> {
    axum::serve(listener, router(app)).await
}

/// Only this machine's own pages: a request whose Host is not the loopback address (a DNS-rebound page) or that a
/// page of another site sent (its Origin) is refused, so nothing on the web can list files, read them, or reach a
/// database through this server.
async fn local_only(req: axum::extract::Request, next: axum::middleware::Next) -> Response {
    let local = |h: &str| {
        let host = h.rsplit_once(':').filter(|(_, p)| p.chars().all(|c| c.is_ascii_digit())).map_or(h, |(h, _)| h);
        matches!(host, "127.0.0.1" | "localhost" | "[::1]")
    };
    let host_ok = req.headers().get(header::HOST).and_then(|v| v.to_str().ok()).is_none_or(local);
    let origin_ok = req
        .headers()
        .get(header::ORIGIN)
        .and_then(|v| v.to_str().ok())
        .is_none_or(|o| o.strip_prefix("http://").is_some_and(local));
    if host_ok && origin_ok {
        next.run(req).await
    } else {
        failed(StatusCode::FORBIDDEN, "only pages of this machine may use Schema Forge")
    }
}

fn failed(status: StatusCode, message: impl Into<String>) -> Response {
    (status, axum::Json(api::ApiError { error: message.into() })).into_response()
}

/// The canvas, built (`canvas/dist`) and carried inside the binary.
#[derive(RustEmbed)]
#[folder = "../../canvas/dist"]
#[allow_missing = true]
struct Canvas;

/// The canvas: a file it was built with, or its page for any address it routes itself. Nothing under `/api/` is the
/// canvas: an unknown call is 404.
async fn canvas(method: Method, uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    if path == "api" || path.starts_with("api/") {
        return failed(StatusCode::NOT_FOUND, format!("no such call: {method} /{path}"));
    }
    let (file, data) = match Canvas::get(path) {
        Some(f) if !path.is_empty() => (path, f),
        _ => match Canvas::get("index.html") {
            Some(f) => ("index.html", f),
            None => {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "The canvas is not built into this binary: run `npm ci && npm run build` in canvas/, then build again.",
                )
                    .into_response();
            }
        },
    };
    let mime = mime_guess::from_path(file).first_or_octet_stream();
    ([(header::CONTENT_TYPE, mime.as_ref().to_string())], data.data.into_owned()).into_response()
}
