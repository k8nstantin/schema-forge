-- cortex.column_identities: a column the database numbers itself, and how. Owner: cortex.
CREATE TABLE cortex.column_identities (
  id        BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.columns (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the column numbered
  always    BOOLEAN NOT NULL DEFAULT false,                                                                              -- true when a value can never be given (ALWAYS); false for BY DEFAULT and for MySQL's AUTO_INCREMENT
  sequence  BIGINT REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED                        -- the sequence that numbers it, where the engine makes one; NULL for none
);

COMMENT ON TABLE cortex.column_identities IS 'a column the database numbers itself, and how.';
COMMENT ON COLUMN cortex.column_identities.id IS 'the column numbered';
COMMENT ON COLUMN cortex.column_identities.always IS 'true when a value can never be given (ALWAYS); false for BY DEFAULT and for MySQL''s AUTO_INCREMENT';
COMMENT ON COLUMN cortex.column_identities.sequence IS 'the sequence that numbers it, where the engine makes one; NULL for none';
