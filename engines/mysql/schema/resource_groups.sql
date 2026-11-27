-- engine_mysql.resource_groups: a resource group made on the server (CREATE RESOURCE GROUP, 8.0 and later), not one MySQL ships.
CREATE TABLE engine_mysql.resource_groups (
  id               UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  type             TEXT NOT NULL CHECK (type IN ('SYSTEM', 'USER')),                                                -- TYPE
  enabled          BOOLEAN NOT NULL DEFAULT true,                                                                   -- ENABLE or DISABLE
  vcpus            TEXT,                                                                                            -- VCPU, as written (0-3,5); NULL for every CPU
  thread_priority  INTEGER NOT NULL DEFAULT 0,                                                                      -- THREAD_PRIORITY
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
