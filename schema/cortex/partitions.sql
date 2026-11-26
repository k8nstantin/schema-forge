-- cortex.partitions: the partitions of a table, in order, with their bounds; where the engine makes a partition a table of its own, that table. Owner: cortex.
CREATE TABLE cortex.partitions (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  partitioning  UUID NOT NULL,                                                                                 -- the partitioning
  position      INTEGER NOT NULL CHECK (position >= 1),                                                        -- its place, 1 first
  name          TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- its name
  bounds        TEXT,                                                                                          -- its bounds as the engine writes them (2025, FOR VALUES IN ('east')); NULL where the strategy gives none
  table_object  UUID,                                                                                          -- the table it is, where the engine makes partitions tables (PostgreSQL); NULL otherwise
  comment       TEXT,                                                                                          -- what it holds; NULL for none
  UNIQUE (partitioning, name) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (partitioning, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, partitioning) REFERENCES cortex.partitionings (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, table_object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX partitions_partitioning ON cortex.partitions (design, partitioning);
CREATE INDEX partitions_table_object ON cortex.partitions (design, table_object);

COMMENT ON TABLE cortex.partitions IS 'the partitions of a table, in order, with their bounds; where the engine makes a partition a table of its own, that table.';
COMMENT ON COLUMN cortex.partitions.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.partitions.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.partitions.partitioning IS 'the partitioning';
COMMENT ON COLUMN cortex.partitions.position IS 'its place, 1 first';
COMMENT ON COLUMN cortex.partitions.name IS 'its name';
COMMENT ON COLUMN cortex.partitions.bounds IS 'its bounds as the engine writes them (2025, FOR VALUES IN (''east'')); NULL where the strategy gives none';
COMMENT ON COLUMN cortex.partitions.table_object IS 'the table it is, where the engine makes partitions tables (PostgreSQL); NULL otherwise';
COMMENT ON COLUMN cortex.partitions.comment IS 'what it holds; NULL for none';
