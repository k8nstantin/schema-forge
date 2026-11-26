-- ui.pinned_notes: a note pinned to one thing of the design or the tool, or to the whole design, for people and the agent; it goes when what it is pinned to goes. Owner: ui.
CREATE TABLE ui.pinned_notes (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it is pinned in: alone, a note on the whole design
  namespace     UUID,                                                                                          -- the namespace it is pinned to; NULL when pinned elsewhere
  object        UUID,                                                                                          -- the object it is pinned to; NULL when pinned elsewhere
  "column"      UUID,                                                                                          -- the column it is pinned to; NULL when pinned elsewhere
  "constraint"  UUID,                                                                                          -- the key, check or link it is pinned to; NULL when pinned elsewhere
  "index"       UUID,                                                                                          -- the index it is pinned to; NULL when pinned elsewhere
  area          UUID,                                                                                          -- the subject area it is pinned to; NULL when pinned elsewhere
  perspective   UUID,                                                                                          -- the perspective it is pinned to; NULL when pinned elsewhere
  turn          UUID,                                                                                          -- the turn it is pinned to; NULL when pinned elsewhere
  position      NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among its design's notes; an order key
  text          TEXT NOT NULL CHECK (length(text) >= 1),                                                       -- the note, as written
  done          BOOLEAN NOT NULL DEFAULT false,                                                                -- true once it has been worked through
  written_by    TEXT NOT NULL CHECK (length(written_by) >= 1),                                                 -- who wrote it: a person's name or the agent's label
  CHECK (num_nonnulls(namespace, object, "column", "constraint", "index", area, perspective, turn) <= 1),
  UNIQUE (design, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "constraint") REFERENCES cortex.constraints (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "index") REFERENCES cortex.indexes (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, area) REFERENCES ui.subject_areas (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, perspective) REFERENCES ui.custom_perspectives (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, turn) REFERENCES cortex.turns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX pinned_notes_namespace ON ui.pinned_notes (design, namespace);
CREATE INDEX pinned_notes_object ON ui.pinned_notes (design, object);
CREATE INDEX pinned_notes_column ON ui.pinned_notes (design, "column");
CREATE INDEX pinned_notes_constraint ON ui.pinned_notes (design, "constraint");
CREATE INDEX pinned_notes_index ON ui.pinned_notes (design, "index");
CREATE INDEX pinned_notes_area ON ui.pinned_notes (design, area);
CREATE INDEX pinned_notes_perspective ON ui.pinned_notes (design, perspective);
CREATE INDEX pinned_notes_turn ON ui.pinned_notes (design, turn);

COMMENT ON TABLE ui.pinned_notes IS 'a note pinned to one thing of the design or the tool, or to the whole design, for people and the agent; it goes when what it is pinned to goes.';
COMMENT ON COLUMN ui.pinned_notes.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN ui.pinned_notes.design IS 'the design it is pinned in: alone, a note on the whole design';
COMMENT ON COLUMN ui.pinned_notes.namespace IS 'the namespace it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes.object IS 'the object it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes."column" IS 'the column it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes."constraint" IS 'the key, check or link it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes."index" IS 'the index it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes.area IS 'the subject area it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes.perspective IS 'the perspective it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes.turn IS 'the turn it is pinned to; NULL when pinned elsewhere';
COMMENT ON COLUMN ui.pinned_notes.position IS 'its place among its design''s notes; an order key';
COMMENT ON COLUMN ui.pinned_notes.text IS 'the note, as written';
COMMENT ON COLUMN ui.pinned_notes.done IS 'true once it has been worked through';
COMMENT ON COLUMN ui.pinned_notes.written_by IS 'who wrote it: a person''s name or the agent''s label';
