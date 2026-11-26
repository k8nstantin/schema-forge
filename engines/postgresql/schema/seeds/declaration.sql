-- declaration: what PostgreSQL is, as data: its versions, its kinds of object, and every option it adds to a part of the model
-- (decision declared-options). The engine's one source: its code is made from these rows. Owner: postgresql.
-- Inserted only where the id is missing: a row the app or a person changed is never overwritten by a later version's seed.

INSERT INTO cortex.engine_versions (id, engine, version, name, position, support_ends) VALUES
  ('postgresql/15', 'postgresql', '15', 'PostgreSQL 15', 1, NULL),
  ('postgresql/16', 'postgresql', '16', 'PostgreSQL 16', 2, NULL),
  ('postgresql/17', 'postgresql', '17', 'PostgreSQL 17', 3, NULL),
  ('postgresql/18', 'postgresql', '18', 'PostgreSQL 18', 4, NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.object_kinds (id, engine, kind, name, position) VALUES
  ('postgresql/table', 'postgresql', 'table', 'Table', 1),
  ('postgresql/view', 'postgresql', 'view', 'View', 2),
  ('postgresql/materialized_view', 'postgresql', 'materialized_view', 'Materialized view', 3),
  ('postgresql/sequence', 'postgresql', 'sequence', 'Sequence', 4),
  ('postgresql/enum', 'postgresql', 'enum', 'Enum type', 5),
  ('postgresql/composite', 'postgresql', 'composite', 'Composite type', 6),
  ('postgresql/domain', 'postgresql', 'domain', 'Domain', 7),
  ('postgresql/range', 'postgresql', 'range', 'Range type', 8),
  ('postgresql/function', 'postgresql', 'function', 'Function', 9),
  ('postgresql/procedure', 'postgresql', 'procedure', 'Procedure', 10),
  ('postgresql/trigger', 'postgresql', 'trigger', 'Trigger', 11)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, about) VALUES
  ('postgresql/columns/is_local', 'postgresql', 'columns', 'is_local', 'boolean', false, NULL, 'false when it comes from a parent table only'),
  ('postgresql/columns/inherit_count', 'postgresql', 'columns', 'inherit_count', 'number', false, NULL, 'how many parents it comes from'),
  ('postgresql/columns/options', 'postgresql', 'columns', 'options', 'json', true, NULL, 'its options as the server writes them; NULL for none'),
  ('postgresql/columns/acl', 'postgresql', 'columns', 'acl', 'json', true, NULL, 'its column privileges; NULL for none'),
  ('postgresql/constraints/validated', 'postgresql', 'constraints', 'validated', 'boolean', false, NULL, 'false when made NOT VALID: existing rows are not checked'),
  ('postgresql/constraints/no_inherit', 'postgresql', 'constraints', 'no_inherit', 'boolean', false, NULL, 'true when it does not pass to child tables'),
  ('postgresql/constraints/is_local', 'postgresql', 'constraints', 'is_local', 'boolean', false, NULL, 'false when it comes from a parent table only'),
  ('postgresql/constraints/inherit_count', 'postgresql', 'constraints', 'inherit_count', 'number', false, NULL, 'how many parents it comes from'),
  ('postgresql/constraints/operators', 'postgresql', 'constraints', 'operators', 'json', true, NULL, 'an exclusion''s operators, one per part (["=", "&&"]); NULL otherwise'),
  ('postgresql/constraints/delete_set_columns', 'postgresql', 'constraints', 'delete_set_columns', 'json', true, NULL, 'ON DELETE SET NULL (...) or SET DEFAULT (...): the ids of the only columns it sets, in order; NULL for all of them'),
  ('postgresql/index_parts/nulls_first', 'postgresql', 'index_parts', 'nulls_first', 'boolean', false, NULL, 'true when nulls sort first'),
  ('postgresql/index_parts/operator_class', 'postgresql', 'index_parts', 'operator_class', 'string', true, NULL, 'its operator class where it is not the default for its type, as the server writes it (gist_trgm_ops); NULL for the default'),
  ('postgresql/index_parts/collation', 'postgresql', 'index_parts', 'collation', 'string', true, NULL, 'its collation where it is not its column''s or expression''s; NULL for that one'),
  ('postgresql/indexes/nulls_not_distinct', 'postgresql', 'indexes', 'nulls_not_distinct', 'boolean', false, NULL, 'true when nulls count as equal (15 and later)'),
  ('postgresql/indexes/options', 'postgresql', 'indexes', 'options', 'json', true, NULL, 'its storage options as the server writes them (["pages_per_range=32"]); NULL for none'),
  ('postgresql/indexes/parent', 'postgresql', 'indexes', 'parent', 'string', true, NULL, 'the partitioned table''s index it is part of; NULL for none'),
  ('postgresql/namespaces/owner', 'postgresql', 'namespaces', 'owner', 'string', true, NULL, 'its owner, by role name; NULL for the one the schema is written as'),
  ('postgresql/namespaces/acl', 'postgresql', 'namespaces', 'acl', 'json', true, NULL, 'its privileges, as the server writes them (["postgres=UC/postgres"]); NULL for the defaults'),
  ('postgresql/objects/persistence', 'postgresql', 'objects', 'persistence', 'string', false, '["permanent", "unlogged"]', 'how it is kept'),
  ('postgresql/objects/options', 'postgresql', 'objects', 'options', 'json', true, NULL, 'its storage options as the server writes them (["fillfactor=70"]); NULL for none'),
  ('postgresql/objects/access_method', 'postgresql', 'objects', 'access_method', 'string', true, NULL, 'its table access method (heap); NULL for the default'),
  ('postgresql/objects/owner', 'postgresql', 'objects', 'owner', 'string', true, NULL, 'its owner, by role name; NULL for the one the schema is written as'),
  ('postgresql/objects/acl', 'postgresql', 'objects', 'acl', 'json', true, NULL, 'its privileges, as the server writes them; NULL for the defaults'),
  ('postgresql/objects/row_security', 'postgresql', 'objects', 'row_security', 'boolean', false, NULL, 'true when its policies apply (ENABLE ROW LEVEL SECURITY)'),
  ('postgresql/objects/force_row_security', 'postgresql', 'objects', 'force_row_security', 'boolean', false, NULL, 'true when they apply to its owner too'),
  ('postgresql/objects/replica_identity', 'postgresql', 'objects', 'replica_identity', 'string', false, '["default", "nothing", "full", "index"]', 'what identifies a row to logical replication'),
  ('postgresql/objects/populated', 'postgresql', 'objects', 'populated', 'boolean', false, NULL, 'for a materialized view, false when made WITH NO DATA'),
  ('postgresql/routines/volatility', 'postgresql', 'routines', 'volatility', 'string', false, '["immutable", "stable", "volatile"]', 'what it promises about its results'),
  ('postgresql/routines/parallel', 'postgresql', 'routines', 'parallel', 'string', false, '["safe", "restricted", "unsafe"]', 'whether it may run in a parallel query'),
  ('postgresql/routines/strict', 'postgresql', 'routines', 'strict', 'boolean', false, NULL, 'true when it returns null on any null argument'),
  ('postgresql/routines/leakproof', 'postgresql', 'routines', 'leakproof', 'boolean', false, NULL, 'true when it reveals nothing of its arguments'),
  ('postgresql/routines/returns_set', 'postgresql', 'routines', 'returns_set', 'boolean', false, NULL, 'true when it returns rows'),
  ('postgresql/routines/cost', 'postgresql', 'routines', 'cost', 'number', true, NULL, 'its estimated cost; NULL for the default'),
  ('postgresql/routines/result_rows', 'postgresql', 'routines', 'result_rows', 'number', true, NULL, 'its estimated rows; NULL for the default'),
  ('postgresql/routines/config', 'postgresql', 'routines', 'config', 'json', true, NULL, 'settings it runs with (["search_path=features"]); NULL for none'),
  ('postgresql/routines/owner', 'postgresql', 'routines', 'owner', 'string', true, NULL, 'its owner, by role name; NULL for the one the schema is written as'),
  ('postgresql/routines/acl', 'postgresql', 'routines', 'acl', 'json', true, NULL, 'its privileges; NULL for the defaults'),
  ('postgresql/sequences/identity', 'postgresql', 'sequences', 'identity', 'boolean', false, NULL, 'true when an identity column made it, not CREATE SEQUENCE'),
  ('postgresql/triggers/function_name', 'postgresql', 'triggers', 'function_name', 'string', false, NULL, 'the trigger function, as the server names it (audit.log_change)'),
  ('postgresql/triggers/arguments', 'postgresql', 'triggers', 'arguments', 'json', true, NULL, 'the arguments passed to it; NULL for none'),
  ('postgresql/triggers/update_columns', 'postgresql', 'triggers', 'update_columns', 'json', true, NULL, 'UPDATE OF: the ids of the columns it fires on; NULL for any'),
  ('postgresql/triggers/old_table', 'postgresql', 'triggers', 'old_table', 'string', true, NULL, 'the transition table of old rows (REFERENCING OLD TABLE AS); NULL for none'),
  ('postgresql/triggers/new_table', 'postgresql', 'triggers', 'new_table', 'string', true, NULL, 'the transition table of new rows; NULL for none'),
  ('postgresql/triggers/enabled', 'postgresql', 'triggers', 'enabled', 'string', false, '["origin", "disabled", "replica", "always"]', 'when it fires'),
  ('postgresql/triggers/constraint_trigger', 'postgresql', 'triggers', 'constraint_trigger', 'boolean', false, NULL, 'made by CREATE CONSTRAINT TRIGGER: it fires after the change, and may wait for the commit'),
  ('postgresql/triggers/from_table', 'postgresql', 'triggers', 'from_table', 'string', true, NULL, 'the table a constraint trigger names in FROM, as the server writes it; NULL for none'),
  ('postgresql/triggers/deferrable', 'postgresql', 'triggers', 'deferrable', 'boolean', false, NULL, 'a constraint trigger that may wait for the commit (DEFERRABLE)'),
  ('postgresql/triggers/initially_deferred', 'postgresql', 'triggers', 'initially_deferred', 'boolean', false, NULL, 'a deferrable one that waits for the commit unless told otherwise (INITIALLY DEFERRED)'),
  ('postgresql/objects/range_subtype', 'postgresql', 'objects', 'range_subtype', 'string', true, NULL, 'a range type''s element type; NULL otherwise'),
  ('postgresql/objects/multirange', 'postgresql', 'objects', 'multirange', 'string', true, NULL, 'a range type''s multirange type name; NULL otherwise')
ON CONFLICT (id) DO NOTHING;
