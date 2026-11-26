-- cortex.workspace_connection_tests: each test of a saved connection, and how it went. Owner: cortex.
CREATE TABLE cortex.workspace_connection_tests (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                             -- UUIDv7, issued when the test ran
  connection  UUID NOT NULL REFERENCES cortex.workspace_connections (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the connection tested
  outcome     TEXT NOT NULL CHECK (outcome IN ('passed', 'warning', 'failed')),                                            -- passed, passed with a warning, or failed
  tested_at   TIMESTAMPTZ NOT NULL DEFAULT now()                                                                           -- when
);

COMMENT ON TABLE cortex.workspace_connection_tests IS 'each test of a saved connection, and how it went.';
COMMENT ON COLUMN cortex.workspace_connection_tests.id IS 'UUIDv7, issued when the test ran';
COMMENT ON COLUMN cortex.workspace_connection_tests.connection IS 'the connection tested';
COMMENT ON COLUMN cortex.workspace_connection_tests.outcome IS 'passed, passed with a warning, or failed';
COMMENT ON COLUMN cortex.workspace_connection_tests.tested_at IS 'when';
