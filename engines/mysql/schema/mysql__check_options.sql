-- mysql__check_options: a check declared but not enforced.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__check_options (
  id            TEXT     NOT NULL PRIMARY KEY REFERENCES checks (id) ON DELETE CASCADE,  -- the check
  not_enforced  INTEGER  NOT NULL CHECK (not_enforced = 1)                 -- present only for a check written NOT ENFORCED
) STRICT;
