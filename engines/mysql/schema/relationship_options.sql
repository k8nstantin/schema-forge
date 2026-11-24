-- engine_mysql.relationship_options: a foreign key written on its column (REFERENCES) instead of as a constraint.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.
CREATE TABLE engine_mysql.relationship_options (
  id      TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.relationships (id) ON DELETE CASCADE,  -- the link
  inline  BOOLEAN NOT NULL CHECK (inline)                                                       -- present only for a foreign key written on its column
);

COMMENT ON TABLE engine_mysql.relationship_options IS 'a foreign key written on its column (REFERENCES) instead of as a constraint. Shipped in the MySQL plugin (engines/mysql); created in a schema database whose engine is mysql, and in no other.';
COMMENT ON COLUMN engine_mysql.relationship_options.id IS 'the link';
COMMENT ON COLUMN engine_mysql.relationship_options.inline IS 'present only for a foreign key written on its column';
