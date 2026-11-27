-- engine_mysql.role_grants: a role granted to an account or another role (8.0 and later), with ADMIN OPTION, and whether it is one of the account's default roles.
CREATE TABLE engine_mysql.role_grants (
  id            UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),                 -- a UUIDv7 made with its row
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  grantee       UUID NOT NULL,                                                                                   -- the account or role it is granted to
  role          UUID NOT NULL,                                                                                   -- the role granted
  admin_option  BOOLEAN NOT NULL DEFAULT false,                                                                  -- WITH ADMIN OPTION
  is_default    BOOLEAN NOT NULL DEFAULT false,                                                                  -- true when it is one of the grantee's DEFAULT ROLE
  UNIQUE (design, id),
  UNIQUE (grantee, role) DEFERRABLE INITIALLY DEFERRED,
  CHECK (grantee <> role),
  FOREIGN KEY (design, grantee) REFERENCES engine_mysql.accounts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, role) REFERENCES engine_mysql.accounts (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX role_grants_grantee ON engine_mysql.role_grants (design, grantee);
CREATE INDEX role_grants_role ON engine_mysql.role_grants (design, role);
