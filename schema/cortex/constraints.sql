-- cortex.constraints: a table's primary key, unique keys, checks and foreign keys, with what every engine says of them; what only one engine has (an exclusion constraint, a NOT NULL constraint by name) is its plugin's.
CREATE TABLE cortex.constraints (
  id                  UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row, kept when the name changes
  design              UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  object              UUID NOT NULL,                                                                                   -- the table it is on
  position            INTEGER NOT NULL CHECK (position >= 1),                                                          -- its place among the table's constraints, as the server lists them
  name                TEXT,                                                                                            -- its name; NULL where the engine gives it none
  kind                TEXT NOT NULL CHECK (kind IN ('primary', 'unique', 'check', 'foreign')),                         -- what it is
  expression          TEXT,                                                                                            -- a check's expression, as the engine writes it; NULL otherwise
  to_object           UUID,                                                                                            -- the table a foreign key refers to; NULL otherwise
  on_delete           TEXT CHECK (on_delete IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),       -- what a foreign key does when the row it refers to is deleted; NULL otherwise
  on_update           TEXT CHECK (on_update IN ('no_action', 'restrict', 'cascade', 'set_null', 'set_default')),       -- what a foreign key does when the key it refers to changes; NULL otherwise
  enforced            BOOLEAN NOT NULL DEFAULT true,                                                                   -- false for one the database holds but does not enforce (NOT ENFORCED)
  "deferrable"        BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when it may be checked at the end of a transaction
  initially_deferred  BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when it is checked at the end unless said otherwise
  UNIQUE (design, id),
  UNIQUE (object, position) DEFERRABLE INITIALLY DEFERRED,
  CHECK ((kind = 'check') = (expression IS NOT NULL)),
  CHECK ((kind = 'foreign') = (to_object IS NOT NULL)),
  CHECK (kind = 'foreign' OR (on_delete IS NULL AND on_update IS NULL)),
  CHECK ("deferrable" OR NOT initially_deferred),
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, to_object) REFERENCES cortex.objects (design, id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX constraints_object ON cortex.constraints (design, object);
CREATE INDEX constraints_to_object ON cortex.constraints (design, to_object);
