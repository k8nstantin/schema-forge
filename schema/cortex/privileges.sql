-- cortex.privileges: what a role or an account may do, one privilege a row: on the whole server (MySQL's *.*), on a namespace, on an object or on one column, given to a role or account the design holds or, by name, to one it does not (PUBLIC). An engine's grant statements are written from these rows. Owner: cortex.
CREATE TABLE cortex.privileges (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  grantee       UUID,                                                                                         -- the role or account given it; NULL when it is named instead
  grantee_name  TEXT CHECK (length(grantee_name) >= 1),                                                       -- the grantee by name, where the design holds no object for it: PUBLIC, or an account another server has; NULL when grantee is set
  namespace     UUID,                                                                                         -- the namespace it is on (MySQL's db.*, a PostgreSQL schema); NULL otherwise
  object        UUID,                                                                                         -- the object it is on (a table, a view, a routine, a sequence, a type); NULL otherwise
  "column"      UUID,                                                                                         -- the one column it is on; NULL otherwise. With namespace and object NULL too, it is on the whole server
  privilege     TEXT NOT NULL CHECK (privilege ~ '^[A-Z][A-Z_ ]*$'),                                          -- as the engine names it (SELECT, CREATE ROUTINE, USAGE)
  grantable     BOOLEAN NOT NULL DEFAULT false,                                                               -- true when the grantee may give it on (WITH GRANT OPTION)
  position      NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place among the grants of its target, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  options       JSONB NOT NULL DEFAULT '{}',                                                                  -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written
  UNIQUE NULLS NOT DISTINCT (design, grantee, grantee_name, namespace, object, "column", privilege) DEFERRABLE INITIALLY DEFERRED,
  CHECK (num_nonnulls(grantee, grantee_name) = 1),
  CHECK (num_nonnulls(namespace, object, "column") <= 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, grantee) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, namespace) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, object) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX privileges_grantee ON cortex.privileges (design, grantee);
CREATE INDEX privileges_namespace ON cortex.privileges (design, namespace);
CREATE INDEX privileges_object ON cortex.privileges (design, object);
CREATE INDEX privileges_column ON cortex.privileges (design, "column");

COMMENT ON TABLE cortex.privileges IS 'what a role or an account may do, one privilege a row: on the whole server (MySQL''s *.*), on a namespace, on an object or on one column, given to a role or account the design holds or, by name, to one it does not (PUBLIC). An engine''s grant statements are written from these rows.';
COMMENT ON COLUMN cortex.privileges.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.privileges.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.privileges.grantee IS 'the role or account given it; NULL when it is named instead';
COMMENT ON COLUMN cortex.privileges.grantee_name IS 'the grantee by name, where the design holds no object for it: PUBLIC, or an account another server has; NULL when grantee is set';
COMMENT ON COLUMN cortex.privileges.namespace IS 'the namespace it is on (MySQL''s db.*, a PostgreSQL schema); NULL otherwise';
COMMENT ON COLUMN cortex.privileges.object IS 'the object it is on (a table, a view, a routine, a sequence, a type); NULL otherwise';
COMMENT ON COLUMN cortex.privileges."column" IS 'the one column it is on; NULL otherwise. With namespace and object NULL too, it is on the whole server';
COMMENT ON COLUMN cortex.privileges.privilege IS 'as the engine names it (SELECT, CREATE ROUTINE, USAGE)';
COMMENT ON COLUMN cortex.privileges.grantable IS 'true when the grantee may give it on (WITH GRANT OPTION)';
COMMENT ON COLUMN cortex.privileges.position IS 'its place among the grants of its target, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.privileges.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written';
