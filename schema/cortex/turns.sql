-- cortex.turns: one round of work: the agent's answer to one prompt, a person's edit, an import, an undo, a restore. Every change belongs to one; each follows the turn before it, so turns form a tree. Owner: cortex.
CREATE TABLE cortex.turns (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, issued by the database: its order is the order turns began
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  seq         BIGINT CHECK (seq >= 1),                                                                       -- its number in its design's commit order, given as it ends: a copy holding the design at a number catches up by the turns after it; NULL while it is open
  parent      UUID,                                                                                          -- the turn it follows; NULL for the first
  branch      UUID NOT NULL,                                                                                 -- the branch it was made on
  by          TEXT NOT NULL CHECK (by IN ('agent', 'person', 'import')),                                     -- who made it
  who         TEXT NOT NULL CHECK (length(who) >= 1),                                                        -- the agent's label, the person's name, or the source read
  summary     TEXT NOT NULL CHECK (length(summary) >= 1),                                                    -- what it does, in one line, as its maker gives it
  state       TEXT NOT NULL CHECK (state IN ('open', 'accepted', 'rejected', 'undone')),                     -- open while it awaits a verdict; then accepted, rejected or undone
  undoes      UUID,                                                                                          -- the turn this one takes back by applying its inverses; NULL for any other turn
  started_at  TIMESTAMPTZ NOT NULL,                                                                          -- when its first change landed
  ended_at    TIMESTAMPTZ,                                                                                   -- when its maker ended it; NULL while it is being made
  decided_at  TIMESTAMPTZ,                                                                                   -- when it was accepted, rejected or undone; NULL while open
  decided_by  TEXT,                                                                                          -- who decided it; NULL while open
  CHECK ((state = 'open') = (decided_at IS NULL)),
  CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
  CHECK (undoes IS NULL OR undoes <> id),
  CHECK (parent IS NULL OR parent <> id),
  UNIQUE (design, seq),
  UNIQUE (design, id),
  FOREIGN KEY (design, parent) REFERENCES cortex.turns (design, id),
  FOREIGN KEY (design, branch) REFERENCES cortex.branches (design, id) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, undoes) REFERENCES cortex.turns (design, id)
);

CREATE INDEX turns_parent ON cortex.turns (design, parent);
CREATE INDEX turns_branch ON cortex.turns (design, branch);
CREATE INDEX turns_undoes ON cortex.turns (design, undoes);

COMMENT ON TABLE cortex.turns IS 'one round of work: the agent''s answer to one prompt, a person''s edit, an import, an undo, a restore. Every change belongs to one; each follows the turn before it, so turns form a tree.';
COMMENT ON COLUMN cortex.turns.id IS 'UUIDv7, issued by the database: its order is the order turns began';
COMMENT ON COLUMN cortex.turns.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.turns.parent IS 'the turn it follows; NULL for the first';
COMMENT ON COLUMN cortex.turns.branch IS 'the branch it was made on';
COMMENT ON COLUMN cortex.turns.by IS 'who made it';
COMMENT ON COLUMN cortex.turns.who IS 'the agent''s label, the person''s name, or the source read';
COMMENT ON COLUMN cortex.turns.summary IS 'what it does, in one line, as its maker gives it';
COMMENT ON COLUMN cortex.turns.state IS 'open while it awaits a verdict; then accepted, rejected or undone';
COMMENT ON COLUMN cortex.turns.undoes IS 'the turn this one takes back by applying its inverses; NULL for any other turn';
COMMENT ON COLUMN cortex.turns.started_at IS 'when its first change landed';
COMMENT ON COLUMN cortex.turns.ended_at IS 'when its maker ended it; NULL while it is being made';
COMMENT ON COLUMN cortex.turns.decided_at IS 'when it was accepted, rejected or undone; NULL while open';
COMMENT ON COLUMN cortex.turns.decided_by IS 'who decided it; NULL while open';
COMMENT ON COLUMN cortex.turns.seq IS 'its number in its design''s commit order, given as it ends: a copy holding the design at a number catches up by the turns after it; NULL while it is open';
