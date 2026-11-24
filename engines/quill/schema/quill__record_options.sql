-- quill__record_options: what Quill says of a record beyond the cortex: whether it is kept in memory.
-- Owner: quill. Shipped in the Quill plugin (engines/quill); created in a schema file whose engine is quill, and in no other.
CREATE TABLE quill__record_options (
  id    TEXT     NOT NULL PRIMARY KEY REFERENCES objects (id) ON DELETE CASCADE,  -- the record
  fast  INTEGER  NOT NULL CHECK (fast = 1)                                  -- present only for a record written fast (kept in memory), from Quill version 2
) STRICT;
