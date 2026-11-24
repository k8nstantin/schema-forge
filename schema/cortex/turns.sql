-- turns: one round of work: the agent's answer to one prompt, a person's edit, an import, an undo. Every change belongs to one (decision 8). Owner: cortex.
-- A turn is accepted or rejected whole; a rejected or undone turn stays, and the turn that takes it back names it in undoes (decision 9).
CREATE TABLE turns (
  id          TEXT  NOT NULL PRIMARY KEY CHECK (length(id) = 36 AND substr(id, 15, 1) = '7'),  -- UUIDv7, issued in increasing order by the file's one writer: its order is the order turns began
  by          TEXT  NOT NULL CHECK (by IN ('agent', 'person', 'import')),     -- who made it
  who         TEXT  NOT NULL CHECK (length(who) >= 1),                        -- the agent's label (claude-opus-5-5), the person's name, or the source read (a file path, a connection name)
  summary     TEXT  NOT NULL CHECK (length(summary) >= 1),                    -- what it does, in one line, as its maker gives it
  state       TEXT  NOT NULL CHECK (state IN ('open', 'accepted', 'rejected', 'undone')),  -- open while it awaits a verdict; then accepted, rejected or undone
  undoes      TEXT  REFERENCES turns (id),                                    -- the turn this one takes back, by applying its inverses; NULL for any other turn
  started_at  TEXT  NOT NULL,                                                 -- when its first change landed, UTC, RFC 3339
  ended_at    TEXT,                                                           -- when its maker ended it, UTC, RFC 3339; NULL while it is still being made
  decided_at  TEXT,                                                           -- when it was accepted, rejected or undone; NULL while open
  decided_by  TEXT,                                                           -- who decided it; NULL while open
  CHECK ((state = 'open') = (decided_at IS NULL)),
  CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
  CHECK (undoes IS NULL OR undoes <> id)
) STRICT;
