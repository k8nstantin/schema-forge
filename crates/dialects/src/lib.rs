//! Reading and writing the targets' own SQL: PostgreSQL dumps and Iceberg DDL in, the same formats out.

pub mod cursor;
pub mod iceberg;
pub mod postgres;
pub mod report;
pub mod split;

pub use report::{Imported, Report};

/// The views, each after the views it reads (a cycle, which the model refuses, keeps the rest in model order).
pub(crate) fn views_in_order(schema: &schema_forge_core::Schema) -> Vec<&schema_forge_core::View> {
    let mut done: std::collections::HashSet<&schema_forge_core::Id> = std::collections::HashSet::new();
    let mut out = Vec::new();
    let mut left: Vec<&schema_forge_core::View> = schema.views.iter().collect();
    while !left.is_empty() {
        let before = left.len();
        left.retain(|v| {
            let ready = v.reads.iter().all(|r| done.contains(r) || !schema.views.iter().any(|x| &x.id == r));
            if ready {
                done.insert(&v.id);
                out.push(*v);
            }
            !ready
        });
        if left.len() == before {
            out.append(&mut left);
        }
    }
    out
}
