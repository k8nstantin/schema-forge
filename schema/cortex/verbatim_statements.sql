-- cortex.verbatim_statements: what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place. Owner: cortex.
CREATE TABLE cortex.verbatim_statements (
  id               TEXT    NOT NULL PRIMARY KEY,                                  -- statement<n>, n given once from id_counters and never reused: statement1
  position         NUMERIC NOT NULL UNIQUE CHECK (position > 0),                  -- its place in the order it was read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  kind             TEXT    NOT NULL CHECK (length(kind) >= 1),                    -- what it is, in the engine's words (account, grant, other)
  text             TEXT    NOT NULL,                                              -- the statement, exactly as written
  after_namespace  TEXT    REFERENCES cortex.namespaces (id) ON DELETE SET NULL,  -- the namespace it is written after (a statement kept after a switch of namespace); NULL when it follows an object or the start
  after_object     TEXT    REFERENCES cortex.objects (id) ON DELETE SET NULL,     -- the object it is written after; NULL when it follows a namespace or the start
  CHECK (after_namespace IS NULL OR after_object IS NULL),
  CHECK (id ~ '^statement[1-9][0-9]*$')
);

COMMENT ON TABLE cortex.verbatim_statements IS 'what the schema holds that the model does not describe (an account, a grant, a statement not understood), kept exactly as written and written back in its place.';
COMMENT ON COLUMN cortex.verbatim_statements.id IS 'statement<n>, n given once from id_counters and never reused: statement1';
COMMENT ON COLUMN cortex.verbatim_statements.position IS 'its place in the order it was read; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.verbatim_statements.kind IS 'what it is, in the engine''s words (account, grant, other)';
COMMENT ON COLUMN cortex.verbatim_statements.text IS 'the statement, exactly as written';
COMMENT ON COLUMN cortex.verbatim_statements.after_namespace IS 'the namespace it is written after (a statement kept after a switch of namespace); NULL when it follows an object or the start';
COMMENT ON COLUMN cortex.verbatim_statements.after_object IS 'the object it is written after; NULL when it follows a namespace or the start';
