-- cortex.objects: everything a namespace holds, of a kind its design's engine has (a table, a view, a routine, a trigger, an event, a type); what only its engine says of it is a row of its kind's plugin table, with the same id.
CREATE TABLE cortex.objects (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row, kept when the name changes
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  engine     TEXT NOT NULL,                                                                                   -- its design's engine: it ties the object's kind to that engine's kinds
  namespace  UUID NOT NULL,                                                                                   -- the namespace that holds it
  kind       TEXT NOT NULL,                                                                                   -- one of its engine's kinds (table)
  name       TEXT NOT NULL CHECK (length(name) >= 1),                                                         -- as the engine names it (orders)
  signature  TEXT NOT NULL DEFAULT '',                                                                        -- what tells overloaded routines apart ((integer, text)); empty where the name is enough
  parent     UUID,                                                                                            -- the object it belongs to (a trigger's table); NULL for none
  position   NUMERIC NOT NULL CHECK (position > 0),                                                           -- its place among its namespace's objects, in the order made or read; one put between two takes their midpoint
  comment    TEXT,                                                                                            -- what it holds, in a sentence or two: written into its SQL
  notes      TEXT,                                                                                            -- longer notes for people and the agent: never written into SQL
  UNIQUE (design, id),
  UNIQUE (namespace, kind, name, signature) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (namespace, position) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, engine) REFERENCES cortex.designs (id, engine) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (engine, kind) REFERENCES cortex.object_kinds (engine, kind),
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX objects_namespace ON cortex.objects (design, namespace);
CREATE INDEX objects_parent ON cortex.objects (design, parent);
CREATE INDEX objects_kind ON cortex.objects (engine, kind);
