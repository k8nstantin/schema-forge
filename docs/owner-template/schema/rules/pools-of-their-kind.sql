-- pools-of-their-kind: A storage pool is an object of the kind storage_pool. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_pools_of_their_kind AS
SELECT 'pools-of-their-kind' AS rule, (p.id)::text AS id FROM engine_example.storage_pools p JOIN cortex.objects o ON o.id = p.id WHERE o.kind <> 'storage_pool';

COMMENT ON VIEW engine_example.broken_pools_of_their_kind IS 'A storage pool is an object of the kind storage_pool.';
