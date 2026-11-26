-- cortex.engine_versions: the versions of their databases the engines support, in order, as each engine declares them. Owner: cortex.
CREATE TABLE cortex.engine_versions (
  id            TEXT NOT NULL PRIMARY KEY,                               -- <engine>/<version>: mysql/8.4
  engine        TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),           -- the engine, as the registry knows it (mysql)
  version       TEXT NOT NULL CHECK (length(version) BETWEEN 1 AND 40),  -- as the engine names the version (5.7, 8.4)
  name          TEXT NOT NULL CHECK (length(name) >= 1),                 -- as people say it (MySQL 8.4)
  position      NUMERIC NOT NULL CHECK (position > 0),                   -- its place among its engine's versions, oldest first: a version's features compare by it
  support_ends  TIMESTAMPTZ,                                             -- when its maker stops supporting it; NULL when not announced
  UNIQUE (engine, version),
  UNIQUE (engine, position),
  CHECK (id = engine || '/' || version)
);

COMMENT ON TABLE cortex.engine_versions IS 'the versions of their databases the engines support, in order, as each engine declares them.';
COMMENT ON COLUMN cortex.engine_versions.id IS '<engine>/<version>: mysql/8.4';
COMMENT ON COLUMN cortex.engine_versions.engine IS 'the engine, as the registry knows it (mysql)';
COMMENT ON COLUMN cortex.engine_versions.version IS 'as the engine names the version (5.7, 8.4)';
COMMENT ON COLUMN cortex.engine_versions.name IS 'as people say it (MySQL 8.4)';
COMMENT ON COLUMN cortex.engine_versions.position IS 'its place among its engine''s versions, oldest first: a version''s features compare by it';
COMMENT ON COLUMN cortex.engine_versions.support_ends IS 'when its maker stops supporting it; NULL when not announced';
