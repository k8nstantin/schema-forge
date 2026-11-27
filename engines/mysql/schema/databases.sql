-- engine_mysql.databases: a database (a schema, in MySQL's words) of the server: a namespace under its instance, with what MySQL says of it.
CREATE TABLE engine_mysql.databases (
  id              UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex namespace
  design          UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  character_set   TEXT NOT NULL,                                                                                   -- its default character set (utf8mb4)
  "collation"     TEXT NOT NULL,                                                                                   -- its default collation (utf8mb4_0900_ai_ci)
  encryption      BOOLEAN,                                                                                         -- its default encryption (DEFAULT ENCRYPTION, 8.0.16 and later); NULL before
  read_only       BOOLEAN,                                                                                         -- true when made read only (READ ONLY, 8.0.22 and later); NULL before
  flavor_options  JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
