-- 2_compaction_policy_add: version 2 of example, the first step of a rename: compaction becomes compaction_policy. Owner: example.
-- A rename takes two versions (decision additive-migrations). This one only adds: the new column, filled from the old in
-- the same transaction, so a build of version 1 still reads every row it knows. Version 3 removes the old column.
-- The store records the copy as a turn of its own (by migration), with its row and value changes, so the log stays whole.
ALTER TABLE engine_example.table_options
  ADD COLUMN compaction_policy TEXT CHECK (compaction_policy IN ('none', 'size', 'time'));
COMMENT ON COLUMN engine_example.table_options.compaction_policy IS 'how its files are compacted; NULL when not written';
UPDATE engine_example.table_options SET compaction_policy = compaction WHERE compaction IS NOT NULL;
