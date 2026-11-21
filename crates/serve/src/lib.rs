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
        .route("/api/schemas", get(schemas).post(new_schema))
        .route("/api/schemas/{name}/change", post(change))
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
        .route("/api/schemas/{name}/rules/groups", put(set_group).post(new_group))
        .route("/api/schemas/{name}/rules/groups/{group}", delete(remove_group))
        .route("/api/schemas/{name}/goals/{goal}", post(goal))
        .route("/api/schemas/{name}/rules/enforce", post(enforce))
        .route("/api/rules/global/enforce", post(enforce_global))
        .route("/api/schemas/{name}/proposals", get(proposals))
        .route("/api/schemas/{name}/undo", post(undo))
        .route("/api/schemas/{name}/operations", get(recent))
        .route("/api/schemas/{name}/turns", get(turns))
        .route("/api/schemas/{name}/turns/{n}/accept", post(accept_turn))
        .route("/api/schemas/{name}/turns/{n}/reject", post(reject_turn))
        .route("/api/schemas/{name}/proposals/{id}/approve", post(approve))
        .route("/api/schemas/{name}/proposals/{id}/reject", post(reject))
        .route("/api/schemas/{name}/proposals/{id}/enforce", post(proposal_enforce))
        .merge(
            Router::new()
                .nest_service("/mcp", schema_forge_mcp::service(store.clone()))
                .layer(axum::middleware::from_fn(agent_seen)),
        )
        .route("/api/workspace", get(workspace))
        .route("/api/events", get(events))
        .fallback(canvas)
        .with_state(store)
}

/// When the agent last reached the MCP, in milliseconds since the Unix epoch; 0 when it has not this run.
static AGENT_SEEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .and_then(|d| u64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

async fn agent_seen(req: axum::extract::Request, next: axum::middleware::Next) -> Response {
    AGENT_SEEN.store(now_ms(), std::sync::atomic::Ordering::Relaxed);
    next.run(req).await
}

/// The workspace: its folder (`~` for your home), and when the agent last reached the MCP.
async fn workspace(State(store): State<Arc<Store>>) -> Response {
    let folder = store.folder();
    let shown = std::env::var_os("HOME")
        .and_then(|h| folder.strip_prefix(h).ok().map(|rest| format!("~/{}", rest.display())))
        .unwrap_or_else(|| folder.display().to_string());
    let seen = AGENT_SEEN.load(std::sync::atomic::Ordering::Relaxed);
    axum::Json(serde_json::json!({ "folder": shown, "agent_seen": (seen > 0).then_some(seen), "now": now_ms() }))
        .into_response()
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
        schema_forge_store::Error::Rule(_) | schema_forge_store::Error::Refused(_) => {
            failed(StatusCode::BAD_REQUEST, e)
        }
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

/// Every rule (built in, and the workspace's own), goal and type map.
async fn catalog(State(store): State<Arc<Store>>) -> Response {
    match store.catalog() {
        Ok(c) => axum::Json(c).into_response(),
        Err(e) => store_failed(e),
    }
}

/// The schema's rules: the global links, its own links and groups, and the schema checked against them.
async fn schema_rules(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    let read = || -> schema_forge_store::Result<serde_json::Value> {
        let model = store.model(&name)?;
        let global = store.global_rules()?;
        let set = store.rules(&name)?;
        let report = rules::check_with(&store.catalog()?, &model, &global, &set);
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
        Ok(rules::check_with(&store.catalog()?, &model, &global, &set))
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
    done(store.set_group(&name, g, false, BY))
}

async fn new_group(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(g): axum::Json<Group>,
) -> Response {
    done(store.set_group(&name, g, true, BY))
}

async fn remove_group(State(store): State<Arc<Store>>, Path((name, group)): Path<(String, String)>) -> Response {
    done(store.remove_group(&name, &group, BY))
}

#[derive(serde::Deserialize)]
struct NewSchema {
    name: String,
    target: Target,
    #[serde(default)]
    about: Option<String>,
    #[serde(default)]
    iceberg_format: Option<u32>,
}

/// Makes an empty schema of a type.
async fn new_schema(State(store): State<Arc<Store>>, axum::Json(n): axum::Json<NewSchema>) -> Response {
    match store.create_schema_with(&n.name, n.target, n.about, n.iceberg_format) {
        Ok(info) => axum::Json(info).into_response(),
        Err(
            e @ (schema_forge_store::Error::SchemaExists(_)
            | schema_forge_store::Error::BadName(_)
            | schema_forge_store::Error::Rule(_)),
        ) => failed(StatusCode::BAD_REQUEST, e),
        Err(e) => store_failed(e),
    }
}

/// A change made by hand: operations as the agent writes them (types as text), and a yes to destructive ones.
/// Hard rules hold for a person too: to go ahead, the rule is turned soft first.
#[derive(serde::Deserialize)]
struct ByHand {
    operations: Vec<serde_json::Value>,
    #[serde(default)]
    confirm_destructive: bool,
}

async fn change(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(c): axum::Json<ByHand>,
) -> Response {
    let target = match store.model(&name) {
        Ok(m) => m.target,
        Err(e) => return store_failed(e),
    };
    let ops = match c
        .operations
        .into_iter()
        .enumerate()
        .map(|(i, v)| schema_forge_mcp::operation(target, v).map_err(|m| format!("operation {}: {m}", i + 1)))
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(ops) => ops,
        Err(m) => return failed(StatusCode::BAD_REQUEST, m),
    };
    match store.change(&name, &ops, c.confirm_destructive, BY) {
        Ok(ch) => axum::Json(serde_json::json!({
            "sequence": ch.operation.sequence,
            "summaries": ch.summaries,
            "soft": ch.soft,
        }))
        .into_response(),
        Err(e) => store_failed(e),
    }
}

/// The schema's turns, newest first, each with what its changes did.
async fn turns(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    let read = || -> schema_forge_store::Result<serde_json::Value> {
        let log = store.operations(&name)?;
        let out: Vec<serde_json::Value> = store
            .turns(&name)?
            .into_iter()
            .rev()
            .map(|t| {
                let changes: Vec<serde_json::Value> = t
                    .changes
                    .iter()
                    .filter_map(|s| log.iter().find(|o| o.sequence == *s))
                    .map(|o| serde_json::json!({ "sequence": o.sequence, "summaries": o.change["summaries"] }))
                    .collect();
                serde_json::json!({ "turn": t, "changes": changes })
            })
            .collect();
        Ok(serde_json::Value::Array(out))
    };
    match read() {
        Ok(v) => axum::Json(v).into_response(),
        Err(e) => store_failed(e),
    }
}

async fn accept_turn(State(store): State<Arc<Store>>, Path((name, n)): Path<(String, u64)>) -> Response {
    match store.accept_turn(&name, n, BY) {
        Ok(t) => axum::Json(t).into_response(),
        Err(e) => store_failed(e),
    }
}

async fn reject_turn(State(store): State<Arc<Store>>, Path((name, n)): Path<(String, u64)>) -> Response {
    match store.reject_turn(&name, n, BY) {
        Ok(t) => axum::Json(t).into_response(),
        Err(e) => store_failed(e),
    }
}

/// Undoes the schema's latest design change.
async fn undo(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    done(store.undo(&name, BY))
}

/// How a link holds: `{rule, at, enforce}`.
#[derive(serde::Deserialize)]
struct SetEnforce {
    rule: String,
    at: Scope,
    enforce: rules::Enforce,
}

async fn enforce(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::Json(e): axum::Json<SetEnforce>,
) -> Response {
    done(store.set_enforce(Rules::Schema(&name), &e.rule, &e.at, e.enforce, BY))
}

async fn enforce_global(State(store): State<Arc<Store>>, axum::Json(e): axum::Json<SetEnforce>) -> Response {
    done(store.set_enforce(Rules::Global, &e.rule, &e.at, e.enforce, BY))
}

/// The schema's proposals, each still open with the system's verdict on it.
async fn proposals(State(store): State<Arc<Store>>, Path(name): Path<String>) -> Response {
    match store.reviewed(&name) {
        Ok((_, all)) => axum::Json(
            all.into_iter()
                .map(|r| serde_json::json!({ "proposal": r.proposal, "verdict": r.verdict }))
                .collect::<Vec<_>>(),
        )
        .into_response(),
        Err(e) => store_failed(e),
    }
}

fn decided(r: schema_forge_store::Result<rules::review::Proposal>) -> Response {
    match r {
        Ok(p) => axum::Json(p).into_response(),
        Err(e) => store_failed(e),
    }
}

async fn approve(State(store): State<Arc<Store>>, Path((name, id)): Path<(String, u64)>) -> Response {
    decided(store.decide(&name, id, true, BY))
}

async fn reject(State(store): State<Arc<Store>>, Path((name, id)): Path<(String, u64)>) -> Response {
    decided(store.decide(&name, id, false, BY))
}

#[derive(serde::Deserialize)]
struct ProposalEnforce {
    enforce: rules::Enforce,
}

async fn proposal_enforce(
    State(store): State<Arc<Store>>,
    Path((name, id)): Path<(String, u64)>,
    axum::Json(e): axum::Json<ProposalEnforce>,
) -> Response {
    decided(store.set_proposal_enforce(&name, id, e.enforce, BY))
}

/// Links a goal's packs to the whole schema, those not in place yet, all or none.
/// How a goal's packs hold: `{enforce}`; each rule's default when left out.
#[derive(serde::Deserialize, Default)]
struct GoalHow {
    #[serde(default)]
    enforce: Option<rules::Enforce>,
}

async fn goal(
    State(store): State<Arc<Store>>,
    Path((name, goal)): Path<(String, String)>,
    body: Option<axum::Json<GoalHow>>,
) -> Response {
    let how = body.map(|b| b.0).unwrap_or_default();
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
    match store.link_packs(&name, packs, how.enforce, BY) {
        Ok(op) => axum::Json(op.into_iter().collect::<Vec<_>>()).into_response(),
        Err(e) => store_failed(e),
    }
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
            "at": change.operation.at,
            "summary": change.operation.change["summaries"].as_array().map(|s| {
                s.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join("; ")
            }),
        });
        Some(Ok(Event::default().event("change").data(data.to_string())))
    });
    Sse::new(stream).keep_alive(KeepAlive::default())
}

#[derive(serde::Deserialize)]
struct Last {
    #[serde(default = "ten")]
    last: usize,
}

const fn ten() -> usize {
    10
}

/// The schema's last changes, newest first: `?last=<n>`, ten by default.
async fn recent(
    State(store): State<Arc<Store>>,
    Path(name): Path<String>,
    axum::extract::Query(q): axum::extract::Query<Last>,
) -> Response {
    if let Err(e) = store.rules(&name) {
        return store_failed(e);
    }
    match store.recent(&name, q.last.min(500)) {
        Ok(ops) => axum::Json(ops).into_response(),
        Err(e) => store_failed(e),
    }
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
