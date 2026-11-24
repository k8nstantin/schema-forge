-- 3_compaction_policy_drop_old: version 3 of example, the second step of the rename: the old column goes. Owner: example.
-- Shipped in a later release than version 2, once no supported build reads compaction; the table file
-- schema/table_options.sql is changed in the same design session, so applying versions 1 to 3 to an empty database gives
-- exactly the table files.
ALTER TABLE engine_example.table_options DROP COLUMN compaction;
