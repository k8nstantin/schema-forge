-- 1_tables: version 1 of example, frozen: its table files and its rules exactly as version 1 shipped them, the tables in
-- the order of their foreign keys, ties by file name. Written once, by the design session that wrote version 2, and
-- never edited again (its checksum is in every database that applied it). Owner: example.
CREATE SCHEMA engine_example;

-- engine_example.column_codecs: the codecs a column's values pass through, in order. Owner: example.
-- Shape 2, an ordered list: many rows per cortex row, each numbered from id_counters and placed by an order key.
CREATE TABLE engine_example.column_codecs (
  id        TEXT    NOT NULL PRIMARY KEY,                                              -- <column>.codec<n>, n given once from id_counters and never reused: c_orders_total.codec1
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,         -- the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                     -- its place among the column's codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  codec     TEXT    NOT NULL CHECK (codec IN ('delta', 'dictionary', 'zstd', 'lz4')),  -- the codec
  level     INTEGER CHECK (level BETWEEN 1 AND 22),                                    -- its level, for a codec that has one; NULL for its default
  UNIQUE ("column", position),
  CHECK (substr(id, 1, length("column") + 6) = "column" || '.codec' AND substr(id, length("column") + 7) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_example.column_codecs IS 'the codecs a column''s values pass through, in order. Shape 2, an ordered list: many rows per cortex row, each numbered from id_counters and placed by an order key.';
COMMENT ON COLUMN engine_example.column_codecs.id IS '<column>.codec<n>, n given once from id_counters and never reused: c_orders_total.codec1';
COMMENT ON COLUMN engine_example.column_codecs."column" IS 'the column';
COMMENT ON COLUMN engine_example.column_codecs.position IS 'its place among the column''s codecs; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.column_codecs.codec IS 'the codec';
COMMENT ON COLUMN engine_example.column_codecs.level IS 'its level, for a codec that has one; NULL for its default';

-- engine_example.nested_fields: the fields inside a column of a nested type (a struct of structs), as a tree. Owner: example.
-- Shape 5, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a
-- column's whole tree is one query and deleting the column deletes it.
CREATE TABLE engine_example.nested_fields (
  id        TEXT    NOT NULL PRIMARY KEY,                                            -- <column>.field<n>, n given once from id_counters and never reused: c_events_payload.field3
  "column"  TEXT    NOT NULL REFERENCES cortex.columns (id) ON DELETE CASCADE,       -- the column the tree belongs to
  parent    TEXT    REFERENCES engine_example.nested_fields (id) ON DELETE CASCADE,  -- the field it sits in; NULL at the top of the column
  position  NUMERIC NOT NULL CHECK (position > 0),                                   -- its place among its parent's fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                              -- its name
  type      TEXT    NOT NULL CHECK (length(type) >= 1),                              -- its type, as the engine writes it
  CHECK (parent IS NULL OR parent <> id),
  CHECK (substr(id, 1, length("column") + 6) = "column" || '.field' AND substr(id, length("column") + 7) ~ '^[1-9][0-9]*$')
);
CREATE UNIQUE INDEX nested_fields_place ON engine_example.nested_fields ("column", coalesce(parent, ''), position);  -- one field per place, at the top too

COMMENT ON TABLE engine_example.nested_fields IS 'the fields inside a column of a nested type (a struct of structs), as a tree. Shape 5, a tree: each row names its parent row, or none at the top; the column it belongs to is on every row, so a column''s whole tree is one query and deleting the column deletes it.';
COMMENT ON COLUMN engine_example.nested_fields.id IS '<column>.field<n>, n given once from id_counters and never reused: c_events_payload.field3';
COMMENT ON COLUMN engine_example.nested_fields."column" IS 'the column the tree belongs to';
COMMENT ON COLUMN engine_example.nested_fields.parent IS 'the field it sits in; NULL at the top of the column';
COMMENT ON COLUMN engine_example.nested_fields.position IS 'its place among its parent''s fields; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.nested_fields.name IS 'its name';
COMMENT ON COLUMN engine_example.nested_fields.type IS 'its type, as the engine writes it';

-- engine_example.storage_pools: a storage pool, a kind of object only Example has (CREATE POOL). Owner: example.
-- Shape 3, an engine-only kind: the object is a cortex row of the kind storage_pool, which Example declares in object_kinds;
-- what only a pool has is here, one row per pool.
CREATE TABLE engine_example.storage_pools (
  id        TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the pool, an object of the kind storage_pool
  location  TEXT    NOT NULL CHECK (length(location) >= 1),                                 -- where its files are, as written
  quota_gb  INTEGER CHECK (quota_gb >= 1)                                                   -- how much it may hold, in GB; NULL for no limit
);

COMMENT ON TABLE engine_example.storage_pools IS 'a storage pool, a kind of object only Example has (CREATE POOL). Shape 3, an engine-only kind: the object is a cortex row of the kind storage_pool, which Example declares in object_kinds; what only a pool has is here, one row per pool.';
COMMENT ON COLUMN engine_example.storage_pools.id IS 'the pool, an object of the kind storage_pool';
COMMENT ON COLUMN engine_example.storage_pools.location IS 'where its files are, as written';
COMMENT ON COLUMN engine_example.storage_pools.quota_gb IS 'how much it may hold, in GB; NULL for no limit';

-- engine_example.table_options: what Example says of a table beyond the cortex: its storage format and how it is compacted. Owner: example.
-- Shape 1, options of a cortex part: one row at most per cortex row, its id that row's id. A row exists only when an option is written.
CREATE TABLE engine_example.table_options (
  id          TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table
  format      TEXT    CHECK (format IN ('row', 'column')),                                    -- how its rows are stored; NULL when not written
  compaction  TEXT    CHECK (compaction IN ('none', 'size', 'time')),                         -- how its files are compacted; NULL when not written
  frozen      BOOLEAN NOT NULL DEFAULT false                                                  -- true when nothing in it may change (FROZEN)
);

COMMENT ON TABLE engine_example.table_options IS 'what Example says of a table beyond the cortex: its storage format and how it is compacted. Shape 1, options of a cortex part: one row at most per cortex row, its id that row''s id. A row exists only when an option is written.';
COMMENT ON COLUMN engine_example.table_options.id IS 'the table';
COMMENT ON COLUMN engine_example.table_options.format IS 'how its rows are stored; NULL when not written';
COMMENT ON COLUMN engine_example.table_options.compaction IS 'how its files are compacted; NULL when not written';
COMMENT ON COLUMN engine_example.table_options.frozen IS 'true when nothing in it may change (FROZEN)';

-- engine_example.table_properties: a table's free properties (WITH PROPERTIES ('k' = 'v')), each kept as written. Owner: example.
-- Shape 4, open-ended properties: for what the engine lets anyone name; one row per key, the key and the value as written.
-- Use it only when the engine itself has no fixed list: a property the engine names belongs in a typed column of shape 1.
CREATE TABLE engine_example.table_properties (
  id        TEXT    NOT NULL PRIMARY KEY,                                       -- <object>.property<n>, n given once from id_counters and never reused: o_orders.property1
  object    TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the table
  position  NUMERIC NOT NULL CHECK (position > 0),                              -- its place as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  key       TEXT    NOT NULL CHECK (length(key) >= 1),                          -- the property's key, as written
  value     TEXT    NOT NULL,                                                   -- its value, as written
  UNIQUE (object, key),
  UNIQUE (object, position),
  CHECK (substr(id, 1, length(object) + 9) = object || '.property' AND substr(id, length(object) + 10) ~ '^[1-9][0-9]*$')
);

COMMENT ON TABLE engine_example.table_properties IS 'a table''s free properties (WITH PROPERTIES (''k'' = ''v'')), each kept as written. Shape 4, open-ended properties: for what the engine lets anyone name; one row per key, the key and the value as written. Use it only when the engine itself has no fixed list: a property the engine names belongs in a typed column of shape 1.';
COMMENT ON COLUMN engine_example.table_properties.id IS '<object>.property<n>, n given once from id_counters and never reused: o_orders.property1';
COMMENT ON COLUMN engine_example.table_properties.object IS 'the table';
COMMENT ON COLUMN engine_example.table_properties.position IS 'its place as written; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN engine_example.table_properties.key IS 'the property''s key, as written';
COMMENT ON COLUMN engine_example.table_properties.value IS 'its value, as written';

-- ids-within-their-counters: A numbered part's number was given by its counter (the cortex's id_counters), so it is never given again. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_ids_within_their_counters AS
SELECT 'ids-within-their-counters' AS rule, (p.id)::text AS id FROM (
  SELECT id FROM engine_example.column_codecs
  UNION ALL SELECT id FROM engine_example.table_properties
  UNION ALL SELECT id FROM engine_example.nested_fields
) p LEFT JOIN cortex.id_counters c ON c.id = rtrim(p.id, '0123456789')
  WHERE c.id IS NULL OR c.last < CAST(substr(p.id, length(rtrim(p.id, '0123456789')) + 1) AS INTEGER);

COMMENT ON VIEW engine_example.broken_ids_within_their_counters IS 'A numbered part''s number was given by its counter (the cortex''s id_counters), so it is never given again.';

-- nested-fields-in-their-column: A nested field sits in a field of the same column. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_nested_fields_in_their_column AS
SELECT 'nested-fields-in-their-column' AS rule, (f.id)::text AS id FROM engine_example.nested_fields f
  JOIN engine_example.nested_fields p ON p.id = f.parent WHERE p."column" <> f."column";

COMMENT ON VIEW engine_example.broken_nested_fields_in_their_column IS 'A nested field sits in a field of the same column.';

-- pools-of-their-kind: A storage pool is an object of the kind storage_pool. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_pools_of_their_kind AS
SELECT 'pools-of-their-kind' AS rule, (p.id)::text AS id FROM engine_example.storage_pools p JOIN cortex.objects o ON o.id = p.id WHERE o.kind <> 'storage_pool';

COMMENT ON VIEW engine_example.broken_pools_of_their_kind IS 'A storage pool is an object of the kind storage_pool.';

-- table-options-on-tables: Table options belong to an object of the kind table. Owner: engine_example.
-- The rows breaking it. cortex.enforce_rules('engine_example') makes the database refuse any commit while it has one.
CREATE VIEW engine_example.broken_table_options_on_tables AS
SELECT 'table-options-on-tables' AS rule, (t.id)::text AS id FROM engine_example.table_options t JOIN cortex.objects o ON o.id = t.id WHERE o.kind <> 'table';

COMMENT ON VIEW engine_example.broken_table_options_on_tables IS 'Table options belong to an object of the kind table.';

SELECT cortex.enforce_rules('engine_example');
