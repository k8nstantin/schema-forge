-- schema_migrations: every migration applied to this file, by its owner. Owner: cortex.
-- The owner is cortex or an engine's id; each counts its own versions from 1 (decision 13). Opening a file applies,
-- in order and in one transaction, every version its owners ship that is not here; a checksum that differs from the
-- shipped file refuses the file.
CREATE TABLE schema_migrations (
  id          TEXT    NOT NULL PRIMARY KEY,                                  -- <owner>/<version>: cortex/1, mysql/3
  owner       TEXT    NOT NULL CHECK (owner = 'cortex' OR owner NOT GLOB '*[^a-z0-9_]*'),  -- cortex, or the id of the engine whose tables it creates
  version     INTEGER NOT NULL CHECK (version >= 1),                       -- the owner's version; 1 creates its tables from its schema folder
  checksum    TEXT    NOT NULL CHECK (length(checksum) = 64),             -- SHA-256 of what was applied, hex: a shipped migration whose text changed is refused
  applied_at  TEXT    NOT NULL,                                            -- when it was applied, UTC, RFC 3339
  UNIQUE (owner, version),
  CHECK (id = owner || '/' || version)
) STRICT;
