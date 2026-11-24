-- workspace.connection_tests: each test of a saved connection, and how it went. Owner: workspace.
CREATE TABLE workspace.connection_tests (
  id          UUID        NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),  -- UUIDv7, issued when the test ran
  connection  UUID        NOT NULL REFERENCES workspace.connections (id) ON DELETE CASCADE,  -- the connection tested
  outcome     TEXT        NOT NULL CHECK (outcome IN ('passed', 'warning', 'failed')),       -- passed, passed with a warning, or failed
  tested_at   TIMESTAMPTZ NOT NULL                                                           -- when
);

COMMENT ON TABLE workspace.connection_tests IS 'each test of a saved connection, and how it went.';
COMMENT ON COLUMN workspace.connection_tests.id IS 'UUIDv7, issued when the test ran';
COMMENT ON COLUMN workspace.connection_tests."connection" IS 'the connection tested';
COMMENT ON COLUMN workspace.connection_tests.outcome IS 'passed, passed with a warning, or failed';
COMMENT ON COLUMN workspace.connection_tests.tested_at IS 'when';
