-- cortex.turns: one round of work on a design (an import, a person's edit, the agent's answer to a prompt, an undo, a restore); every change belongs to one; a named turn is a savepoint.
CREATE TABLE cortex.turns (
  id          UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                     -- a UUIDv7 made with its row: turns sort in the order they began
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,        -- the design
  branch      UUID NOT NULL,                                                                                       -- the branch it was made on
  parent      UUID,                                                                                                -- the turn it follows: the branch's head when it began; NULL for a design's first
  kind        TEXT NOT NULL CHECK (kind IN ('import', 'edit', 'agent', 'undo', 'restore', 'switch')),              -- what made it
  state       TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'committed', 'rejected', 'undone')),           -- open while it runs; committed or rejected when it ends; undone when a later turn undid it
  seq         INTEGER CHECK (seq >= 1),                                                                            -- its place in its design's commit order, given when it commits; NULL until then
  author      TEXT NOT NULL CHECK (length(author) >= 1),                                                           -- who made it: a person's name, or the agent's
  prompt      TEXT,                                                                                                -- the prompt it answers, for an agent's turn
  summary     TEXT,                                                                                                -- what it did, in a sentence
  name        TEXT CHECK (length(name) BETWEEN 1 AND 100),                                                         -- its savepoint name, when someone named it; NULL otherwise
  started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),                                                                  -- when it began
  ended_at    TIMESTAMPTZ,                                                                                         -- when it ended; NULL while open
  UNIQUE (design, id),
  UNIQUE (design, seq),
  UNIQUE (design, name),
  CHECK ((state = 'open') = (ended_at IS NULL)),
  CHECK ((seq IS NULL) = (state IN ('open', 'rejected'))),
  FOREIGN KEY (design, branch) REFERENCES cortex.branches (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.turns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX turns_branch ON cortex.turns (design, branch);
CREATE INDEX turns_parent ON cortex.turns (design, parent);
