-- cortex.workspace_connection_values: the value of each field a connection's engine declares, by the field's key; never a field the engine declares secret. Owner: cortex.
CREATE TABLE cortex.workspace_connection_values (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                             -- UUIDv7, made with the row
  connection  UUID NOT NULL REFERENCES cortex.workspace_connections (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the connection
  field       TEXT NOT NULL CHECK (length(field) >= 1),                                                                    -- the key of a field the engine declares, as the engine gives it
  value       TEXT NOT NULL CHECK (length(value) >= 1),                                                                    -- its value; a field left empty has no row, and the engine's default applies
  UNIQUE (connection, field) DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.workspace_connection_values IS 'the value of each field a connection''s engine declares, by the field''s key; never a field the engine declares secret.';
COMMENT ON COLUMN cortex.workspace_connection_values.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.workspace_connection_values.connection IS 'the connection';
COMMENT ON COLUMN cortex.workspace_connection_values.field IS 'the key of a field the engine declares, as the engine gives it';
COMMENT ON COLUMN cortex.workspace_connection_values.value IS 'its value; a field left empty has no row, and the engine''s default applies';
