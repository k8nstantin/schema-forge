-- engine_mysql.compression_dictionaries: Percona Server's compression dictionary (CREATE COMPRESSION_DICTIONARY): the data compressed columns are compressed with; refused on every other flavor.
CREATE TABLE engine_mysql.compression_dictionaries (
  id      UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  data    TEXT NOT NULL,                                                                                   -- its data, as written
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
