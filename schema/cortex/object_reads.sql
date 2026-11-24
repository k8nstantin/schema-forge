-- object_reads: the objects an object is made from or reads (a view's query), worked out by the engine, in the order first named. Owner: cortex.
CREATE TABLE object_reads (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <object>.read<position>: o_current_orders.read1
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the object that reads
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- the order the reader names them in
  reads     TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the object read
  UNIQUE (object, position),
  UNIQUE (object, reads),
  CHECK (object <> reads),
  CHECK (id = object || '.read' || position)
) STRICT;
