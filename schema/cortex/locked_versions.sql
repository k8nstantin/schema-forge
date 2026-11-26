-- cortex.locked_versions: a locked version of the schema: the log up to one turn, its number and its hash. Owner: cortex.
CREATE TABLE cortex.locked_versions (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, issued when it is locked
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it is a version of
  number      INTEGER NOT NULL CHECK (number >= 1),                                                          -- v1, v2, v3: one more than its design's version before
  turn        UUID NOT NULL UNIQUE REFERENCES cortex.turns (id),                                             -- the last turn it holds: moving the design to it gives the version
  hash        TEXT NOT NULL CHECK (length(hash) = 64),                                                       -- SHA-256 of the version's design, hex: the design at that turn always hashes to it
  message     TEXT NOT NULL CHECK (length(message) >= 1),                                                    -- what the version is, in a sentence
  locked_by   TEXT NOT NULL,                                                                                 -- who locked it
  locked_at   TIMESTAMPTZ NOT NULL,                                                                          -- when
  git_commit  TEXT CHECK (git_commit IS NULL OR length(git_commit) IN (40, 64)),                             -- the commit its definitions were written in; NULL outside a git repository
  git_tag     TEXT,                                                                                          -- the tag of that commit; NULL outside a git repository
  UNIQUE (design, number) DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.locked_versions IS 'a locked version of the schema: the log up to one turn, its number and its hash.';
COMMENT ON COLUMN cortex.locked_versions.id IS 'UUIDv7, issued when it is locked';
COMMENT ON COLUMN cortex.locked_versions.design IS 'the design it is a version of';
COMMENT ON COLUMN cortex.locked_versions.number IS 'v1, v2, v3: one more than its design''s version before';
COMMENT ON COLUMN cortex.locked_versions.turn IS 'the last turn it holds: moving the design to it gives the version';
COMMENT ON COLUMN cortex.locked_versions.hash IS 'SHA-256 of the version''s design, hex: the design at that turn always hashes to it';
COMMENT ON COLUMN cortex.locked_versions.message IS 'what the version is, in a sentence';
COMMENT ON COLUMN cortex.locked_versions.locked_by IS 'who locked it';
COMMENT ON COLUMN cortex.locked_versions.locked_at IS 'when';
COMMENT ON COLUMN cortex.locked_versions.git_commit IS 'the commit its definitions were written in; NULL outside a git repository';
COMMENT ON COLUMN cortex.locked_versions.git_tag IS 'the tag of that commit; NULL outside a git repository';
