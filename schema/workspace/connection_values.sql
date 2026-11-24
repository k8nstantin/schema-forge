-- connection_values: the value of each field a connection's engine declares, by the field's key; never a field the engine declares secret. Owner: workspace.
CREATE TABLE connection_values (
  id          TEXT  NOT NULL PRIMARY KEY,                                      -- <connection>.<field key>
  connection  TEXT  NOT NULL REFERENCES connections (id) ON DELETE CASCADE,    -- the connection
  field       TEXT  NOT NULL CHECK (length(field) >= 1),                       -- the key of a field the engine declares, as the engine gives it
  value       TEXT  NOT NULL CHECK (length(value) >= 1),                       -- its value; a field left empty has no row, and the engine's default applies
  UNIQUE (connection, field),
  CHECK (id = connection || '.' || field)
) STRICT;
