-- ui.perspective_members: the tables and columns a custom perspective shows, in order. Owner: ui.
CREATE TABLE ui.perspective_members (
  id           UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  perspective  UUID NOT NULL,                                                                                 -- the perspective
  object       UUID NOT NULL,                                                                                 -- the table or view shown
  "column"     UUID,                                                                                          -- one of its columns, shown alone; NULL for the whole object
  position     NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place in the perspective; an order key
  colour       TEXT CHECK (colour ~ '^#[0-9a-f]{6}$'),                                                        -- its own colour, as #rrggbb; NULL to follow the perspective's colour_by
  UNIQUE (perspective, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE NULLS NOT DISTINCT (perspective, object, "column") DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, perspective) REFERENCES ui.custom_perspectives (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX perspective_members_perspective ON ui.perspective_members (design, perspective);
CREATE INDEX perspective_members_object ON ui.perspective_members (design, object);
CREATE INDEX perspective_members_column ON ui.perspective_members (design, "column");

COMMENT ON TABLE ui.perspective_members IS 'the tables and columns a custom perspective shows, in order.';
COMMENT ON COLUMN ui.perspective_members.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN ui.perspective_members.design IS 'the design it belongs to';
COMMENT ON COLUMN ui.perspective_members.perspective IS 'the perspective';
COMMENT ON COLUMN ui.perspective_members.object IS 'the table or view shown';
COMMENT ON COLUMN ui.perspective_members."column" IS 'one of its columns, shown alone; NULL for the whole object';
COMMENT ON COLUMN ui.perspective_members.position IS 'its place in the perspective; an order key';
COMMENT ON COLUMN ui.perspective_members.colour IS 'its own colour, as #rrggbb; NULL to follow the perspective''s colour_by';
