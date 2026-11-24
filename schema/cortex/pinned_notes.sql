-- cortex.pinned_notes: a note pinned to anything of the design, for people and the agent (@notes). Owner: cortex.
-- Part of the design (decision canvas-state): shared by everyone on the schema and the agent, every change an operation of a turn.
-- A note is not removed with what it is pinned to: the operation that removes a part removes or moves its notes in the same turn,
-- and the rule notes-on-what-exists refuses a commit that leaves one pinned to nothing.
CREATE TABLE cortex.pinned_notes (
  id           TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^note[1-9][0-9]*$'),   -- note<n>, n given once from id_counters and never reused: note1
  target_kind  TEXT    NOT NULL CHECK (target_kind IN ('schema', 'namespace', 'object', 'column', 'relationship', 'area', 'part', 'turn', 'locked_version')),  -- what it is pinned to: a part is any numbered part (a key, an index, a check…)
  target_id    TEXT    NOT NULL CHECK (length(target_id) >= 1),                 -- the id of what it is pinned to (o_orders, c_orders_total, o_orders.key1, a turn's id); for the schema, schema
  position     NUMERIC NOT NULL UNIQUE CHECK (position > 0),                    -- its place among the notes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered
  text         TEXT    NOT NULL CHECK (length(text) >= 1),                      -- the note, as written
  done         BOOLEAN NOT NULL DEFAULT false,                                  -- true once it has been worked through
  written_by   TEXT    NOT NULL CHECK (length(written_by) >= 1)                 -- who wrote it: a person's name or the agent's label
);

COMMENT ON TABLE cortex.pinned_notes IS 'a note pinned to anything of the design, for people and the agent (@notes). Part of the design (decision canvas-state): shared by everyone on the schema and the agent, every change an operation of a turn. A note is not removed with what it is pinned to: the operation that removes a part removes or moves its notes in the same turn, and the rule notes-on-what-exists refuses a commit that leaves one pinned to nothing.';
COMMENT ON COLUMN cortex.pinned_notes.id IS 'note<n>, n given once from id_counters and never reused: note1';
COMMENT ON COLUMN cortex.pinned_notes.target_kind IS 'what it is pinned to: a part is any numbered part (a key, an index, a check…)';
COMMENT ON COLUMN cortex.pinned_notes.target_id IS 'the id of what it is pinned to (o_orders, c_orders_total, o_orders.key1, a turn''s id); for the schema, schema';
COMMENT ON COLUMN cortex.pinned_notes.position IS 'its place among the notes; an order key: one put between two takes their midpoint (NUMERIC, so the midpoints never run out), so nothing is renumbered';
COMMENT ON COLUMN cortex.pinned_notes.text IS 'the note, as written';
COMMENT ON COLUMN cortex.pinned_notes.done IS 'true once it has been worked through';
COMMENT ON COLUMN cortex.pinned_notes.written_by IS 'who wrote it: a person''s name or the agent''s label';
