-- engine_postgresql.collations: a collation the schema defines. Owner: postgresql.
CREATE TABLE engine_postgresql.collations (
  id             UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  namespace      UUID NOT NULL,                                                                                 -- the schema it is in
  name           TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- its name
  provider       TEXT NOT NULL CHECK (provider IN ('icu', 'libc', 'builtin')),                                  -- where its rules come from
  locale         TEXT,                                                                                          -- its locale (und-u-ks-level2); NULL for libc, which names lc_collate and lc_ctype
  lc_collate     TEXT,                                                                                          -- libc's collate locale; NULL otherwise
  lc_ctype       TEXT,                                                                                          -- libc's character-class locale; NULL otherwise
  deterministic  BOOLEAN NOT NULL DEFAULT true,                                                                 -- false when strings unequal byte for byte may compare equal
  comment        TEXT,                                                                                          -- what it is for; NULL for none
  UNIQUE (namespace, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX collations_namespace ON engine_postgresql.collations (design, namespace);

COMMENT ON TABLE engine_postgresql.collations IS 'a collation the schema defines.';
COMMENT ON COLUMN engine_postgresql.collations.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.collations.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.collations.namespace IS 'the schema it is in';
COMMENT ON COLUMN engine_postgresql.collations.name IS 'its name';
COMMENT ON COLUMN engine_postgresql.collations.provider IS 'where its rules come from';
COMMENT ON COLUMN engine_postgresql.collations.locale IS 'its locale (und-u-ks-level2); NULL for libc, which names lc_collate and lc_ctype';
COMMENT ON COLUMN engine_postgresql.collations.lc_collate IS 'libc''s collate locale; NULL otherwise';
COMMENT ON COLUMN engine_postgresql.collations.lc_ctype IS 'libc''s character-class locale; NULL otherwise';
COMMENT ON COLUMN engine_postgresql.collations.deterministic IS 'false when strings unequal byte for byte may compare equal';
COMMENT ON COLUMN engine_postgresql.collations.comment IS 'what it is for; NULL for none';
