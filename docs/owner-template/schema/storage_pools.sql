-- engine_example.storage_pools: a storage pool, a kind of object only Example has (CREATE POOL). Owner: example.
-- Shape 3, an engine-only kind: the object is a cortex row of the kind storage_pool, which Example declares in object_kinds;
-- what only a pool has is here, one row per pool.
CREATE TABLE engine_example.storage_pools (
  id        BIGINT  NOT NULL PRIMARY KEY,                                                                  -- the pool, an object of the kind storage_pool
  location  TEXT    NOT NULL CHECK (length(location) >= 1),                                                -- where its files are, as written
  quota_gb  INTEGER CHECK (quota_gb >= 1),                                                                 -- how much it may hold, in GB; NULL for no limit
  design    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE
);

COMMENT ON TABLE engine_example.storage_pools IS 'a storage pool, a kind of object only Example has (CREATE POOL). Shape 3, an engine-only kind: the object is a cortex row of the kind storage_pool, which Example declares in object_kinds; what only a pool has is here, one row per pool.';
COMMENT ON COLUMN engine_example.storage_pools.id IS 'the pool, an object of the kind storage_pool';
COMMENT ON COLUMN engine_example.storage_pools.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_example.storage_pools.location IS 'where its files are, as written';
COMMENT ON COLUMN engine_example.storage_pools.quota_gb IS 'how much it may hold, in GB; NULL for no limit';
