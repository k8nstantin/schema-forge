-- mysql__link_options: a foreign key written on its column (REFERENCES) instead of as a constraint.
-- Owner: mysql. Shipped in the MySQL plugin (engines/mysql); created in a schema file whose engine is mysql, and in no other.
CREATE TABLE mysql__link_options (
  id      TEXT     NOT NULL PRIMARY KEY REFERENCES links (id) ON DELETE CASCADE,  -- the link
  inline  INTEGER  NOT NULL CHECK (inline = 1)                             -- present only for a link written on its column
) STRICT;
