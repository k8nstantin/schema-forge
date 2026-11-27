-- engine_mysql.libraries: a JavaScript library (CREATE LIBRARY, 9.7): its language and source as the server holds it; the routines that use it name it as a cortex dependency.
CREATE TABLE engine_mysql.libraries (
  id        UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  language  TEXT NOT NULL DEFAULT 'JAVASCRIPT' CHECK (language IN ('JAVASCRIPT')),                           -- LANGUAGE
  source    TEXT NOT NULL,                                                                                   -- its source, exactly as SHOW CREATE LIBRARY writes it
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
