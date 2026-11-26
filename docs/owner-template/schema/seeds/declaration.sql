-- declaration: what Example is, as data: its kinds of object and every option it adds to a part of the model (decision
-- declared-options). The engine's one source: its code is made from these rows. Owner: example.
-- Inserted only where the id is missing: a row the app or a person changed is never overwritten by a later version's seed.

INSERT INTO cortex.object_kinds (id, engine, kind, name, position) VALUES
  ('example/table', 'example', 'table', 'Table', 1),
  ('example/storage_pool', 'example', 'storage_pool', 'Storage pool', 2)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, about) VALUES
  ('example/objects/format', 'example', 'objects', 'format', 'string', true, '["row", "column"]', 'how a table''s rows are stored; NULL when not written'),
  ('example/objects/frozen', 'example', 'objects', 'frozen', 'boolean', false, NULL, 'true when nothing in a table may change (FROZEN)'),
  ('example/objects/properties', 'example', 'objects', 'properties', 'json', true, NULL, 'the properties a table''s users name themselves (WITH PROPERTIES (''k'' = ''v'')), as an object'),
  ('example/objects/compaction_policy', 'example', 'objects', 'compaction_policy', 'string', true, '["none", "size", "time"]', 'how a table''s files are compacted; NULL when not written'),
  ('example/objects/location', 'example', 'objects', 'location', 'string', false, NULL, 'where a storage pool''s files are, as written'),
  ('example/objects/quota_gb', 'example', 'objects', 'quota_gb', 'number', true, NULL, 'how much a storage pool may hold, in GB; NULL for no limit')
ON CONFLICT (id) DO NOTHING;
