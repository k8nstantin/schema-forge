-- engine_postgresql.sequences: what PostgreSQL says of a sequence beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.sequences (
  id        UUID NOT NULL PRIMARY KEY,                                                                     -- the sequence
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  identity  BOOLEAN NOT NULL DEFAULT false,                                                                -- true when an identity column made it, not CREATE SEQUENCE
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.sequences (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_postgresql.sequences IS 'what PostgreSQL says of a sequence beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.sequences.id IS 'the sequence';
COMMENT ON COLUMN engine_postgresql.sequences.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.sequences.identity IS 'true when an identity column made it, not CREATE SEQUENCE';
