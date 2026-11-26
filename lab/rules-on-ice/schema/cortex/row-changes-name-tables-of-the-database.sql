-- row-changes-name-tables-of-the-database: The log names only tables of this database, each with its namespace. Owner: cortex.
-- The rows breaking it. cortex.enforce_rules('cortex') makes the database refuse any commit while it has one.
CREATE VIEW cortex.broken_row_changes_name_tables_of_the_database AS
SELECT 'row-changes-name-tables-of-the-database' AS rule, (r.id)::text AS id FROM cortex.row_changes r
  WHERE to_regclass(r.table_name) IS NULL;

COMMENT ON VIEW cortex.broken_row_changes_name_tables_of_the_database IS 'The log names only tables of this database, each with its namespace.';
