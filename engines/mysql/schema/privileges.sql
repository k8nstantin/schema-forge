-- engine_mysql.privileges: one privilege granted to an account or role, at its level: the server (*.*), a database, a table, a column of it, a routine, or a proxied account; with GRANT OPTION. Static and dynamic privileges by name.
CREATE TABLE engine_mysql.privileges (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                     -- a UUIDv7 made with its row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,        -- the design
  grantee       UUID NOT NULL,                                                                                       -- the account or role
  privilege     TEXT NOT NULL CHECK (privilege ~ '^[A-Z][A-Z0-9_ ]*$'),                                              -- as the server names it (SELECT, ALTER ROUTINE, BACKUP_ADMIN)
  level         TEXT NOT NULL CHECK (level IN ('global', 'database', 'table', 'column', 'routine', 'proxy')),        -- where it is granted
  database_name TEXT,                                                                                                -- the database, at the database, table, column and routine levels, as written (wildcards allowed at the database level)
  object        UUID,                                                                                                -- the table or routine of the design it is granted on; NULL where it names one outside the design
  object_name   TEXT,                                                                                                -- the table or routine's name, as written, at those levels
  routine_kind  TEXT CHECK (routine_kind IN ('PROCEDURE', 'FUNCTION')),                                              -- at the routine level, which kind of routine it names
  column_name   TEXT,                                                                                                -- the column, at the column level
  proxied       UUID,                                                                                                -- the account a PROXY privilege lets it act as
  grant_option  BOOLEAN NOT NULL DEFAULT false,                                                                      -- WITH GRANT OPTION
  UNIQUE (design, id),
  CHECK ((level IN ('global', 'proxy')) = (database_name IS NULL)),
  CHECK ((level IN ('table', 'column', 'routine')) = (object_name IS NOT NULL)),
  CHECK ((level = 'column') = (column_name IS NOT NULL)),
  CHECK ((level = 'routine') = (routine_kind IS NOT NULL)),
  CHECK ((level = 'proxy') = (proxied IS NOT NULL)),
  FOREIGN KEY (design, grantee) REFERENCES engine_mysql.accounts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, proxied) REFERENCES engine_mysql.accounts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX privileges_grantee ON engine_mysql.privileges (design, grantee);
CREATE INDEX privileges_object ON engine_mysql.privileges (design, object);
CREATE INDEX privileges_proxied ON engine_mysql.privileges (design, proxied);
