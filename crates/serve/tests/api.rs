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
