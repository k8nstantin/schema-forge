-- engine_postgresql.operator_class_members: the operators and support functions an operator class lists (OPERATOR 1 <, FUNCTION 1 cmp(int, int)): one the design holds is a reference, a built-in its name. Owner: postgresql.
CREATE TABLE engine_postgresql.operator_class_members (
  id              UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design          UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  operator_class  UUID NOT NULL,                                                                                -- the operator class
  what            TEXT NOT NULL CHECK (what IN ('operator', 'function')),                                       -- an operator or a support function
  number          INTEGER NOT NULL CHECK (number > 0),                                                          -- its strategy or support number, as the access method numbers them
  member          UUID,                                                                                         -- the operator or function; NULL when named instead
  member_name     TEXT CHECK (length(member_name) >= 1),                                                        -- it by signature, a built-in (>(integer,integer)); NULL when member is set
  position        NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered
  CHECK (num_nonnulls(member, member_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, operator_class) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, member) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX operator_class_members_operator_class ON engine_postgresql.operator_class_members (design, operator_class);
CREATE INDEX operator_class_members_member ON engine_postgresql.operator_class_members (design, member);

COMMENT ON TABLE engine_postgresql.operator_class_members IS 'the operators and support functions an operator class lists (OPERATOR 1 <, FUNCTION 1 cmp(int, int)): one the design holds is a reference, a built-in its name.';
COMMENT ON COLUMN engine_postgresql.operator_class_members.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.operator_class_members.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.operator_class_members.operator_class IS 'the operator class';
COMMENT ON COLUMN engine_postgresql.operator_class_members.what IS 'an operator or a support function';
COMMENT ON COLUMN engine_postgresql.operator_class_members.number IS 'its strategy or support number, as the access method numbers them';
COMMENT ON COLUMN engine_postgresql.operator_class_members.member IS 'the operator or function; NULL when named instead';
COMMENT ON COLUMN engine_postgresql.operator_class_members.member_name IS 'it by signature, a built-in (>(integer,integer)); NULL when member is set';
COMMENT ON COLUMN engine_postgresql.operator_class_members.position IS 'its place in the list, 1 first; an order key: one put between two takes their midpoint, so nothing is renumbered';
