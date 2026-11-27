-- engine_mysql.index_parts: what MySQL says of an index part beyond the cortex: the length of a prefix.
CREATE TABLE engine_mysql.index_parts (
  id             UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex index part
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  prefix_length  INTEGER NOT NULL CHECK (prefix_length >= 1),                                                     -- the length of the column's prefix indexed (name(20)), in characters or bytes as MySQL counts it
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.index_parts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
