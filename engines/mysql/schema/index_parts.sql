-- engine_mysql.index_parts: how much of a column one part of an index holds. Owner: mysql.
CREATE TABLE engine_mysql.index_parts (
  id      BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.index_parts (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the index part
  length  INTEGER NOT NULL CHECK (length >= 1)                                                                             -- how many characters or bytes of the column it indexes
);

COMMENT ON TABLE engine_mysql.index_parts IS 'how much of a column one part of an index holds.';
COMMENT ON COLUMN engine_mysql.index_parts.id IS 'the index part';
COMMENT ON COLUMN engine_mysql.index_parts.length IS 'how many characters or bytes of the column it indexes';
