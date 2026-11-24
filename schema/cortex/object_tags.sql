-- object_tags: the tags of an object (scd2, pii), in order. Owner: cortex.
CREATE TABLE object_tags (
  id        TEXT    NOT NULL PRIMARY KEY,                                      -- <object>.tag<position>: o_orders.tag1
  object    TEXT    NOT NULL REFERENCES objects (id) ON DELETE CASCADE,        -- the object tagged
  position  INTEGER NOT NULL CHECK (position >= 1),                            -- its place among the object's tags
  tag       TEXT    NOT NULL CHECK (length(tag) >= 1),                         -- the tag
  UNIQUE (object, position),
  UNIQUE (object, tag),
  CHECK (id = object || '.tag' || position)
) STRICT;
