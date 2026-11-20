//! `schema-forge serve`: one local process that holds the workspace's store and serves the perspectives, their
//! data, and every change as it lands.

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;

use axum::Router;
use axum::extract::{Path, State};
use axum::http::{StatusCode, Uri, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use rust_embed::RustEmbed;
use schema_forge_core::rules::{self, Group, Link, Scope};
use schema_forge_core::{Id, Target};
use schema_forge_store::{Rules, Store};
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::BroadcastStream;

/// The perspectives, built (`canvas/dist`) and carried inside the binary.
#[derive(RustEmbed)]
#[folder = "../../canvas/dist"]
#[allow_missing = true]
struct Canvas;

/// The routes, over `store`.
pub fn app(store: Arc<Store>) -> Router {
    Router::new()
        .route("/api/schemas", get(schemas))
        .route("/api/schemas/{name}", get(model))
        .route("/api/schemas/{name}/definition/{id}", get(definition))
        .route("/api/schemas/{name}/shape", get(shape))
        .route("/api/rules", get(catalog))
        .route("/api/rules/global/links", post(link_global))
        .route("/api/rules/global/unlink", post(unlink_global))
        .route("/api/schemas/{name}/rules", get(schema_rules))
        .route("/api/schemas/{name}/rules/links", post(link))
        .route("/api/schemas/{name}/rules/preview", post(preview))
        .route("/api/schemas/{name}/rules/unlink", post(unlink))
        .route("/api/schemas/{name}/rules/groups", put(set_group))
        .route("/api/schemas/{name}/rules/groups/{group}", delete(remove_group))
        .route("/api/schemas/{name}/goals/{goal}", post(goal))
        .route("/api/events", get(events))
        .fallback(canvas)
        .with_state(store)
}

/// Serves on `127.0.0.1:port` until the process ends; `ready` hears the address once it is listening.
///
/// # Errors
/// When the port cannot be taken.
pub async fn serve(store: Arc<Store>, port: u16, ready: impl FnOnce(SocketAddr)) -> Result<(), String> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port)).await.map_err(|e| format!("port {port}: {e}"))?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;
    ready(addr);
    axum::serve(listener, app(store)).await.map_err(|e| e.to_string())
}

fn failed(status: StatusCode, message: impl ToString) -> Response {
    (status, axum::Json(serde_json::json!({ "error": message.to_string() }))).into_response()
}

async fn schemas(State(store): State<Arc<Store>>) -> Response {
    match store.schemas() {
        Ok(list) => axum::Json(list).into_response(),
        Err(e) => failed(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

/// A store error as a response: an unknown schema is not found, a rule change that does not hold is the
/// request's fault, anything else is the server's failure.
fn store_failed(e: schema_forge_store::Error) -> Response {
    match e {
        schema_forge_store::Error::NoSchema(_) => failed(StatusCode::NOT_FOUND, e),
        schema_forge_store::Error::Rule(_) => failed(StatusCode::BAD_REQUEST, e),
        e => failed(StatusCode::INTERNAL_SERVER_ERROR, e),
    }
}

async fn model(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    match store.model(&name) {
        Ok(m) => axum::Json(m).into_response(),
        Err(e) => store_failed(e),
    }
}

/// The schema as the perspectives show it: families, stacked copies and the links between tables.
async fn shape(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    match store.model(&name) {
        Ok(m) => axum::Json(schema_forge_core::shape(&m)).into_response(),
        Err(e) => store_failed(e),
    }
}

/// Who a change made through the perspectives is recorded as.
const BY: &str = "you";

/// Every built-in rule, goal and type map.
async fn catalog() -> Response {
    axum::Json(rules::catalog()).into_response()
}

/// The schema's rules: the global links, its own links and groups, and the schema checked against them.
async fn schema_rules(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    let read = || -> schema_forge_store::Result<serde_json::Value> {
        let model = store.model(&name)?;
        let global = store.global_rules()?;
        let set = store.rules(&name)?;
        let report = rules::check(&model, &global, &set);
        Ok(serde_json::json!({ "global": global, "links": set.links, "groups": set.groups, "report": report }))
    };
    match read() {
        Ok(v) => axum::Json(v).into_response(),
        Err(e) => store_failed(e),
    }
}

/// What the schema would break if `links` were added to its own: nothing is stored.
async fn preview(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(links): axum::Json<Vec<Link>>,
) -> Response {
    let read = || -> schema_forge_store::Result<rules::Report> {
        let model = store.model(&name)?;
        let global = store.global_rules()?;
        let mut set = store.rules(&name)?;
        set.links.extend(links);
        Ok(rules::check(&model, &global, &set))
    };
    match read() {
        Ok(r) => axum::Json(r).into_response(),
        Err(e) => store_failed(e),
    }
}

fn done(r: schema_forge_store::Result<schema_forge_store::Operation>) -> Response {
    match r {
        Ok(op) => axum::Json(op).into_response(),
        Err(e) => store_failed(e),
    }
}

/// A link or exception for one schema.
async fn link(State(store): State<Arc<Store>>, Path(name): Path<String>, axum::Json(l): axum::Json<Link>) -> Response {
    done(store.link_rule(Rules::Schema(&name), l, BY))
}

/// What to take away: the rule and the level it is linked at.
#[derive(serde::Deserialize)]
struct Unlink {
    rule: String,
    at: Scope,
}

async fn unlink(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(u): axum::Json<Unlink>,
) -> Response {
    done(store.unlink_rule(Rules::Schema(&name), &u.rule, &u.at, BY))
}

async fn link_global(State(store): State<Arc<Store>>, axum::Json(l): axum::Json<Link>) -> Response {
    done(store.link_rule(Rules::Global, l, BY))
}

async fn unlink_global(State(store): State<Arc<Store>>, axum::Json(u): axum::Json<Unlink>) -> Response {
    done(store.unlink_rule(Rules::Global, &u.rule, &u.at, BY))
}

async fn set_group(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(g): axum::Json<Group>,
) -> Response {
    done(store.set_group(&name, g, BY))
}

async fn remove_group(State(store): State<Arc<Store>>, Path((name, group)): Path<(String, String)>) -> Response {
    done(store.remove_group(&name, &group, BY))
}

/// Links a goal's packs to the whole schema, those not linked there yet.
async fn goal(State(store): State<Arc<Store>>, Path((name, goal)): Path<(String, String)>) -> Response {
    let Some(g) = rules::catalog().goals.iter().find(|g| g.id == goal) else {
        return failed(StatusCode::NOT_FOUND, format!("there is no goal `{goal}`"));
    };
    let target = match store.schemas() {
        Ok(list) => match list.into_iter().find(|s| s.name == name) {
            Some(s) => s.target,
            None => return failed(StatusCode::NOT_FOUND, format!("there is no schema `{name}`")),
        },
        Err(e) => return store_failed(e),
    };
    let Some((_, packs)) = g.packs.iter().find(|(t, _)| *t == target) else {
        return failed(StatusCode::BAD_REQUEST, format!("`{}` is not for a {target:?} schema", g.title));
    };
    let linked = match store.rules(&name) {
        Ok(set) => set.links,
        Err(e) => return store_failed(e),
    };
    let mut ops = Vec::new();
    for p in packs.iter().filter(|p| !linked.iter().any(|l| l.rule == **p && l.at == Scope::Schema)) {
        let l = Link { rule: (*p).to_string(), at: Scope::Schema, off: false, locked: false, reason: None };
        match store.link_rule(Rules::Schema(&name), l, BY) {
            Ok(op) => ops.push(op),
            Err(e) => return store_failed(e),
        }
    }
    axum::Json(ops).into_response()
}

/// One object's SQL, as its target writes it.
async fn definition(State(store): State<Arc<Store>>, Path((name, id)): Path<(String, String)>) -> Response {
    let model = match store.model(&name) {
        Ok(m) => m,
        Err(e) => return store_failed(e),
    };
    let Ok(id) = Id::try_from(id) else { return failed(StatusCode::BAD_REQUEST, "not an id") };
    let sql = match model.target {
        Target::Postgres => schema_forge_dialects::postgres::definition(&model, &id),
        Target::Iceberg => schema_forge_dialects::iceberg::definition(&model, &id),
        Target::Mysql => return failed(StatusCode::NOT_IMPLEMENTED, "MySQL definitions are not written yet"),
    };
    match sql {
        Some(sql) => ([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], sql).into_response(),
        None => failed(StatusCode::NOT_FOUND, format!("no object `{id}` in `{name}`")),
    }
}

/// Every change, as it is committed: `{schema, sequence, kind, by}`.
async fn events(State(store): State<Arc<Store>>) -> Sse<impl tokio_stream::Stream<Item = Result<Event, Infallible>>> {
    let stream = BroadcastStream::new(store.subscribe()).filter_map(|change| {
        let change = change.ok()?;
        let data = serde_json::json!({
            "schema": change.schema,
            "sequence": change.operation.sequence,
            "kind": change.operation.kind,
            "by": change.operation.by,
        });
        Some(Ok(Event::default().event("change").data(data.to_string())))
    });
    Sse::new(stream).keep_alive(KeepAlive::default())
}

/// The built perspectives; any path that is not a file is the app itself, except under `/api`, where a path no
/// route takes is not found.
async fn canvas(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    if path == "api" || path.starts_with("api/") {
        return failed(StatusCode::NOT_FOUND, format!("no such endpoint `{}`", uri.path()));
    }
    let (file, content) = match Canvas::get(if path.is_empty() { "index.html" } else { path }) {
        Some(c) => (if path.is_empty() { "index.html" } else { path }, c),
        None => match Canvas::get("index.html") {
            Some(c) => ("index.html", c),
            None => {
                return failed(
                    StatusCode::NOT_FOUND,
                    "the perspectives are not built into this binary: run `npm run build` in canvas/, then build again",
                );
            }
        },
    };
    let mime = mime_guess::from_path(file).first_or_octet_stream();
    ([(header::CONTENT_TYPE, mime.as_ref().to_string())], content.data).into_response()
}
