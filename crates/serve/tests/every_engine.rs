//! Every flow of the API (docs/api.md), on every engine of the test registry: the shipped ones and the made-up one
//! built unlike them, so the server's shared code fails here wherever it assumes one engine. What each engine is
//! tested on (a sample file, and a connection where its live database needs no service) is data, in
//! tests/fixtures/engines.json, so this file names no engine.
//!
//! Each flow: the engine as it declares itself; a file read in, its report adding up; the schema listed, viewed with
//! every object and the shape of its tables, without problems; every object's definition and the whole schema's SQL,
//! which reads back as the same schema; then, where the live database needs no service, a connection saved without
//! its secret, listed with the engine's summary, tested step by step with a wrong secret and the right one, and read
//! into a schema as its file is; and everything removed again.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use http_body_util::BodyExt;
use schema_forge_engine::live::FieldKind;
use schema_forge_engine::{Engine, Input};
use schema_forge_serve::{App, router};
use serde_json::{Value, json};
use tower::ServiceExt;

fn root() -> PathBuf {
    std::fs::canonicalize(Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")).expect("the repository")
}

/// The server over a fresh workspace.
struct Server {
    router: axum::Router,
    folder: PathBuf,
}

impl Server {
    fn new(name: &str) -> Self {
        let folder = std::env::temp_dir().join(format!("schema-forge-every-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&folder);
        std::fs::create_dir_all(&folder).expect("a workspace");
        let router = router(Arc::new(App { folder: folder.clone(), registry: schema_forge_engines::for_tests() }));
        Self { router, folder }
    }

    async fn call(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Vec<u8>) {
        let req = Request::builder().method(method).uri(uri).header(header::HOST, "127.0.0.1:7410");
        let req = match body {
            Some(b) => req.header(header::CONTENT_TYPE, "application/json").body(Body::from(b.to_string())),
            None => req.body(Body::empty()),
        };
        let res = self.router.clone().oneshot(req.expect("a request")).await.expect("an answer");
        let status = res.status();
        (status, res.into_body().collect().await.expect("a body").to_bytes().to_vec())
    }

    /// A call that must succeed, as JSON.
    async fn json(&self, method: &str, uri: &str, body: Option<Value>) -> Value {
        let (s, bytes) = self.call(method, uri, body).await;
        let text = String::from_utf8_lossy(&bytes);
        assert!(s.is_success(), "{method} {uri}: {s} {text}");
        serde_json::from_slice(&bytes).unwrap_or_else(|e| panic!("{method} {uri}: not JSON ({e}): {text}"))
    }

    /// A call that must succeed, as text.
    async fn text(&self, uri: &str) -> String {
        let (s, bytes) = self.call("GET", uri, None).await;
        let text = String::from_utf8_lossy(&bytes).into_owned();
        assert!(s.is_success(), "GET {uri}: {s} {text}");
        text
    }

    /// A call that must be refused with `status` and say why.
    async fn refused(&self, method: &str, uri: &str, body: Option<Value>, status: StatusCode) -> String {
        let (s, bytes) = self.call(method, uri, body).await;
        let v: Value = serde_json::from_slice(&bytes).unwrap_or_default();
        assert_eq!(s, status, "{method} {uri}: {}", String::from_utf8_lossy(&bytes));
        let error = v["error"].as_str().unwrap_or_default().to_string();
        assert!(!error.is_empty(), "{method} {uri}: a refusal says why");
        error
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.folder);
    }
}

/// What tests/fixtures/engines.json gives each engine.
fn fixture(id: &str) -> Value {
    let all: Value = serde_json::from_str(
        &std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/engines.json"))
            .expect("the fixtures"),
    )
    .expect("JSON");
    let f = all[id].clone();
    assert!(f.is_object(), "tests/fixtures/engines.json says nothing of the engine `{id}`: every engine is tested");
    f
}

/// The values of a connection, with every path field made absolute from the repository's root.
fn values_of(engine: &dyn Engine, values: &Value) -> Value {
    let live = engine.live().expect("a live part");
    let mut out = serde_json::Map::new();
    for (k, v) in values.as_object().expect("values") {
        let is_path = live.fields().iter().any(|f| f.key == k && f.kind == FieldKind::Path);
        let v = v.as_str().expect("text");
        out.insert(k.clone(), json!(if is_path { root().join(v).display().to_string() } else { v.to_string() }));
    }
    Value::Object(out)
}

/// Each engine of the test registry, with its fixture.
fn engines() -> Vec<(String, Value)> {
    schema_forge_engines::for_tests().all().map(|e| (e.id().to_string(), fixture(e.id()))).collect()
}

#[tokio::test]
#[ignore = "step 3 builds the server's handlers (docs/api.md)"]
async fn every_engine_is_described_as_it_declares_itself() {
    let server = Server::new("engines");
    let described = server.json("GET", "/api/engines", None).await;
    let registry = schema_forge_engines::for_tests();
    let ids: Vec<&str> = described.as_array().expect("a list").iter().filter_map(|e| e["id"].as_str()).collect();
    assert_eq!(ids, registry.all().map(Engine::id).collect::<Vec<_>>());
    for e in registry.all() {
        let d = described.as_array().unwrap().iter().find(|d| d["id"] == e.id()).unwrap();
        assert_eq!(d["name"], e.name());
        assert_eq!(d["namespace_word"]["one"], e.namespace_word().one);
        assert_eq!(d["default_version"], e.default_version());
        assert_eq!(d["kinds"].as_array().map(Vec::len), Some(e.kinds().len()));
        assert_eq!(d["writes"], e.write().is_some());
        match e.live() {
            Some(live) => {
                let keys: Vec<&str> =
                    d["live"]["fields"].as_array().unwrap().iter().filter_map(|f| f["key"].as_str()).collect();
                assert_eq!(keys, live.fields().iter().map(|f| f.key).collect::<Vec<_>>());
            }
            None => assert!(d.get("live").is_none()),
        }
    }
}

#[tokio::test]
#[ignore = "step 3 builds the server's handlers (docs/api.md)"]
async fn every_engine_reads_a_file_in_and_writes_it_back() {
    let registry = schema_forge_engines::for_tests();
    for (id, fx) in engines() {
        let engine = registry.get(&id).expect("registered");
        let server = Server::new(&id);
        let file = root().join(fx["file"].as_str().expect("a sample file"));
        let name = format!("{id}-shop");
        let read = server
            .json("POST", "/api/schemas/import", Some(json!({ "path": file.display().to_string(), "name": name })))
            .await;
        assert_eq!(read["report"]["adds_up"], true, "{id}: {read}");
        assert_eq!(read["schema"]["engine"], id.as_str());
        // Read again under the same name: refused unless it replaces.
        server
            .refused(
                "POST",
                "/api/schemas/import",
                Some(json!({ "path": file.display().to_string(), "name": name })),
                StatusCode::BAD_REQUEST,
            )
            .await;

        let listed = server.json("GET", "/api/schemas", None).await;
        assert!(listed.as_array().unwrap().iter().any(|s| s["name"] == name.as_str() && s["engine"] == id.as_str()));

        // The view holds every object the engine read, each table in the shape, and no problems.
        let direct = engine.read().expect("reads").read(&Input::open(&file).expect("the file")).expect("reads");
        let view = server.json("GET", &format!("/api/schemas/{name}"), None).await;
        let objects = view["objects"].as_array().expect("objects");
        assert_eq!(objects.len(), direct.schema.objects.len(), "{id}");
        let shaped: Vec<&str> =
            view["shape"]["tables"].as_array().unwrap().iter().filter_map(|t| t["table"].as_str()).collect();
        for o in objects {
            assert_eq!(o["table"].as_bool(), Some(shaped.contains(&o["id"].as_str().unwrap())), "{id}: {o}");
        }
        assert_eq!(view["problems"], json!([]), "{id}");
        assert_eq!(view["summary"]["namespace_word"]["one"], engine.namespace_word().one);

        let report = server.json("GET", &format!("/api/schemas/{name}/report"), None).await;
        assert_eq!(report, read["report"]);

        // Every object's definition, and the whole schema, which reads back as the same schema.
        for o in objects {
            let def = server.text(&format!("/api/schemas/{name}/definition/{}", o["id"].as_str().unwrap())).await;
            assert!(!def.trim().is_empty(), "{id}: {} has no definition", o["name"]);
        }
        server
            .refused("GET", &format!("/api/schemas/{name}/definition/o_not_there"), None, StatusCode::NOT_FOUND)
            .await;
        let sql = server.text(&format!("/api/schemas/{name}/sql")).await;
        let back = std::env::temp_dir().join(format!("schema-forge-back-{id}-{}", std::process::id()));
        std::fs::write(&back, &sql).expect("written");
        let again = server
            .json(
                "POST",
                "/api/schemas/import",
                Some(json!({ "path": back.display().to_string(), "name": format!("{name}-again") })),
            )
            .await;
        std::fs::remove_file(&back).expect("removed");
        let again_view = server.json("GET", &format!("/api/schemas/{name}-again"), None).await;
        assert_eq!(again_view["objects"], view["objects"], "{id}: written and read back, it is the same schema");
        assert_eq!(again["report"]["adds_up"], true);

        server.json("DELETE", &format!("/api/schemas/{name}"), None).await;
        server.refused("GET", &format!("/api/schemas/{name}"), None, StatusCode::NOT_FOUND).await;
    }
}

#[tokio::test]
#[ignore = "step 3 builds the server's handlers (docs/api.md)"]
async fn every_engine_with_a_live_fixture_is_connected_tested_and_read() {
    let registry = schema_forge_engines::for_tests();
    let mut tried = 0;
    for (id, fx) in engines() {
        let Some(live_fx) = fx.get("live") else { continue };
        tried += 1;
        let engine = registry.get(&id).expect("registered");
        let live = engine.live().expect("a live part");
        let server = Server::new(&format!("{id}-live"));
        let values = values_of(engine, &live_fx["values"]);
        let secret = live_fx["secret"].as_str().expect("a secret");
        let conn = format!("{id}-conn");

        // A secret field in a profile is refused; without it, the profile is kept.
        if let Some(secret_field) = live.fields().iter().find(|f| f.kind == FieldKind::Secret) {
            let mut with_secret = values.clone();
            with_secret[secret_field.key] = json!(secret);
            server
                .refused(
                    "PUT",
                    &format!("/api/connections/{conn}"),
                    Some(json!({ "engine": id, "values": with_secret })),
                    StatusCode::BAD_REQUEST,
                )
                .await;
        }
        server.json("PUT", &format!("/api/connections/{conn}"), Some(json!({ "engine": id, "values": values }))).await;
        let listed = server.json("GET", "/api/connections", None).await;
        let c = listed.as_array().unwrap().iter().find(|c| c["name"] == conn.as_str()).expect("listed").clone();
        let profile = schema_forge_engine::live::Profile::new(
            values.as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect(),
        );
        assert_eq!(c["summary"], live.summary(&profile), "{id}: the engine's own summary");
        assert!(!c.to_string().contains(secret), "{id}: a listed connection never holds its secret");

        // Tested with a wrong secret, it fails at a step and skips the rest; with the right one, it passes.
        let wrong =
            server.json("POST", "/api/connections/test", Some(json!({ "name": conn, "secret": "wrong" }))).await;
        assert_eq!(wrong["outcome"], "failed", "{id}: {wrong}");
        assert_eq!(wrong["steps"].as_array().map(Vec::len), Some(5));
        let right = server.json("POST", "/api/connections/test", Some(json!({ "name": conn, "secret": secret }))).await;
        assert_ne!(right["outcome"], "failed", "{id}: {right}");
        let listed = server.json("GET", "/api/connections", None).await;
        assert!(listed[0]["tested"]["outcome"].is_string(), "{id}: a saved connection keeps how its test went");
        assert!(!listed.to_string().contains(secret));

        // Read live, and read from the file: the same schema, the shelves (or databases) `which` names.
        let which = live_fx["which"].clone();
        let read = server
            .json(
                "POST",
                "/api/schemas/live",
                Some(json!({ "connection": conn, "secret": secret, "which": which, "name": format!("{id}-live") })),
            )
            .await;
        assert_eq!(read["report"]["adds_up"], true);
        assert_eq!(read["schema"]["source"]["kind"], "live");
        assert_eq!(read["schema"]["source"]["summary"], live.summary(&profile));
        let view = server.json("GET", &format!("/api/schemas/{id}-live"), None).await;
        let names: Vec<&str> =
            view["namespaces"].as_array().unwrap().iter().filter_map(|n| n["name"].as_str()).collect();
        let wanted: Vec<&str> = which.as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert_eq!(names, wanted, "{id}: only what `which` names is read");
        let workspace_text = walk(&server.folder);
        assert!(!workspace_text.contains(secret), "{id}: the secret is written nowhere in the workspace");

        server.json("DELETE", &format!("/api/connections/{conn}"), None).await;
        assert_eq!(server.json("GET", "/api/connections", None).await, json!([]));
    }
    assert!(tried > 0, "at least one engine's live flow runs without a service");
}

/// Everything under `dir`, as text.
fn walk(dir: &Path) -> String {
    let mut out = String::new();
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.push_str(&walk(&p));
        } else {
            out.push_str(&String::from_utf8_lossy(&std::fs::read(&p).unwrap_or_default()));
        }
    }
    out
}
