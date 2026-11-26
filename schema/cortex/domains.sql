-- cortex.domains: a type narrowed by a default, a not null and checks (its checks are in constraints). Owner: cortex.
CREATE TABLE cortex.domains (
  id             BIGINT NOT NULL PRIMARY KEY,                                                                   -- the domain
  design         UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  base           TEXT NOT NULL CHECK (length(base) >= 1),                                                       -- the type it narrows, as the engine writes it
  default_value  TEXT,                                                                                          -- its default, in the engine's SQL; NULL for none
  nullable       BOOLEAN NOT NULL DEFAULT true,                                                                 -- true when it may hold null
  "collation"    TEXT,                                                                                          -- its collation where it is not its base type's; NULL for that one
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.domains IS 'a type narrowed by a default, a not null and checks (its checks are in constraints).';
COMMENT ON COLUMN cortex.domains.id IS 'the domain';
COMMENT ON COLUMN cortex.domains.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.domains.base IS 'the type it narrows, as the engine writes it';
COMMENT ON COLUMN cortex.domains.default_value IS 'its default, in the engine''s SQL; NULL for none';
COMMENT ON COLUMN cortex.domains.nullable IS 'true when it may hold null';
COMMENT ON COLUMN cortex.domains."collation" IS 'its collation where it is not its base type''s; NULL for that one';
