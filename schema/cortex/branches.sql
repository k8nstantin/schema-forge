-- cortex.branches: a line of work: its newest turn. Switching branch moves the design to its newest turn. Owner: cortex.
CREATE TABLE cortex.branches (
  id       UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design   UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it is a line of work on
  name     TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- main, experiment
  head     UUID,                                                                                          -- its newest turn, or the turn it forks from before it has one (a rule holds it to a turn: turns name their branch, so a key here would be a cycle); NULL before the first turn
  current  BOOLEAN NOT NULL DEFAULT false,                                                                -- true for the branch its design is on: exactly one per design, held at commit
  UNIQUE (design, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id)
);

COMMENT ON TABLE cortex.branches IS 'a line of work: its newest turn. Switching branch moves the design to its newest turn.';
COMMENT ON COLUMN cortex.branches.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.branches.design IS 'the design it is a line of work on';
COMMENT ON COLUMN cortex.branches.name IS 'main, experiment';
COMMENT ON COLUMN cortex.branches.head IS 'its newest turn, or the turn it forks from before it has one (a rule holds it to a turn: turns name their branch, so a key here would be a cycle); NULL before the first turn';
COMMENT ON COLUMN cortex.branches.current IS 'true for the branch its design is on: exactly one per design, held at commit';
