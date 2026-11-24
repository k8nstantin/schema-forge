-- mysql__index_part_options: how much of a column one part of an index holds.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__index_part_options (
  id      TEXT     NOT NULL PRIMARY KEY REFERENCES index_parts (id) ON DELETE CASCADE,  -- the index part
  length  INTEGER  NOT NULL CHECK (length >= 1)                            -- how many characters or bytes of the column it indexes
) STRICT;
