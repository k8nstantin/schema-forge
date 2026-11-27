-- cortex.constraint_columns: the columns of a key, in order; for a foreign key, each with the column of the other table it refers to.
CREATE TABLE cortex.constraint_columns (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  "constraint"  UUID NOT NULL,                                                                                   -- the key
  position      INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place in the key: 1 first
  "column"      UUID NOT NULL,                                                                                   -- a column of the key's table
  to_column     UUID,                                                                                            -- for a foreign key, the column it refers to; NULL otherwise
  UNIQUE (design, id),
  UNIQUE ("constraint", position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "constraint") REFERENCES cortex.constraints (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, to_column) REFERENCES cortex.columns (design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX constraint_columns_constraint ON cortex.constraint_columns (design, "constraint");
CREATE INDEX constraint_columns_column ON cortex.constraint_columns (design, "column");
CREATE INDEX constraint_columns_to_column ON cortex.constraint_columns (design, to_column);
