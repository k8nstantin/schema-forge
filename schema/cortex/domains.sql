-- cortex.domains: a type narrowed by a default, a not null and checks (its checks are in check_constraints). Owner: cortex.
CREATE TABLE cortex.domains (
  id             TEXT    NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE,  -- the domain
  base           TEXT    NOT NULL CHECK (length(base) >= 1),                                     -- the type it narrows, as the engine writes it
  default_value  TEXT,                                                                           -- its default, in the engine's SQL; NULL for none
  nullable       BOOLEAN NOT NULL DEFAULT true                                                   -- true when it may hold null
);

COMMENT ON TABLE cortex.domains IS 'a type narrowed by a default, a not null and checks (its checks are in check_constraints).';
COMMENT ON COLUMN cortex.domains.id IS 'the domain';
COMMENT ON COLUMN cortex.domains.base IS 'the type it narrows, as the engine writes it';
COMMENT ON COLUMN cortex.domains.default_value IS 'its default, in the engine''s SQL; NULL for none';
COMMENT ON COLUMN cortex.domains.nullable IS 'true when it may hold null';
