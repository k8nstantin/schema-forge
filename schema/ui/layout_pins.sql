-- ui.layout_pins: a table's place pinned in one view of the canvas; everything not pinned is laid out afresh each time. Owner: ui.
CREATE TABLE ui.layout_pins (
  id           UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  view         TEXT CHECK (length(view) >= 1),                                                                -- a built-in view and its focus (map, map/billing); NULL for a custom perspective
  perspective  UUID,                                                                                          -- the custom perspective it is pinned in: the pin goes with it; NULL for a built-in view
  object       UUID NOT NULL,                                                                                 -- the table or view pinned
  x            NUMERIC NOT NULL,                                                                              -- across, in the layout's grid units from its left
  y            NUMERIC NOT NULL,                                                                              -- down, in the layout's grid units from its top
  CHECK ((view IS NULL) <> (perspective IS NULL)),
  UNIQUE NULLS NOT DISTINCT (view, perspective, object) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, perspective) REFERENCES ui.custom_perspectives (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX layout_pins_perspective ON ui.layout_pins (design, perspective);
CREATE INDEX layout_pins_object ON ui.layout_pins (design, object);

COMMENT ON TABLE ui.layout_pins IS 'a table''s place pinned in one view of the canvas; everything not pinned is laid out afresh each time.';
COMMENT ON COLUMN ui.layout_pins.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN ui.layout_pins.design IS 'the design it belongs to';
COMMENT ON COLUMN ui.layout_pins.view IS 'a built-in view and its focus (map, map/billing); NULL for a custom perspective';
COMMENT ON COLUMN ui.layout_pins.perspective IS 'the custom perspective it is pinned in: the pin goes with it; NULL for a built-in view';
COMMENT ON COLUMN ui.layout_pins.object IS 'the table or view pinned';
COMMENT ON COLUMN ui.layout_pins.x IS 'across, in the layout''s grid units from its left';
COMMENT ON COLUMN ui.layout_pins.y IS 'down, in the layout''s grid units from its top';
