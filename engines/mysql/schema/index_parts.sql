-- engine_mysql.index_parts: how much of a column one part of an index holds. Owner: mysql.
CREATE TABLE engine_mysql.index_parts (
  id      BIGINT NOT NULL PRIMARY KEY,                                                                   -- the index part
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  length  INTEGER NOT NULL CHECK (length >= 1),                                                          -- how many characters or bytes of the column it indexes
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.index_parts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.index_parts IS 'how much of a column one part of an index holds.';
COMMENT ON COLUMN engine_mysql.index_parts.id IS 'the index part';
COMMENT ON COLUMN engine_mysql.index_parts.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.index_parts.length IS 'how many characters or bytes of the column it indexes';
