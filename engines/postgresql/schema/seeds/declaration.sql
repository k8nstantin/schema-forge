-- declaration: what PostgreSQL is, as data: its versions, its kinds of object, and every option it adds to a part of the model
-- (decision declared-options). The engine's one source: its code is made from these rows. Owner: postgresql.
-- Inserted only where the id is missing: a row the app or a person changed is never overwritten by a later version's seed.

INSERT INTO cortex.engine_versions (id, engine, version, name, position, support_ends) VALUES
  ('postgresql/15', 'postgresql', '15', 'PostgreSQL 15', 1, NULL),
  ('postgresql/16', 'postgresql', '16', 'PostgreSQL 16', 2, NULL),
  ('postgresql/17', 'postgresql', '17', 'PostgreSQL 17', 3, NULL),
  ('postgresql/18', 'postgresql', '18', 'PostgreSQL 18', 4, NULL)
ON CONFLICT (id) DO NOTHING;


-- the managed flavors of the engine (decision schema-per-engine), and what each lacks, each fact with the page it was read on
INSERT INTO cortex.engine_flavors (id, engine, flavor, name, position, about) VALUES
  ('postgresql/rds', 'postgresql', 'rds', 'Amazon RDS for PostgreSQL', 1, 'PostgreSQL run by Amazon RDS: the community server''s versions, without SUPERUSER'),
  ('postgresql/aurora', 'postgresql', 'aurora', 'Amazon Aurora PostgreSQL', 2, 'Amazon''s PostgreSQL-compatible engine on its own storage, following the community''s major versions'),
  ('postgresql/cloudsql', 'postgresql', 'cloudsql', 'Cloud SQL for PostgreSQL', 3, 'PostgreSQL run by Google Cloud SQL: no SUPERUSER, no custom tablespaces, its own list of extensions'),
  ('postgresql/alloydb', 'postgresql', 'alloydb', 'AlloyDB for PostgreSQL', 4, 'Google''s PostgreSQL-compatible engine: PostgreSQL, with a columnar engine and Google''s extensions added'),
  ('postgresql/spanner', 'postgresql', 'spanner', 'Spanner, PostgreSQL interface', 5, 'Google Spanner spoken through a subset of PostgreSQL''s language, with Spanner''s own objects added; not a PostgreSQL server, so no major version of its own')
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.object_kinds (id, engine, kind, name, position, scope, flavor) VALUES
  ('postgresql/table', 'postgresql', 'table', 'Table', 1, 'namespace', NULL),
  ('postgresql/view', 'postgresql', 'view', 'View', 2, 'namespace', NULL),
  ('postgresql/materialized_view', 'postgresql', 'materialized_view', 'Materialized view', 3, 'namespace', NULL),
  ('postgresql/sequence', 'postgresql', 'sequence', 'Sequence', 4, 'namespace', NULL),
  ('postgresql/enum', 'postgresql', 'enum', 'Enum type', 5, 'namespace', NULL),
  ('postgresql/composite', 'postgresql', 'composite', 'Composite type', 6, 'namespace', NULL),
  ('postgresql/domain', 'postgresql', 'domain', 'Domain', 7, 'namespace', NULL),
  ('postgresql/range', 'postgresql', 'range', 'Range type', 8, 'namespace', NULL),
  ('postgresql/function', 'postgresql', 'function', 'Function', 9, 'namespace', NULL),
  ('postgresql/procedure', 'postgresql', 'procedure', 'Procedure', 10, 'namespace', NULL),
  ('postgresql/trigger', 'postgresql', 'trigger', 'Trigger', 11, 'namespace', NULL),
  ('postgresql/change_stream', 'postgresql', 'change_stream', 'Change stream', 12, 'database', 'postgresql/spanner'),
  ('postgresql/locality_group', 'postgresql', 'locality_group', 'Locality group', 13, 'database', 'postgresql/spanner'),
  ('postgresql/placement', 'postgresql', 'placement', 'Placement', 14, 'database', 'postgresql/spanner'),
  ('postgresql/queue', 'postgresql', 'queue', 'Queue', 15, 'namespace', 'postgresql/spanner'),
  ('postgresql/role', 'postgresql', 'role', 'Role', 16, 'server', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, about) VALUES
  ('postgresql/objects/login', 'postgresql', 'objects', 'login', 'boolean', false, NULL, 'a role that may sign in (LOGIN): a user'),
  ('postgresql/objects/superuser', 'postgresql', 'objects', 'superuser', 'boolean', false, NULL, 'a role that passes every check (SUPERUSER)'),
  ('postgresql/objects/createdb', 'postgresql', 'objects', 'createdb', 'boolean', false, NULL, 'a role that may make databases (CREATEDB)'),
  ('postgresql/objects/createrole', 'postgresql', 'objects', 'createrole', 'boolean', false, NULL, 'a role that may make roles (CREATEROLE)'),
  ('postgresql/objects/inherit', 'postgresql', 'objects', 'inherit', 'boolean', false, NULL, 'a role that has the privileges of the roles it is a member of (INHERIT)'),
  ('postgresql/objects/replication', 'postgresql', 'objects', 'replication', 'boolean', false, NULL, 'a role that may stream replication (REPLICATION)'),
  ('postgresql/objects/bypassrls', 'postgresql', 'objects', 'bypassrls', 'boolean', false, NULL, 'a role that row security does not bind (BYPASSRLS)'),
  ('postgresql/objects/connection_limit', 'postgresql', 'objects', 'connection_limit', 'number', false, NULL, 'how many connections a role may hold at once; -1 for no limit'),
  ('postgresql/objects/valid_until', 'postgresql', 'objects', 'valid_until', 'string', true, NULL, 'when a role''s password stops working, as PostgreSQL writes it; NULL for never'),
  ('postgresql/columns/is_local', 'postgresql', 'columns', 'is_local', 'boolean', false, NULL, 'false when it comes from a parent table only'),
  ('postgresql/columns/inherit_count', 'postgresql', 'columns', 'inherit_count', 'number', false, NULL, 'how many parents it comes from'),
  ('postgresql/columns/options', 'postgresql', 'columns', 'options', 'json', true, NULL, 'its options as the server writes them; NULL for none'),
  ('postgresql/columns/acl', 'postgresql', 'columns', 'acl', 'json', true, NULL, 'its column privileges; NULL for none'),
  ('postgresql/constraints/validated', 'postgresql', 'constraints', 'validated', 'boolean', false, NULL, 'false when made NOT VALID: existing rows are not checked'),
  ('postgresql/constraints/no_inherit', 'postgresql', 'constraints', 'no_inherit', 'boolean', false, NULL, 'true when it does not pass to child tables'),
  ('postgresql/constraints/is_local', 'postgresql', 'constraints', 'is_local', 'boolean', false, NULL, 'false when it comes from a parent table only'),
  ('postgresql/constraints/inherit_count', 'postgresql', 'constraints', 'inherit_count', 'number', false, NULL, 'how many parents it comes from'),
  ('postgresql/constraints/operators', 'postgresql', 'constraints', 'operators', 'json', true, NULL, 'an exclusion''s operators, one per part (["=", "&&"]); NULL otherwise'),
  ('postgresql/index_parts/nulls_first', 'postgresql', 'index_parts', 'nulls_first', 'boolean', false, NULL, 'true when nulls sort first'),
  ('postgresql/index_parts/operator_class', 'postgresql', 'index_parts', 'operator_class', 'string', true, NULL, 'its operator class where it is not the default for its type, as the server writes it (gist_trgm_ops); NULL for the default'),
  ('postgresql/index_parts/collation', 'postgresql', 'index_parts', 'collation', 'string', true, NULL, 'its collation where it is not its column''s or expression''s; NULL for that one'),
  ('postgresql/indexes/replica_identity_index', 'postgresql', 'indexes', 'replica_identity_index', 'boolean', false, NULL, 'true for the index that identifies a table''s rows to logical replication (REPLICA IDENTITY USING INDEX)'),
  ('postgresql/indexes/clustered', 'postgresql', 'indexes', 'clustered', 'boolean', false, NULL, 'true for the index the table was last clustered on (CLUSTER ON)'),
  ('postgresql/constraint_columns/set_on_delete', 'postgresql', 'constraint_columns', 'set_on_delete', 'boolean', false, NULL, 'true for a column ON DELETE SET NULL (...) or SET DEFAULT (...) names: the only columns it sets'),
  ('postgresql/indexes/nulls_not_distinct', 'postgresql', 'indexes', 'nulls_not_distinct', 'boolean', false, NULL, 'true when nulls count as equal (15 and later)'),
  ('postgresql/indexes/options', 'postgresql', 'indexes', 'options', 'json', true, NULL, 'its storage options as the server writes them (["pages_per_range=32"]); NULL for none'),
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

INSERT INTO cortex.option_declarations (id, engine, part, name, value_type, nullable, choices, since, about) VALUES
  ('postgresql/memberships/inherit_option', 'postgresql', 'memberships', 'inherit_option', 'boolean', false, NULL, 'postgresql/16', 'true when the member has the role''s privileges without SET ROLE (WITH INHERIT)'),
  ('postgresql/memberships/set_option', 'postgresql', 'memberships', 'set_option', 'boolean', false, NULL, 'postgresql/16', 'true when the member may SET ROLE to it (WITH SET)')
ON CONFLICT (id) DO NOTHING;

-- what each flavor lacks
INSERT INTO cortex.flavor_limits (id, flavor, what, kind, option, value, name, since, "until", severity, about, source) VALUES
  ('postgresql/spanner/kind/trigger', 'postgresql/spanner', 'kind', 'postgresql/trigger', NULL, NULL, NULL, NULL, NULL, 'refused', 'triggers are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/enum', 'postgresql/spanner', 'kind', 'postgresql/enum', NULL, NULL, NULL, NULL, NULL, 'refused', 'user-defined data types are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/composite', 'postgresql/spanner', 'kind', 'postgresql/composite', NULL, NULL, NULL, NULL, NULL, 'refused', 'user-defined data types are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/domain', 'postgresql/spanner', 'kind', 'postgresql/domain', NULL, NULL, NULL, NULL, NULL, 'refused', 'user-defined data types are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/range', 'postgresql/spanner', 'kind', 'postgresql/range', NULL, NULL, NULL, NULL, NULL, 'refused', 'user-defined data types are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/procedure', 'postgresql/spanner', 'kind', 'postgresql/procedure', NULL, NULL, NULL, NULL, NULL, 'refused', 'user-defined stored procedures are not supported', 'https://docs.cloud.google.com/spanner/docs/postgresql-interface'),
  ('postgresql/spanner/kind/function', 'postgresql/spanner', 'kind', 'postgresql/function', NULL, NULL, NULL, NULL, NULL, 'refused', 'its DDL has no CREATE FUNCTION: a function is one Spanner ships', 'https://docs.cloud.google.com/spanner/docs/reference/postgresql/data-definition-language'),
  ('postgresql/spanner/kind/materialized_view', 'postgresql/spanner', 'kind', 'postgresql/materialized_view', NULL, NULL, NULL, NULL, NULL, 'refused', 'its DDL has no CREATE MATERIALIZED VIEW', 'https://docs.cloud.google.com/spanner/docs/reference/postgresql/data-definition-language')
ON CONFLICT (id) DO NOTHING;
