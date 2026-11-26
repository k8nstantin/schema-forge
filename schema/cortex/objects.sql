-- cortex.objects: everything a namespace holds, and what the server holds beside its namespaces: tables, views, routines, triggers, events, sequences, types, tablespaces, whatever kinds the engine declares. Owner: cortex.
CREATE TABLE cortex.objects (
  id         UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),               -- UUIDv7, made with the row, kept when the name changes
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  namespace  UUID,                                                                                          -- the namespace that holds it; NULL for an object of a kind the server holds (scope server): the guard check_kinds sees to both
  kind       TEXT NOT NULL CHECK (kind ~ '^[a-z0-9_]+$'),                                                   -- one of its design's engine's kinds (table): the guard check_kinds refuses any other as the row is written
  name       TEXT NOT NULL CHECK (length(name) >= 1),                                                       -- orders
  signature  TEXT NOT NULL DEFAULT '',                                                                      -- the argument types that tell an overloaded routine apart ((integer, text)); empty where a name is enough
  parent     UUID,                                                                                          -- the object it belongs to: a trigger's table; NULL for none
  position   NUMERIC NOT NULL CHECK (position > 0),                                                         -- its place among its namespace's objects (or the server's), in the order made or read; an order key
  comment    TEXT,                                                                                          -- what it holds, in a sentence or two: written into its SQL
  notes      TEXT,                                                                                          -- longer notes for people and the agent: never written into SQL
  options    JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE NULLS NOT DISTINCT (design, namespace, parent, kind, name, signature) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE NULLS NOT DISTINCT (design, namespace, position) DEFERRABLE INITIALLY DEFERRED,
  UNIQUE (design, id),
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, parent) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX objects_namespace ON cortex.objects (design, namespace);
CREATE INDEX objects_parent ON cortex.objects (design, parent);

COMMENT ON TABLE cortex.objects IS 'everything a namespace holds, and what the server holds beside its namespaces: tables, views, routines, triggers, events, sequences, types, tablespaces, whatever kinds the engine declares.';
COMMENT ON COLUMN cortex.objects.id IS 'UUIDv7, made with the row, kept when the name changes';
COMMENT ON COLUMN cortex.objects.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.objects.namespace IS 'the namespace that holds it; NULL for an object of a kind the server holds (scope server): the guard check_kinds sees to both';
COMMENT ON COLUMN cortex.objects.kind IS 'one of its design''s engine''s kinds (table): the guard check_kinds refuses any other as the row is written';
COMMENT ON COLUMN cortex.objects.name IS 'orders';
COMMENT ON COLUMN cortex.objects.signature IS 'the argument types that tell an overloaded routine apart ((integer, text)); empty where a name is enough';
COMMENT ON COLUMN cortex.objects.parent IS 'the object it belongs to: a trigger''s table; NULL for none';
COMMENT ON COLUMN cortex.objects.position IS 'its place among its namespace''s objects (or the server''s), in the order made or read; an order key';
COMMENT ON COLUMN cortex.objects.comment IS 'what it holds, in a sentence or two: written into its SQL';
COMMENT ON COLUMN cortex.objects.notes IS 'longer notes for people and the agent: never written into SQL';
COMMENT ON COLUMN cortex.objects.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
