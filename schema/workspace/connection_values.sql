-- workspace.connection_values: the value of each field a connection's engine declares, by the field's key; never a field the engine declares secret. Owner: workspace.
CREATE TABLE workspace.connection_values (
  id          TEXT NOT NULL PRIMARY KEY,                                              -- <connection>.<field key>
  connection  UUID NOT NULL REFERENCES workspace.connections (id) ON DELETE CASCADE,  -- the connection
  field       TEXT NOT NULL CHECK (length(field) >= 1),                               -- the key of a field the engine declares, as the engine gives it
  value       TEXT NOT NULL CHECK (length(value) >= 1),                               -- its value; a field left empty has no row, and the engine's default applies
  UNIQUE (connection, field),
  CHECK (id = connection || '.' || field)
);

COMMENT ON TABLE workspace.connection_values IS 'the value of each field a connection''s engine declares, by the field''s key; never a field the engine declares secret.';
COMMENT ON COLUMN workspace.connection_values.id IS '<connection>.<field key>';
COMMENT ON COLUMN workspace.connection_values."connection" IS 'the connection';
COMMENT ON COLUMN workspace.connection_values.field IS 'the key of a field the engine declares, as the engine gives it';
COMMENT ON COLUMN workspace.connection_values.value IS 'its value; a field left empty has no row, and the engine''s default applies';
