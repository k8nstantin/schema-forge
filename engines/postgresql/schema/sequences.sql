-- engine_postgresql.sequences: what PostgreSQL says of a sequence beyond the cortex. Owner: postgresql.
CREATE TABLE engine_postgresql.sequences (
  id        BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.sequences (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the sequence
  identity  BOOLEAN NOT NULL DEFAULT false                                                                                 -- true when an identity column made it, not CREATE SEQUENCE
);

COMMENT ON TABLE engine_postgresql.sequences IS 'what PostgreSQL says of a sequence beyond the cortex.';
COMMENT ON COLUMN engine_postgresql.sequences.id IS 'the sequence';
COMMENT ON COLUMN engine_postgresql.sequences.identity IS 'true when an identity column made it, not CREATE SEQUENCE';
