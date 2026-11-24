-- type_fields: the fields of a composite type, in order. Owner: cortex.
CREATE TABLE type_fields (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <object>.field<position>: o_address.field1
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the type
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place in the type
  name      TEXT    NOT NULL CHECK (length(name) >= 1),                        -- its name
  type      TEXT    NOT NULL CHECK (length(type) >= 1),                        -- its type, as the engine writes it
  comment   TEXT,                                                              -- what it holds
  UNIQUE (object, position),
  UNIQUE (object, name),
  CHECK (id = object || '.field' || position)
) STRICT;
