-- ui.object_places: where the tool puts an object: its subject area, and the family it is put in by hand. Owner: ui.
CREATE TABLE ui.object_places (
  id      BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the object
  area    BIGINT REFERENCES ui.subject_areas (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,                    -- the subject area it belongs to; NULL for none
  family  TEXT CHECK (length(family) >= 1)                                                                             -- the family it is put in by hand, overriding the one worked out from its name; NULL for that one
);

COMMENT ON TABLE ui.object_places IS 'where the tool puts an object: its subject area, and the family it is put in by hand.';
COMMENT ON COLUMN ui.object_places.id IS 'the object';
COMMENT ON COLUMN ui.object_places.area IS 'the subject area it belongs to; NULL for none';
COMMENT ON COLUMN ui.object_places.family IS 'the family it is put in by hand, overriding the one worked out from its name; NULL for that one';
