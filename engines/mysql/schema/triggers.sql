-- engine_mysql.triggers: a trigger: when it fires and its body as the server holds it, with the context it was made in; its table is its cortex object's parent.
CREATE TABLE engine_mysql.triggers (
  id                    UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  timing                TEXT NOT NULL CHECK (timing IN ('BEFORE', 'AFTER')),                                              -- BEFORE or AFTER
  event                 TEXT NOT NULL CHECK (event IN ('INSERT', 'UPDATE', 'DELETE')),                                    -- the change it fires on
  action_order          INTEGER NOT NULL CHECK (action_order >= 1),                                                      -- its order among its table's triggers of the same timing and event (FOLLOWS, PRECEDES)
  body                  TEXT NOT NULL,                                                                                   -- its body, exactly as SHOW CREATE TRIGGER writes it
  definer               TEXT NOT NULL,                                                                                   -- DEFINER, as written
  sql_mode              TEXT NOT NULL,                                                                                   -- the SQL mode it was made under
  character_set_client  TEXT NOT NULL,                                                                                   -- the client character set it was made with
  collation_connection  TEXT NOT NULL,                                                                                   -- the connection collation it was made with
  database_collation    TEXT NOT NULL,                                                                                   -- its database's collation when it was made
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
