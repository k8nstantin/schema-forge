//! The server against its contract, docs/api.md: the routes it answers are the ones the document lists, the canvas's
//! TypeScript is what the Rust types say, and nothing but this machine is answered.

use std::path::Path;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use http_body_util::BodyExt;
use schema_forge_serve::{App, ROUTES, api, router};
use tower::ServiceExt;

fn root() -> &'static Path {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."))
}

/// The routes docs/api.md lists, from its table: `| \`GET\` | \`/api/engines\` | …`.
fn documented() -> Vec<(String, String)> {
    let doc = std::fs::read_to_string(root().join("docs/api.md")).expect("docs/api.md");
    doc.lines()
        .filter_map(|l| {
            let cells: Vec<&str> = l.split('|').map(str::trim).collect();
            let method = cells.get(1)?.strip_prefix('`')?.strip_suffix('`')?;
            let path = cells.get(2)?.strip_prefix('`')?.strip_suffix('`')?;
            path.starts_with("/api/").then(|| (method.to_string(), path.to_string()))
        })
        .collect()
}

#[test]
fn the_server_answers_exactly_the_routes_the_document_lists() {
    let doc = documented();
    let code: Vec<(String, String)> = ROUTES.iter().map(|(m, p)| ((*m).to_string(), (*p).to_string())).collect();
    assert!(!doc.is_empty(), "docs/api.md lists no routes");
    let missing: Vec<_> = doc.iter().filter(|r| !code.contains(r)).collect();
    let undocumented: Vec<_> = code.iter().filter(|r| !doc.contains(r)).collect();
    assert!(missing.is_empty(), "documented, but the server does not answer them: {missing:?}");
    assert!(undocumented.is_empty(), "the server answers them, but docs/api.md does not list them: {undocumented:?}");
}

fn app() -> axum::Router {
    let folder = std::env::temp_dir().join(format!("schema-forge-contract-{}", std::process::id()));
    router(Arc::new(App { folder, registry: schema_forge_engines::for_tests() }))
}

async fn call(method: &str, uri: &str, host: &str, origin: Option<&str>) -> (StatusCode, String) {
    let mut req = Request::builder().method(method).uri(uri).header(header::HOST, host);
    if let Some(o) = origin {
        req = req.header(header::ORIGIN, o);
    }
    let res = app().oneshot(req.body(Body::empty()).expect("a request")).await.expect("an answer");
    let status = res.status();
    let body = res.into_body().collect().await.expect("a body").to_bytes();
    (status, String::from_utf8_lossy(&body).into_owned())
}

const HERE: &str = "127.0.0.1:7410";

#[tokio::test]
async fn every_route_is_answered_and_nothing_else_under_api() {
    for (method, path) in ROUTES {
        let uri = path.replace("{name}", "shop").replace("{object}", "o_orders");
        let (s, body) = call(method, &uri, HERE, None).await;
        assert!(!body.contains("no such call"), "{method} {uri} is not routed: {s} {body}");
    }
    let (s, body) = call("GET", "/api/nothing", HERE, None).await;
    assert_eq!(s, StatusCode::NOT_FOUND);
    assert!(body.contains("no such call"), "{body}");
}

#[tokio::test]
async fn only_this_machine_is_answered() {
    assert_eq!(call("GET", "/api/engines", HERE, Some("http://evil.test")).await.0, StatusCode::FORBIDDEN);
    assert_eq!(call("GET", "/api/engines", "rebound.test:7410", None).await.0, StatusCode::FORBIDDEN);
    assert_ne!(call("GET", "/api/engines", HERE, Some("http://localhost:5173")).await.0, StatusCode::FORBIDDEN);
}

#[test]
fn the_canvas_types_are_what_the_rust_types_say() {
    let path = root().join("canvas/src/api/types.ts");
    let want = api::typescript();
    if std::env::var_os("UPDATE_TYPES").is_some() {
        std::fs::create_dir_all(path.parent().expect("a folder")).expect("the folder");
        std::fs::write(&path, &want).expect("written");
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        have == want,
        "canvas/src/api/types.ts is stale: run `UPDATE_TYPES=1 cargo test -p schema-forge-serve --test contract`"
    );
}
