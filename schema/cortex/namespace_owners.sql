-- cortex.namespace_owners: the role a namespace belongs to (a PostgreSQL schema's owner), one row a namespace that has one: apart from cortex.namespaces, which every object refers to, so a namespace and its owner's role never refer to each other. Owner: cortex.
CREATE TABLE cortex.namespace_owners (
  id          UUID NOT NULL PRIMARY KEY,                                                                    -- the namespace
  design      UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  owner       UUID,                                                                                         -- the role it belongs to; NULL when named instead
  owner_name  TEXT CHECK (length(owner_name) >= 1),                                                         -- its owner by name, where the design holds no role of that name; NULL when owner is set
  CHECK (num_nonnulls(owner, owner_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.namespaces (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, owner) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX namespace_owners_owner ON cortex.namespace_owners (design, owner);

COMMENT ON TABLE cortex.namespace_owners IS 'the role a namespace belongs to (a PostgreSQL schema''s owner), one row a namespace that has one: apart from cortex.namespaces, which every object refers to, so a namespace and its owner''s role never refer to each other.';
COMMENT ON COLUMN cortex.namespace_owners.id IS 'the namespace';
COMMENT ON COLUMN cortex.namespace_owners.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.namespace_owners.owner IS 'the role it belongs to; NULL when named instead';
COMMENT ON COLUMN cortex.namespace_owners.owner_name IS 'its owner by name, where the design holds no role of that name; NULL when owner is set';
