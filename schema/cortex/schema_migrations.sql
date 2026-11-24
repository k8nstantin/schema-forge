-- cortex.schema_migrations: every migration applied to this schema's database, by its owner. Owner: cortex.
-- The owner is cortex or an engine's id; each counts its own versions from 1 (decision 13). Opening the database applies,
-- in order and in one transaction, every version its owners ship that is not here; a checksum that differs from the
-- shipped file refuses the database.
CREATE TABLE cortex.schema_migrations (
  id          TEXT        NOT NULL PRIMARY KEY,                                         -- <owner>/<version>: cortex/1, mysql/3
  owner       TEXT        NOT NULL CHECK (owner = 'cortex' OR owner ~ '^[a-z0-9_]+$'),  -- cortex, or the id of the engine whose tables it creates
  version     INTEGER     NOT NULL CHECK (version >= 1),                                -- the owner's version; 1 creates its tables from its schema folder
  checksum    TEXT        NOT NULL CHECK (length(checksum) = 64),                       -- SHA-256 of what was applied, hex: a shipped migration whose text changed is refused
  applied_at  TIMESTAMPTZ NOT NULL,                                                     -- when it was applied
  UNIQUE (owner, version),
  CHECK (id = owner || '/' || version)
);

COMMENT ON TABLE cortex.schema_migrations IS 'every migration applied to this schema''s database, by its owner. The owner is cortex or an engine''s id; each counts its own versions from 1 (decision 13). Opening the database applies, in order and in one transaction, every version its owners ship that is not here; a checksum that differs from the shipped file refuses the database.';
COMMENT ON COLUMN cortex.schema_migrations.id IS '<owner>/<version>: cortex/1, mysql/3';
COMMENT ON COLUMN cortex.schema_migrations.owner IS 'cortex, or the id of the engine whose tables it creates';
COMMENT ON COLUMN cortex.schema_migrations.version IS 'the owner''s version; 1 creates its tables from its schema folder';
COMMENT ON COLUMN cortex.schema_migrations.checksum IS 'SHA-256 of what was applied, hex: a shipped migration whose text changed is refused';
COMMENT ON COLUMN cortex.schema_migrations.applied_at IS 'when it was applied';
