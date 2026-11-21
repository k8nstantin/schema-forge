//! The API the perspectives read: schemas, a model, one object's SQL, and the right status when something is
//! missing or fails.

use std::sync::Arc;

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use schema_forge_core::{Schema, Target};
use schema_forge_store::Store;
use tower::ServiceExt as _;

fn fixture(name: &str) -> Schema {
    let path = format!("{}/../core/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("schema")
}

/// A store holding `orders` (PostgreSQL), as an import leaves it.
fn store(dir: &tempfile::TempDir) -> Arc<Store> {
    let store = Store::open(&dir.path().join("store.redb")).expect("open");
    store.create_schema("orders", Target::Postgres).expect("create");
    store.replace_model("orders", &fixture("orders_postgres.json"), "import", "import").expect("save");
    Arc::new(store)
}

async fn get(store: &Arc<Store>, uri: &str) -> (StatusCode, String) {
    let response = schema_forge_serve::app(store.clone())
        .oneshot(Request::get(uri).body(Body::empty()).expect("request"))
        .await
        .expect("response");
    let status = response.status();
    let body = to_bytes(response.into_body(), usize::MAX).await.expect("body");
    (status, String::from_utf8(body.to_vec()).expect("utf-8"))
}

#[tokio::test]
async fn the_perspectives_read_schemas_models_and_definitions() {
    let dir = tempfile::tempdir().expect("dir");
    let store = store(&dir);

    let (status, body) = get(&store, "/api/schemas").await;
    assert_eq!(status, StatusCode::OK);
    let list: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert_eq!(list[0]["name"], "orders");
    assert_eq!(list[0]["target"], "postgres");

    let (status, body) = get(&store, "/api/schemas/orders").await;
    assert_eq!(status, StatusCode::OK);
    let model: Schema = serde_json::from_str(&body).expect("a model");
    assert_eq!(model, fixture("orders_postgres.json"), "the model comes back as stored");

    let (status, body) = get(&store, "/api/schemas/orders/definition/t_orders").await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.starts_with("CREATE TABLE"), "the table's SQL: {body}");

    let (status, body) = get(&store, "/api/schemas/orders/shape").await;
    assert_eq!(status, StatusCode::OK);
    let shape: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert_eq!(shape["tables"].as_array().map(Vec::len), Some(2), "every table has its place");
    assert!(
        shape["links"].as_array().is_some_and(|l| l.iter().any(|x| x["declared"] == true)),
        "the declared foreign key is a link"
    );
}

#[tokio::test]
async fn what_is_missing_is_not_found_and_never_the_app() {
    let dir = tempfile::tempdir().expect("dir");
    let store = store(&dir);
    for uri in [
        "/api/schemas/nowhere",
        "/api/schemas/nowhere/definition/t_orders",
        "/api/schemas/nowhere/shape",
        "/api/schemas/nowhere/rules",
        "/api/schemas/orders/definition/t_nothing",
        "/api/nothing",
    ] {
        let (status, body) = get(&store, uri).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{uri}");
        let error: serde_json::Value =
            serde_json::from_str(&body).unwrap_or_else(|_| panic!("{uri}: json, not {body}"));
        assert!(error["error"].is_string(), "{uri}: {body}");
    }
    let (status, _) = get(&store, "/api/schemas/orders/definition/Not%20an%20id").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

async fn send(store: &Arc<Store>, method: &str, uri: &str, body: serde_json::Value) -> (StatusCode, serde_json::Value) {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .expect("request");
    let response = schema_forge_serve::app(store.clone()).oneshot(request).await.expect("response");
    let status = response.status();
    let bytes = to_bytes(response.into_body(), usize::MAX).await.expect("body");
    (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
}

#[tokio::test]
async fn rules_are_read_linked_and_refused_with_a_reason() {
    let dir = tempfile::tempdir().expect("dir");
    let store = store(&dir);

    let (status, body) = get(&store, "/api/rules").await;
    assert_eq!(status, StatusCode::OK);
    let catalog: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert!(catalog["rules"].as_array().is_some_and(|r| r.iter().any(|x| x["id"] == "cdc")));
    assert_eq!(catalog["maps"].as_array().map(Vec::len), Some(6));

    let (status, op) = send(
        &store,
        "POST",
        "/api/schemas/orders/rules/links",
        serde_json::json!({ "rule": "docs", "at": { "level": "schema" } }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{op}");
    assert_eq!(op["kind"], "link_rule");
    let (status, err) = send(
        &store,
        "POST",
        "/api/schemas/orders/rules/links",
        serde_json::json!({ "rule": "docs", "at": { "level": "table", "table": "t_orders" }, "off": true }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "an exception needs a reason");
    assert!(err["error"].as_str().is_some_and(|e| e.contains("reason")), "{err}");
    let hot = serde_json::json!({ "name": "hot", "tables": ["t_orders"] });
    let (status, _) = send(&store, "PUT", "/api/schemas/orders/rules/groups", hot.clone()).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "only a group there is can change");
    let (status, _) = send(&store, "POST", "/api/schemas/orders/rules/groups", hot.clone()).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(&store, "POST", "/api/schemas/orders/rules/groups", hot.clone()).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a new group never replaces one");
    let (status, _) = send(&store, "PUT", "/api/schemas/orders/rules/groups", hot).await;
    assert_eq!(status, StatusCode::OK);
    let (status, ops) = send(&store, "POST", "/api/schemas/orders/goals/postgres-iceberg", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::OK, "{ops}");
    assert_eq!(ops.as_array().map(Vec::len), Some(1), "the goal links its packs in one change");
    assert_eq!(ops[0]["change"]["packs"].as_array().map(Vec::len), Some(2), "{ops}");
    let (_, again) = send(&store, "POST", "/api/schemas/orders/goals/postgres-iceberg", serde_json::json!({})).await;
    assert_eq!(again, serde_json::json!([]), "nothing left to link");
    let (status, _) = send(&store, "POST", "/api/schemas/orders/goals/nothing", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, preview) = send(
        &store,
        "POST",
        "/api/schemas/orders/rules/preview",
        serde_json::json!([{ "rule": "scd2", "at": { "level": "schema" } }]),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(preview["tallies"]["scd2.columns"]["checked"].as_u64().is_some_and(|n| n > 0), "{preview}");
    let (status, body) = get(&store, "/api/schemas/orders/rules").await;
    assert_eq!(status, StatusCode::OK);
    let rules: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert_eq!(rules["links"].as_array().map(Vec::len), Some(3), "the preview stored nothing");
    assert_eq!(rules["groups"][0]["name"], "hot");
    assert!(rules["report"]["tallies"]["docs"]["checked"].as_u64().is_some_and(|n| n > 0));
    assert!(rules["report"]["tables"]["t_orders"]["applied"].as_array().is_some_and(|a| a.len() == 3));

    let (status, _) = send(
        &store,
        "POST",
        "/api/schemas/orders/rules/unlink",
        serde_json::json!({ "rule": "docs", "at": { "level": "schema" } }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(&store, "DELETE", "/api/schemas/orders/rules/groups/hot", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(
        &store,
        "POST",
        "/api/rules/global/links",
        serde_json::json!({ "rule": "pk", "at": { "level": "global" }, "locked": true }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = send(
        &store,
        "POST",
        "/api/schemas/orders/rules/links",
        serde_json::json!({ "rule": "pk.present", "at": { "level": "schema" }, "off": true, "reason": "no" }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "pk is locked for every schema");
}

/// One MCP call over the streamable HTTP endpoint; the reply's JSON-RPC message, read from its event stream.
/// The app is made once, as `serve` makes it: MCP sessions live in it.
async fn mcp(
    app: &axum::Router,
    session: Option<&str>,
    body: serde_json::Value,
) -> (Option<String>, serde_json::Value) {
    let mut request = Request::post("/mcp")
        .header("content-type", "application/json")
        .header("accept", "application/json, text/event-stream")
        .header("host", "127.0.0.1");
    if let Some(s) = session {
        request = request.header("mcp-session-id", s);
    }
    let response =
        app.clone().oneshot(request.body(Body::from(body.to_string())).expect("request")).await.expect("response");
    let session = response.headers().get("mcp-session-id").map(|v| v.to_str().expect("ascii").to_string());
    let bytes = to_bytes(response.into_body(), usize::MAX).await.expect("body");
    let text = String::from_utf8(bytes.to_vec()).expect("utf-8");
    let message = text
        .lines()
        .filter_map(|l| l.strip_prefix("data: "))
        .find_map(|d| serde_json::from_str::<serde_json::Value>(d).ok())
        .unwrap_or(serde_json::Value::Null);
    (session, message)
}

fn tool_text(reply: &serde_json::Value) -> String {
    reply["result"]["content"][0]["text"].as_str().unwrap_or_default().to_string()
}

#[tokio::test]
async fn the_agent_proposes_the_person_approves_and_the_rule_holds() {
    let dir = tempfile::tempdir().expect("dir");
    let store = store(&dir);
    let app = schema_forge_serve::app(store.clone());
    let init = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": { "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": { "name": "test", "version": "1" } } });
    let (session, reply) = mcp(&app, None, init).await;
    assert_eq!(reply["result"]["serverInfo"]["name"], "schema-forge");
    let session = session.expect("a session");
    mcp(&app, Some(&session), serde_json::json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })).await;

    let call = |id: u64, name: &str, arguments: serde_json::Value| serde_json::json!({ "jsonrpc": "2.0", "id": id, "method": "tools/call", "params": { "name": name, "arguments": arguments } });
    let (_, reply) = mcp(&app, Some(&session), call(2, "rules", serde_json::json!({ "schema": "orders" }))).await;
    assert!(tool_text(&reply).contains("No rules are linked"), "{reply}");

    let proposals = serde_json::json!({ "schema": "orders", "proposals": [
        { "kind": "new", "sentence": { "has_column": { "column": "id", "required": true } }, "at": "schema", "enforce": "hard", "why": "every table has one" },
        { "kind": "new", "sentence": { "columns": { "name": { "ends_with": "_at" }, "must": { "of_type": ["string"] } } }, "at": "schema", "enforce": "soft", "why": "?" }
    ] });
    let (_, reply) = mcp(&app, Some(&session), call(3, "propose_rules", proposals)).await;
    let text = tool_text(&reply);
    assert!(text.contains("#1 Every table has `id`, required"), "{text}");
    assert!(
        text.contains("#2") && text.contains("invalid"),
        "`string` is an Iceberg type, not a PostgreSQL one: {text}"
    );

    let (status, _) = send(&store, "POST", "/api/schemas/orders/proposals/2/approve", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "an invalid proposal cannot be approved");
    let (status, approved) =
        send(&store, "POST", "/api/schemas/orders/proposals/1/approve", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::OK, "{approved}");
    assert_eq!(approved["rule"], "custom.1");

    let (_, reply) = mcp(&app, Some(&session), call(4, "rules", serde_json::json!({ "schema": "orders" }))).await;
    assert!(tool_text(&reply).contains("@rule:custom.1"), "the agent sees the approved rule: {reply}");
    let (_, body) = get(&store, "/api/rules").await;
    assert!(body.contains("\"provenance\""), "the catalog says who proposed and approved it");

    // The approved rule is hard: a table without `id` is refused, with the rule and the reason; nothing lands.
    let table = |name: &str, columns: serde_json::Value| serde_json::json!({ "op": "add_table", "namespace": "public", "name": name, "columns": columns });
    let bad = serde_json::json!({ "schema": "orders", "operations": [table("notes", serde_json::json!([{ "name": "body", "type": "text" }]))] });
    let (_, reply) = mcp(&app, Some(&session), call(5, "change", bad)).await;
    assert_eq!(reply["result"]["isError"], true, "{reply}");
    assert!(tool_text(&reply).contains("custom.1"), "the refusal names the rule: {reply}");
    let good = serde_json::json!({ "schema": "orders", "operations": [
        table("notes", serde_json::json!([{ "name": "id", "type": "bigint", "nullable": false }, { "name": "body", "type": "varchar(200)" }])),
        { "op": "relate", "from": "notes", "columns": ["id"], "to": "orders", "to_columns": ["order_key"] }
    ] });
    let (_, reply) = mcp(&app, Some(&session), call(6, "change", good)).await;
    let text = tool_text(&reply);
    assert!(text.contains("added table `notes` with 2 columns") && text.contains("related `notes`"), "{reply}");
    let (_, body) = get(&store, "/api/schemas/orders").await;
    let model: Schema = serde_json::from_str(&body).expect("a model");
    let notes = model.tables.iter().find(|t| t.name == "notes").expect("notes landed");
    assert_eq!(notes.columns[1].data_type.length, Some(200), "the type was read as PostgreSQL writes it");
    let (status, _) = send(&store, "POST", "/api/schemas/orders/undo", serde_json::json!({})).await;
    assert_eq!(status, StatusCode::OK);
    let (_, body) = get(&store, "/api/schemas/orders").await;
    assert!(!body.contains("\"notes\""), "undone");
}
