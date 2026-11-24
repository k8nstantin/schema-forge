-- mysql__view_options: what MySQL says of a view beyond its query.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__view_options (
  id            TEXT  NOT NULL PRIMARY KEY REFERENCES queries (id) ON DELETE CASCADE,  -- the view
  algorithm     TEXT  CHECK (algorithm IN ('UNDEFINED', 'MERGE', 'TEMPTABLE')),  -- how its query is run; NULL when not written
  check_option  TEXT  CHECK (check_option IN ('CASCADED', 'LOCAL')),             -- whether rows written through it must match it; NULL for none
  security      TEXT  CHECK (security IN ('DEFINER', 'INVOKER'))                 -- whose rights it runs with (SQL SECURITY); NULL when not written
) STRICT;
