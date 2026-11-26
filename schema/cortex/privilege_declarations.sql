-- cortex.privilege_declarations: the privileges each engine has, at the levels it grants them (the server, a namespace, an object, a column), in the versions that have them: a grant of any other is refused. Owner: cortex.
CREATE TABLE cortex.privilege_declarations (
  id         TEXT NOT NULL PRIMARY KEY,                                                                 -- <engine>/<privilege>: mysql/CREATE ROUTINE
  engine     TEXT NOT NULL CHECK (engine ~ '^[a-z0-9_]+$'),                                             -- the engine
  privilege  TEXT NOT NULL CHECK (length(privilege) >= 1),                                             -- as the engine names it (SELECT, BACKUP_ADMIN); with pattern, a regular expression
  levels     JSONB NOT NULL CHECK (jsonb_typeof(levels) = 'array' AND jsonb_array_length(levels) >= 1), -- where it is granted: any of server, namespace, object, column
  pattern    BOOLEAN NOT NULL DEFAULT false,                                                            -- true when privilege is a regular expression: MySQL's dynamic privileges, which its components register
  since      TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                 -- the first version that has it; NULL for every one
  "until"    TEXT REFERENCES cortex.engine_versions (id) DEFERRABLE INITIALLY DEFERRED,                 -- the last version that has it; NULL for every later one
  about      TEXT NOT NULL CHECK (length(about) >= 1),                                                  -- what it lets its grantee do
  UNIQUE (engine, privilege),
  CHECK (pattern OR privilege ~ '^[A-Z][A-Z_ ]*$'),
  CHECK (id = engine || '/' || privilege OR pattern)
);

COMMENT ON TABLE cortex.privilege_declarations IS 'the privileges each engine has, at the levels it grants them (the server, a namespace, an object, a column), in the versions that have them: a grant of any other is refused.';
COMMENT ON COLUMN cortex.privilege_declarations.id IS '<engine>/<privilege>: mysql/CREATE ROUTINE';
COMMENT ON COLUMN cortex.privilege_declarations.engine IS 'the engine';
COMMENT ON COLUMN cortex.privilege_declarations.privilege IS 'as the engine names it (SELECT, BACKUP_ADMIN); with pattern, a regular expression';
COMMENT ON COLUMN cortex.privilege_declarations.levels IS 'where it is granted: any of server, namespace, object, column';
COMMENT ON COLUMN cortex.privilege_declarations.pattern IS 'true when privilege is a regular expression: MySQL''s dynamic privileges, which its components register';
COMMENT ON COLUMN cortex.privilege_declarations.since IS 'the first version that has it; NULL for every one';
COMMENT ON COLUMN cortex.privilege_declarations."until" IS 'the last version that has it; NULL for every later one';
COMMENT ON COLUMN cortex.privilege_declarations.about IS 'what it lets its grantee do';
