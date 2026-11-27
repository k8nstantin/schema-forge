-- engine_mysql.servers: a server a FEDERATED table connects through (CREATE SERVER): where it is and as whom, never its password.
CREATE TABLE engine_mysql.servers (
  id             UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  wrapper        TEXT NOT NULL DEFAULT 'mysql',                                                                   -- FOREIGN DATA WRAPPER
  host           TEXT,                                                                                            -- HOST
  port           INTEGER CHECK (port BETWEEN 0 AND 65535),                                                        -- PORT
  socket         TEXT,                                                                                            -- SOCKET
  database_name  TEXT,                                                                                            -- DATABASE
  user_name      TEXT,                                                                                            -- USER; its PASSWORD is never kept
  owner          TEXT,                                                                                            -- OWNER
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
