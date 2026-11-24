-- mysql__database_options: what MySQL says of a database (a namespace) beyond the cortex.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__database_options (
  id         TEXT    NOT NULL PRIMARY KEY REFERENCES namespaces (id) ON DELETE CASCADE,  -- the database
  charset    TEXT,                                                    -- its default character set (DEFAULT CHARACTER SET); NULL when not written
  collation  TEXT,                                                    -- its default collation (DEFAULT COLLATE); NULL when not written
  encryption INTEGER CHECK (encryption IN (0, 1)),                    -- 1 when its tables are encrypted by default (DEFAULT ENCRYPTION 'Y'); NULL when not written
  read_only  INTEGER CHECK (read_only IN (0, 1))                      -- 1 when nothing in it may change (READ ONLY = 1); NULL when not written
) STRICT;
