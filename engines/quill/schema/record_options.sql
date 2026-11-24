-- engine_quill.record_options: what Quill says of a record beyond the cortex: whether it is kept in memory.
-- Owner: quill. Shipped in the Quill plugin (engines/quill); created in a schema database whose engine is quill, and in no other.
CREATE TABLE engine_quill.record_options (
  id    TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the record
  fast  BOOLEAN NOT NULL CHECK (fast)                                                   -- present only for a record written fast (kept in memory), from Quill version 2
);

COMMENT ON TABLE engine_quill.record_options IS 'what Quill says of a record beyond the cortex: whether it is kept in memory. Shipped in the Quill plugin (engines/quill); created in a schema database whose engine is quill, and in no other.';
COMMENT ON COLUMN engine_quill.record_options.id IS 'the record';
COMMENT ON COLUMN engine_quill.record_options.fast IS 'present only for a record written fast (kept in memory), from Quill version 2';
