-- integrity: what MySQL's tables require that a foreign key cannot say, as queries returning the rows breaking it. Owner: mysql.
-- Run by the store with the cortex's integrity.sql before every commit to a schema file whose engine is mysql.

-- name: table-options-on-tables
-- Table options belong to an object of the kind table.
SELECT 'table-options-on-tables', t.id FROM mysql__table_options t JOIN objects o ON o.id = t.id WHERE o.kind <> 'table';

-- name: program-context-on-programs
-- A program context belongs to a view, procedure, function, trigger, event or library.
SELECT 'program-context-on-programs', p.id FROM mysql__program_context p JOIN objects o ON o.id = p.id
  WHERE o.kind NOT IN ('view', 'procedure', 'function', 'trigger', 'event', 'library');

-- name: event-and-trigger-context
-- time_zone and disabled_on_replica belong to an event, follows and precedes to a trigger.
SELECT 'event-and-trigger-context', p.id FROM mysql__program_context p JOIN objects o ON o.id = p.id
  WHERE (o.kind <> 'event' AND (p.time_zone IS NOT NULL OR p.disabled_on_replica IS NOT NULL))
     OR (o.kind <> 'trigger' AND (p.follows IS NOT NULL OR p.precedes IS NOT NULL));

-- name: kinds-of-their-tables
-- A loadable function, a tablespace and a spatial reference system are rows of objects of their own kind.
SELECT 'kinds-of-their-tables', x.id FROM mysql__loadable_functions x JOIN objects o ON o.id = x.id WHERE o.kind <> 'loadable_function'
UNION ALL SELECT 'kinds-of-their-tables', x.id FROM mysql__tablespaces x JOIN objects o ON o.id = x.id WHERE o.kind <> 'tablespace'
UNION ALL SELECT 'kinds-of-their-tables', x.id FROM mysql__spatial_reference_systems x JOIN objects o ON o.id = x.id WHERE o.kind <> 'spatial_reference_system';

-- name: partition-options-on-partitions
-- Partition options belong to a partition or a subpartition.
SELECT 'partition-options-on-partitions', p.id FROM mysql__partition_options p
  WHERE p.id NOT IN (SELECT id FROM partitions) AND p.id NOT IN (SELECT id FROM mysql__subpartitions);

-- name: subpartitions-of-subpartitioned-tables
-- A partition has named subpartitions only when its table is subpartitioned.
SELECT 'subpartitions-of-subpartitioned-tables', s.id FROM mysql__subpartitions s JOIN partitions p ON p.id = s.partition
  WHERE p.partitioning NOT IN (SELECT id FROM mysql__subpartitionings);
