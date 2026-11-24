-- requirements: what the database must have installed for this schema (an extension, a plugin), by name. Owner: cortex.
CREATE TABLE requirements (
  id    TEXT  NOT NULL PRIMARY KEY CHECK (length(id) >= 1)                     -- its name, in the engine's words (postgis)
) STRICT;
