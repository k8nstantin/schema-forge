-- ui.object_places: where the tool puts an object: its subject area, and the family it is put in by hand. Owner: ui.
CREATE TABLE ui.object_places (
  id      UUID NOT NULL PRIMARY KEY,                                                                     -- the object
  design  UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  area    UUID,                                                                                          -- the subject area it belongs to; NULL for none
  family  TEXT CHECK (length(family) >= 1),                                                              -- the family it is put in by hand, overriding the one worked out from its name; NULL for that one
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, area) REFERENCES ui.subject_areas (design, id) ON DELETE SET NULL (area) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX object_places_area ON ui.object_places (design, area);

COMMENT ON TABLE ui.object_places IS 'where the tool puts an object: its subject area, and the family it is put in by hand.';
COMMENT ON COLUMN ui.object_places.id IS 'the object';
COMMENT ON COLUMN ui.object_places.design IS 'the design it belongs to';
COMMENT ON COLUMN ui.object_places.area IS 'the subject area it belongs to; NULL for none';
COMMENT ON COLUMN ui.object_places.family IS 'the family it is put in by hand, overriding the one worked out from its name; NULL for that one';
