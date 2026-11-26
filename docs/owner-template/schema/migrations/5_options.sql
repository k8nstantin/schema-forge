-- 5_options: version 5 of example: what Example adds to one cortex row becomes that row's options (decision declared-options). Owner: example.
-- table_options and storage_pools each added one row's facts to a cortex object; those facts are now options of the
-- object (cortex.objects.options), declared as rows of cortex.option_declarations by this folder's seeds, so a new
-- option is a row, never a column. The rules that guarded the two tables go with them, and the triggers they put on
-- cortex.objects too. A real owner moves its rows' facts into the options in the same version, before it drops them.
DROP TRIGGER IF EXISTS "rule:engine_example.table_options_on_tables" ON cortex.objects;
DROP TRIGGER IF EXISTS "rule:engine_example.table_options_on_tables:again" ON cortex.objects;
DROP TRIGGER IF EXISTS "rule:engine_example.pools_of_their_kind" ON cortex.objects;
DROP TRIGGER IF EXISTS "rule:engine_example.pools_of_their_kind:again" ON cortex.objects;
DROP VIEW engine_example.broken_table_options_on_tables;
DROP VIEW engine_example.broken_pools_of_their_kind;
DROP TABLE engine_example.table_options;
DROP TABLE engine_example.storage_pools;
