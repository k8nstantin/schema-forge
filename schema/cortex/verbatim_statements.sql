-- cortex.verbatim_statements: what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place. Owner: cortex.
CREATE TABLE cortex.verbatim_statements (
  id               UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it was read with
  position         NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place in the order it was read; an order key
  kind             TEXT NOT NULL CHECK (length(kind) >= 1),                                                       -- what it is, in the engine's words (account, grant, other)
  text             TEXT NOT NULL,                                                                                 -- the statement, exactly as written
  after_namespace  UUID,                                                                                          -- the namespace it is written after; NULL when it follows an object or the start
  after_object     UUID,                                                                                          -- the object it is written after; NULL when it follows a namespace or the start
  CHECK (after_namespace IS NULL OR after_object IS NULL),
  UNIQUE (design, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, after_namespace) REFERENCES cortex.namespaces (design, id) ON DELETE SET NULL (after_namespace) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, after_object) REFERENCES cortex.objects (design, id) ON DELETE SET NULL (after_object) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX verbatim_statements_after_namespace ON cortex.verbatim_statements (design, after_namespace);
CREATE INDEX verbatim_statements_after_object ON cortex.verbatim_statements (design, after_object);

COMMENT ON TABLE cortex.verbatim_statements IS 'what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place.';
COMMENT ON COLUMN cortex.verbatim_statements.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.verbatim_statements.design IS 'the design it was read with';
COMMENT ON COLUMN cortex.verbatim_statements.position IS 'its place in the order it was read; an order key';
COMMENT ON COLUMN cortex.verbatim_statements.kind IS 'what it is, in the engine''s words (account, grant, other)';
COMMENT ON COLUMN cortex.verbatim_statements.text IS 'the statement, exactly as written';
COMMENT ON COLUMN cortex.verbatim_statements.after_namespace IS 'the namespace it is written after; NULL when it follows an object or the start';
COMMENT ON COLUMN cortex.verbatim_statements.after_object IS 'the object it is written after; NULL when it follows a namespace or the start';
