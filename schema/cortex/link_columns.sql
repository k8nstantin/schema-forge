-- link_columns: the column pairs of a link, in order: from_column refers to to_column. Owner: cortex.
CREATE TABLE link_columns (
  id           TEXT    NOT NULL PRIMARY KEY,                                   -- <link>.<position>: l_orders_customer.1
  link         TEXT    NOT NULL REFERENCES links (id) ON DELETE CASCADE,       -- the link
  position     INTEGER NOT NULL CHECK (position >= 1),                         -- the pair's place in the link
  from_column  TEXT    NOT NULL REFERENCES columns (id) ON DELETE CASCADE,     -- a column of the link's from_object
  to_column    TEXT    NOT NULL REFERENCES columns (id) ON DELETE CASCADE,     -- a column of the link's to_object
  UNIQUE (link, position),
  CHECK (id = link || '.' || position)
) STRICT;
