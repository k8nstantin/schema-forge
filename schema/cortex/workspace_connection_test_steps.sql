-- cortex.workspace_connection_test_steps: each step of a connection test, in order, and what it said (docs/connections.xml). Owner: cortex.
CREATE TABLE cortex.workspace_connection_test_steps (
  id       UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                                  -- UUIDv7, made with the row
  test     UUID NOT NULL REFERENCES cortex.workspace_connection_tests (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the test
  step     TEXT NOT NULL CHECK (step IN ('reach', 'secure', 'sign_in', 'version', 'rights')),                                -- the step
  outcome  TEXT NOT NULL CHECK (outcome IN ('passed', 'warning', 'failed', 'skipped')),                                      -- how it went
  said     TEXT NOT NULL,                                                                                                    -- what happened, in the engine's sentence; never a secret
  UNIQUE (test, step) DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.workspace_connection_test_steps IS 'each step of a connection test, in order, and what it said (docs/connections.xml).';
COMMENT ON COLUMN cortex.workspace_connection_test_steps.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.workspace_connection_test_steps.test IS 'the test';
COMMENT ON COLUMN cortex.workspace_connection_test_steps.step IS 'the step';
COMMENT ON COLUMN cortex.workspace_connection_test_steps.outcome IS 'how it went';
COMMENT ON COLUMN cortex.workspace_connection_test_steps.said IS 'what happened, in the engine''s sentence; never a secret';
