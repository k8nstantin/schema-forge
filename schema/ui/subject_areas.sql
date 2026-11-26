-- ui.subject_areas: groups of objects by subject (billing, catalog), across namespaces, as the canvas groups and colours them. Owner: ui.
CREATE TABLE ui.subject_areas (
  id        UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it groups objects of
  name      TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- billing
  colour    TEXT CHECK (colour ~ '^#[0-9a-f]{6}$'),                                                        -- its colour, as #rrggbb; NULL for the canvas's choice
  position  NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among its design's areas; an order key
  UNIQUE (design, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id)
);

COMMENT ON TABLE ui.subject_areas IS 'groups of objects by subject (billing, catalog), across namespaces, as the canvas groups and colours them.';
COMMENT ON COLUMN ui.subject_areas.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN ui.subject_areas.design IS 'the design it groups objects of';
COMMENT ON COLUMN ui.subject_areas.name IS 'billing';
COMMENT ON COLUMN ui.subject_areas.colour IS 'its colour, as #rrggbb; NULL for the canvas''s choice';
COMMENT ON COLUMN ui.subject_areas.position IS 'its place among its design''s areas; an order key';
