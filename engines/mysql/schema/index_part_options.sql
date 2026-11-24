-- engine_mysql.index_part_options: how much of a column one part of an index holds.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.index_part_options (
  id      TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.index_parts (id) ON DELETE CASCADE,  -- the index part
  length  INTEGER NOT NULL CHECK (length >= 1)                                                -- how many characters or bytes of the column it indexes
);

COMMENT ON TABLE engine_mysql.index_part_options IS 'how much of a column one part of an index holds. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.index_part_options.id IS 'the index part';
COMMENT ON COLUMN engine_mysql.index_part_options.length IS 'how many characters or bytes of the column it indexes';
