-- cortex.column_identities: a column the database numbers itself, and how. Owner: cortex.
CREATE TABLE cortex.column_identities (
  id        BIGINT NOT NULL PRIMARY KEY,                                                                   -- the column numbered
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  always    BOOLEAN NOT NULL DEFAULT false,                                                                -- true when a value can never be given (ALWAYS); false for BY DEFAULT and for MySQL's AUTO_INCREMENT
  sequence  BIGINT,                                                                                        -- the sequence that numbers it, where the engine makes one; NULL for none
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, sequence) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX column_identities_sequence ON cortex.column_identities (design, sequence);

COMMENT ON TABLE cortex.column_identities IS 'a column the database numbers itself, and how.';
COMMENT ON COLUMN cortex.column_identities.id IS 'the column numbered';
COMMENT ON COLUMN cortex.column_identities.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.column_identities.always IS 'true when a value can never be given (ALWAYS); false for BY DEFAULT and for MySQL''s AUTO_INCREMENT';
COMMENT ON COLUMN cortex.column_identities.sequence IS 'the sequence that numbers it, where the engine makes one; NULL for none';
