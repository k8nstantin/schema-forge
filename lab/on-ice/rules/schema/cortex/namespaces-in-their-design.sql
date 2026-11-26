-- namespaces-in-their-design: A namespace sits in a namespace of its own design. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_namespaces_in_their_design AS
SELECT 'namespaces-in-their-design' AS rule, (n.id)::text AS id FROM cortex.namespaces n JOIN cortex.namespaces p ON p.id = n.parent WHERE p.design <> n.design;

COMMENT ON VIEW cortex.broken_namespaces_in_their_design IS 'A namespace sits in a namespace of its own design.';
