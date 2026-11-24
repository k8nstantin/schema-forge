-- integrity: what a foreign key cannot say, as queries that return the rows breaking it. Owner: cortex.
-- The store runs every query here before it commits a transaction that wrote this file; a query that returns a row
-- refuses the commit, naming the query and the row. Each query is a SELECT that names its rule in the first column.
-- An engine ships its own integrity.sql beside its tables, run the same way.

-- name: link-from-columns-on-from-object
-- Every from_column of a link is a column of the link's from_object.
SELECT 'link-from-columns-on-from-object', lc.id FROM link_columns lc JOIN links l ON l.id = lc.link
  JOIN columns c ON c.id = lc.from_column WHERE c.object <> l.from_object;

-- name: link-to-columns-on-to-object
-- Every to_column of a link is a column of the link's to_object.
SELECT 'link-to-columns-on-to-object', lc.id FROM link_columns lc JOIN links l ON l.id = lc.link
  JOIN columns c ON c.id = lc.to_column WHERE c.object <> l.to_object;

-- name: key-columns-on-their-table
-- Every column of a key is a column of the key's table.
SELECT 'key-columns-on-their-table', kc.id FROM key_columns kc JOIN keys k ON k.id = kc.key
  JOIN columns c ON c.id = kc."column" WHERE c.object <> k.object;

-- name: index-columns-on-their-table
-- Every column an index orders by or includes is a column of the index's table.
SELECT 'index-columns-on-their-table', p.id FROM index_parts p JOIN indexes i ON i.id = p."index"
  JOIN columns c ON c.id = p."column" WHERE c.object <> i.object
UNION ALL
SELECT 'index-columns-on-their-table', x.id FROM index_includes x JOIN indexes i ON i.id = x."index"
  JOIN columns c ON c.id = x."column" WHERE c.object <> i.object;

-- name: partition-columns-on-their-table
-- Every column a table is partitioned or ordered by is a column of that table.
SELECT 'partition-columns-on-their-table', f.id FROM partition_fields f
  JOIN columns c ON c.id = f."column" WHERE c.object <> f.partitioning
UNION ALL
SELECT 'partition-columns-on-their-table', o.id FROM order_fields o
  JOIN columns c ON c.id = o."column" WHERE c.object <> o.object;

-- name: keys-on-table-kinds
-- Only an object of a kind that holds keys has keys, indexes or a partitioning.
SELECT 'keys-on-table-kinds', k.id FROM keys k JOIN objects o ON o.id = k.object
  JOIN kinds t ON t.id = o.kind WHERE t.table_like = 0
UNION ALL
SELECT 'keys-on-table-kinds', i.id FROM indexes i JOIN objects o ON o.id = i.object
  JOIN kinds t ON t.id = o.kind WHERE t.table_like = 0
UNION ALL
SELECT 'keys-on-table-kinds', p.id FROM partitionings p JOIN objects o ON o.id = p.id
  JOIN kinds t ON t.id = o.kind WHERE t.table_like = 0;

-- name: one-program-part
-- An object holds at most one of a query, a routine, a trigger, an event, a sequence and a domain.
SELECT 'one-program-part', o.id FROM objects o WHERE
  (o.id IN (SELECT id FROM queries)) + (o.id IN (SELECT id FROM routines)) + (o.id IN (SELECT id FROM triggers))
  + (o.id IN (SELECT id FROM events)) + (o.id IN (SELECT id FROM sequences)) + (o.id IN (SELECT id FROM domains)) > 1;

-- name: turn-takes-back-an-earlier-turn
-- A turn that undoes another began after it.
SELECT 'turn-takes-back-an-earlier-turn', t.id FROM turns t WHERE t.undoes IS NOT NULL AND t.undoes >= t.id;

-- name: operation-after-its-turn
-- An operation's id is after its turn's id: a turn begins with its first operation.
SELECT 'operation-after-its-turn', o.id FROM operations o WHERE o.id < o.turn;

-- name: versions-follow-the-log
-- A higher version holds a later operation.
SELECT 'versions-follow-the-log', b.id FROM versions a JOIN versions b ON b.number = a.number + 1
  WHERE b.at_operation <= a.at_operation;

-- name: one-schema-row
-- The file holds its schema's row (the table allows at most one).
SELECT 'one-schema-row', 'schema' WHERE (SELECT count(*) FROM schema) <> 1;
