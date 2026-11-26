-- engine_example.table_options: what Example says of a table beyond the cortex: its storage format and how it is compacted. Owner: example.
-- Shape 1, options of a cortex part: one row at most per cortex row, its id that row's id. A row exists only when an option is written.
CREATE TABLE engine_example.table_options (
  id                 UUID NOT NULL PRIMARY KEY,                                                                     -- the table
  format             TEXT CHECK (format IN ('row', 'column')),                                                      -- how its rows are stored; NULL when not written
  frozen             BOOLEAN NOT NULL DEFAULT false,                                                                -- true when nothing in it may change (FROZEN)
  properties         JSONB,                                                                                         -- the properties its users name themselves (WITH PROPERTIES ('k' = 'v')), as an object; NULL for none
  compaction_policy  TEXT CHECK (compaction_policy IN ('none', 'size', 'time')),                                    -- how its files are compacted; NULL when not written
  design             UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE
);

COMMENT ON TABLE engine_example.table_options IS 'what Example says of a table beyond the cortex: its storage format and how it is compacted. Shape 1, options of a cortex part: one row at most per cortex row, its id that row''s id. A row exists only when an option is written.';
COMMENT ON COLUMN engine_example.table_options.id IS 'the table';
COMMENT ON COLUMN engine_example.table_options.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_example.table_options.format IS 'how its rows are stored; NULL when not written';
COMMENT ON COLUMN engine_example.table_options.frozen IS 'true when nothing in it may change (FROZEN)';
COMMENT ON COLUMN engine_example.table_options.properties IS 'the properties its users name themselves (WITH PROPERTIES (''k'' = ''v'')), as an object; NULL for none';
COMMENT ON COLUMN engine_example.table_options.compaction_policy IS 'how its files are compacted; NULL when not written';
