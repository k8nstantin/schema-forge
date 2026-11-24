-- domains: a type narrowed by a default, a not null and checks (its checks are in checks). Owner: cortex.
CREATE TABLE domains (
  id             TEXT    NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the domain
  base           TEXT    NOT NULL CHECK (length(base) >= 1),                   -- the type it narrows, as the engine writes it
  default_value  TEXT,                                                         -- its default, in the engine's SQL; NULL for none
  nullable       INTEGER NOT NULL DEFAULT 1 CHECK (nullable IN (0, 1))         -- 1 when it may hold null
) STRICT;
