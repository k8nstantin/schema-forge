-- cortex.objects: everything a namespace holds: tables, views, routines, triggers, events, sequences, types, whatever kinds the engine declares. Owner: cortex.
CREATE TABLE cortex.objects (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row, kept when the name changes
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  namespace  UUID NOT NULL,                                                                                 -- the namespace that holds it
  kind       TEXT NOT NULL CHECK (kind ~ '^[a-z0-9_]+$'),                                                   -- one of its design's engine's kinds (table): the rule kinds-of-the-engine refuses any other
  name       TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- orders
  signature  TEXT NOT NULL DEFAULT '',                                                                      -- the argument types that tell an overloaded routine apart ((integer, text)); empty where a name is enough
  parent     UUID,                                                                                          -- the object it belongs to: a trigger's table; NULL for none
  position   NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among its namespace's objects, in the order made or read; an order key
  comment    TEXT,                                                                                          -- what it holds, in a sentence or two: written into its SQL
  notes      TEXT,                                                                                          -- longer notes for people and the agent: never written into SQL
  UNIQUE (namespace, kind, name, signature) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (namespace, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX objects_namespace ON cortex.objects (design, namespace);
CREATE INDEX objects_parent ON cortex.objects (design, parent);

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds: tables, views, routines, triggers, events, sequences, types, whatever kinds the engine declares.';
COMMENT ON COLUMN cortex.objects.id IS 'UUIDv7, made with the row, kept when the name changes';
COMMENT ON COLUMN cortex.objects.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it';
COMMENT ON COLUMN cortex.objects.kind IS 'one of its design''s engine''s kinds (table): the rule kinds-of-the-engine refuses any other';
COMMENT ON COLUMN cortex.objects.name IS 'orders';
COMMENT ON COLUMN cortex.objects.signature IS 'the argument types that tell an overloaded routine apart ((integer, text)); empty where a name is enough';
COMMENT ON COLUMN cortex.objects.parent IS 'the object it belongs to: a trigger''s table; NULL for none';
COMMENT ON COLUMN cortex.objects.position IS 'its place among its namespace''s objects, in the order made or read; an order key';
COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';
COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';
