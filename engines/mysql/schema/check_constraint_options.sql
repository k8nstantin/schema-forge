-- engine_mysql.check_constraint_options: a check declared but not enforced.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.check_constraint_options (
  id            TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.check_constraints (id) ON DELETE CASCADE,  -- the check
  not_enforced  BOOLEAN NOT NULL CHECK (not_enforced)                           -- present only for a check written NOT ENFORCED
);

COMMENT ON TABLE engine_mysql.check_constraint_options IS 'a check declared but not enforced. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.check_constraint_options.id IS 'the check';
COMMENT ON COLUMN engine_mysql.check_constraint_options.not_enforced IS 'present only for a check written NOT ENFORCED';
