-- engine_mysql.subpartitions: the subpartitions of a partition, in order. Owner: mysql.
CREATE TABLE engine_mysql.subpartitions (
  id           UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row
  design       UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  "partition"  UUID NOT NULL,                                                                                 -- the partition split
  position     NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  name         TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- its name
  UNIQUE ("partition", position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, "partition") REFERENCES cortex.partitions (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX subpartitions_partition ON engine_mysql.subpartitions (design, "partition");

COMMENT ON TABLE engine_mysql.subpartitions IS 'the subpartitions of a partition, in order.';
COMMENT ON COLUMN engine_mysql.subpartitions.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_mysql.subpartitions.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.subpartitions."partition" IS 'the partition split';
COMMENT ON COLUMN engine_mysql.subpartitions.position IS 'its place, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN engine_mysql.subpartitions.name IS 'its name';
