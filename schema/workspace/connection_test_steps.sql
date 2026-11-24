-- workspace.connection_test_steps: each step of a connection test, in order, and what it said (docs/connections.md). Owner: workspace.
CREATE TABLE workspace.connection_test_steps (
  id       TEXT NOT NULL PRIMARY KEY,                                                          -- <test>.<step>
  test     UUID NOT NULL REFERENCES workspace.connection_tests (id) ON DELETE CASCADE,         -- the test
  step     TEXT NOT NULL CHECK (step IN ('reach', 'secure', 'sign_in', 'version', 'rights')),  -- the step
  outcome  TEXT NOT NULL CHECK (outcome IN ('passed', 'warning', 'failed', 'skipped')),        -- how it went
  said     TEXT NOT NULL,                                                                      -- what happened, in the engine's sentence; never a secret
  UNIQUE (test, step),
  CHECK (id = test || '.' || step)
);

COMMENT ON TABLE workspace.connection_test_steps IS 'each step of a connection test, in order, and what it said (docs/connections.md).';
COMMENT ON COLUMN workspace.connection_test_steps.id IS '<test>.<step>';
COMMENT ON COLUMN workspace.connection_test_steps.test IS 'the test';
COMMENT ON COLUMN workspace.connection_test_steps.step IS 'the step';
COMMENT ON COLUMN workspace.connection_test_steps.outcome IS 'how it went';
COMMENT ON COLUMN workspace.connection_test_steps.said IS 'what happened, in the engine''s sentence; never a secret';
