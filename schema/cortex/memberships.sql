-- cortex.memberships: which roles a role or an account is a member of (PostgreSQL's GRANT role TO member; MySQL 8's roles), each with whether the member may grant it on. Owner: cortex.
CREATE TABLE cortex.memberships (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  role          UUID NOT NULL,                                                                                -- the role granted
  member        UUID NOT NULL,                                                                                -- the role or account it is granted to
  admin_option  BOOLEAN NOT NULL DEFAULT false,                                                               -- true when the member may grant the role on (WITH ADMIN OPTION)
  position      NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place among the member's roles, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  options       JSONB NOT NULL DEFAULT '{}',                                                                  -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written
  UNIQUE (role, member) DEFERRABLE INITIALLY DEFERRED,
  CHECK (role <> member),
  UNIQUE (design, id),
  FOREIGN KEY (design, role) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, member) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX memberships_role ON cortex.memberships (design, role);
CREATE INDEX memberships_member ON cortex.memberships (design, member);

COMMENT ON TABLE cortex.memberships IS 'which roles a role or an account is a member of (PostgreSQL''s GRANT role TO member; MySQL 8''s roles), each with whether the member may grant it on.';
COMMENT ON COLUMN cortex.memberships.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN cortex.memberships.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.memberships.role IS 'the role granted';
COMMENT ON COLUMN cortex.memberships.member IS 'the role or account it is granted to';
COMMENT ON COLUMN cortex.memberships.admin_option IS 'true when the member may grant the role on (WITH ADMIN OPTION)';
COMMENT ON COLUMN cortex.memberships.position IS 'its place among the member''s roles, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
COMMENT ON COLUMN cortex.memberships.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written';
