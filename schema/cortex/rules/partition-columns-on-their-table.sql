-- partition-columns-on-their-table: Every column a table is partitioned or ordered by is a column of that table. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_partition_columns_on_their_table AS
SELECT 'partition-columns-on-their-table' AS rule, (f.id)::text AS id FROM cortex.partition_fields f
  JOIN cortex.columns c ON c.id = f."column" WHERE c.object <> f.partitioning
UNION ALL
SELECT 'partition-columns-on-their-table', (o.id)::text FROM cortex.sort_fields o
  JOIN cortex.columns c ON c.id = o."column" WHERE c.object <> o.object;

COMMENT ON VIEW cortex.broken_partition_columns_on_their_table IS 'Every column a table is partitioned or ordered by is a column of that table.';
