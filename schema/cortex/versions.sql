-- versions: a locked version of the schema: the log up to one operation, its number and its hash. Owner: cortex.
CREATE TABLE versions (
  id            TEXT     NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, issued when it is locked
  number        INTEGER  NOT NULL UNIQUE CHECK (number >= 1),                -- v1, v2, v3: one more than the version before
  at_operation  TEXT     NOT NULL UNIQUE REFERENCES operations (id),         -- the last operation it holds: replaying the log to it gives the version
  hash          TEXT     NOT NULL CHECK (length(hash) = 64),                 -- SHA-256 of the version's model in its canonical file form, hex
  message       TEXT     NOT NULL CHECK (length(message) >= 1),              -- what the version is, in a sentence
  locked_by     TEXT     NOT NULL,                                           -- who locked it
  locked_at     TEXT     NOT NULL,                                           -- when, UTC, RFC 3339
  git_commit    TEXT     CHECK (git_commit IS NULL OR length(git_commit) = 40),  -- the commit its definitions were written in; NULL outside a git repository
  git_tag       TEXT                                                         -- the tag of that commit (schema/shop/v3); NULL outside a git repository
) STRICT;
