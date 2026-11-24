-- connection_tests: each test of a saved connection, and how it went. Owner: workspace.
CREATE TABLE connection_tests (
  id          TEXT  NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, issued when the test ran
  connection  TEXT  NOT NULL REFERENCES connections (id) ON DELETE CASCADE,    -- the connection tested
  outcome     TEXT  NOT NULL CHECK (outcome IN ('passed', 'warning', 'failed')),  -- passed, passed with a warning, or failed
  tested_at   TEXT  NOT NULL                                                   -- UTC, RFC 3339
) STRICT;
