-- engine_mysql.routines: a stored procedure or function (its kind is the cortex object's): what it returns, how it runs, its body exactly as the server holds it, and the context it was made in; its parameters are engine_mysql.routine_parameters, the libraries it uses its cortex dependencies.
CREATE TABLE engine_mysql.routines (
  id                    UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design                UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  parameter_list        TEXT NOT NULL DEFAULT '',                                                                        -- its parameter list exactly as written, between the parentheses: MySQL keeps it as typed (its parameters, parsed, are engine_mysql.routine_parameters)
  returns               TEXT,                                                                                            -- a function's RETURNS type, as written; NULL for a procedure
  deterministic         BOOLEAN NOT NULL DEFAULT false,                                                                  -- DETERMINISTIC
  data_access           TEXT NOT NULL DEFAULT 'CONTAINS SQL' CHECK (data_access IN ('CONTAINS SQL', 'NO SQL', 'READS SQL DATA', 'MODIFIES SQL DATA')),  -- what it does with data
  security              TEXT NOT NULL DEFAULT 'DEFINER' CHECK (security IN ('DEFINER', 'INVOKER')),                       -- SQL SECURITY
  definer               TEXT NOT NULL,                                                                                   -- DEFINER, as written (`app`@`%`)
  language              TEXT NOT NULL DEFAULT 'SQL' CHECK (language IN ('SQL', 'JAVASCRIPT')),                            -- LANGUAGE (JAVASCRIPT, 9.7)
  body                  TEXT NOT NULL,                                                                                   -- its body, exactly as SHOW CREATE writes it
  sql_mode              TEXT NOT NULL,                                                                                   -- the SQL mode it was made under
  character_set_client  TEXT NOT NULL,                                                                                   -- the client character set it was made with
  collation_connection  TEXT NOT NULL,                                                                                   -- the connection collation it was made with
  database_collation    TEXT NOT NULL,                                                                                   -- its database's collation when it was made
  flavor_options        JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(flavor_options) = 'object'),                     -- what only its flavor says of it, by the keys its flavor declares
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
