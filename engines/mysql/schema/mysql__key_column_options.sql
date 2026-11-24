-- mysql__key_column_options: how one column of a key is indexed where it is not the whole column ascending.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__key_column_options (
  id      TEXT     NOT NULL PRIMARY KEY REFERENCES key_columns (id) ON DELETE CASCADE,  -- the key's column
  length  INTEGER  CHECK (length >= 1),                                    -- how many characters or bytes of it the key holds (b(10)); NULL for the whole column
  "desc"  INTEGER  NOT NULL DEFAULT 0 CHECK ("desc" IN (0, 1)),            -- 1 when it is held descending (DESC)
  CHECK (length IS NOT NULL OR "desc" = 1)
) STRICT;
