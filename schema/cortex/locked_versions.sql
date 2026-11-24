-- cortex.locked_versions: a locked version of the schema: the log up to one operation, its number and its hash. Owner: cortex.
CREATE TABLE cortex.locked_versions (
  id            UUID        NOT NULL PRIMARY KEY CHECK (uuid_extract_version(id) = 7),     -- UUIDv7, issued when it is locked
  number        INTEGER     NOT NULL UNIQUE CHECK (number >= 1),                           -- v1, v2, v3: one more than the version before
  at_operation  UUID        NOT NULL UNIQUE REFERENCES cortex.operations (id),             -- the last operation it holds: replaying the log to it gives the version
  hash          TEXT        NOT NULL CHECK (length(hash) = 64),                            -- SHA-256 of the version's model in its canonical file form, hex
  message       TEXT        NOT NULL CHECK (length(message) >= 1),                         -- what the version is, in a sentence
  locked_by     TEXT        NOT NULL,                                                      -- who locked it
  locked_at     TIMESTAMPTZ NOT NULL,                                                      -- when
  git_commit    TEXT        CHECK (git_commit IS NULL OR length(git_commit) IN (40, 64)),  -- the commit its definitions were written in (SHA-1 or SHA-256); NULL outside a git repository
  git_tag       TEXT                                                                       -- the tag of that commit (schema/shop/v3); NULL outside a git repository
);

COMMENT ON TABLE cortex.locked_versions IS 'a locked version of the schema: the log up to one operation, its number and its hash.';
COMMENT ON COLUMN cortex.locked_versions.id IS 'UUIDv7, issued when it is locked';
COMMENT ON COLUMN cortex.locked_versions.number IS 'v1, v2, v3: one more than the version before';
COMMENT ON COLUMN cortex.locked_versions.at_operation IS 'the last operation it holds: replaying the log to it gives the version';
COMMENT ON COLUMN cortex.locked_versions.hash IS 'SHA-256 of the version''s model in its canonical file form, hex';
COMMENT ON COLUMN cortex.locked_versions.message IS 'what the version is, in a sentence';
COMMENT ON COLUMN cortex.locked_versions.locked_by IS 'who locked it';
COMMENT ON COLUMN cortex.locked_versions.locked_at IS 'when';
COMMENT ON COLUMN cortex.locked_versions.git_commit IS 'the commit its definitions were written in (SHA-1 or SHA-256); NULL outside a git repository';
COMMENT ON COLUMN cortex.locked_versions.git_tag IS 'the tag of that commit (schema/shop/v3); NULL outside a git repository';
