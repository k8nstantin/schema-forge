-- subpartitions-of-subpartitioned-tables: A partition has named subpartitions only when its table is subpartitioned. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_subpartitions_of_subpartitioned_tables AS
SELECT 'subpartitions-of-subpartitioned-tables' AS rule, (s.id)::text AS id FROM engine_mysql.subpartitions s JOIN cortex.partitions p ON p.id = s.partition
  WHERE p.partitioning NOT IN (SELECT id FROM engine_mysql.subpartitionings);

COMMENT ON VIEW engine_mysql.broken_subpartitions_of_subpartitioned_tables IS 'A partition has named subpartitions only when its table is subpartitioned.';
