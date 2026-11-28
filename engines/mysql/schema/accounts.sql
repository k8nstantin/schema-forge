-- engine_mysql.accounts: an account of the server, or a role (its kind is the cortex object's: account or role): how it signs in, its password's hash exactly as the server keeps it (never the password), and its limits and policies.
CREATE TABLE engine_mysql.accounts (
  id                        UUID NOT NULL PRIMARY KEY,                                                                       -- its cortex object; its name is user@host
  design                    UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,    -- the design
  user_name                 TEXT NOT NULL,                                                                                   -- the user part, as written (may be empty: the anonymous account)
  host                      TEXT NOT NULL,                                                                                   -- the host part, as written (%)
  auth_plugin               TEXT,                                                                                            -- IDENTIFIED WITH, the plugin
  auth_string               TEXT,                                                                                            -- IDENTIFIED WITH ... AS, the password's hash exactly as the server keeps it (a 0x hex literal where it is binary), written back so the account signs in as before; NULL for an account without a password; never the password itself, which no server gives
  ssl_type                  TEXT CHECK (ssl_type IN ('NONE', 'SSL', 'X509', 'SPECIFIED')),                                   -- REQUIRE
  ssl_cipher                TEXT,                                                                                            -- REQUIRE CIPHER, where written
  x509_issuer               TEXT,                                                                                            -- REQUIRE ISSUER, where written
  x509_subject              TEXT,                                                                                            -- REQUIRE SUBJECT, where written
  max_queries_per_hour      INTEGER NOT NULL DEFAULT 0 CHECK (max_queries_per_hour >= 0),                                    -- WITH MAX_QUERIES_PER_HOUR; 0 for no limit
  max_updates_per_hour      INTEGER NOT NULL DEFAULT 0 CHECK (max_updates_per_hour >= 0),                                    -- WITH MAX_UPDATES_PER_HOUR
  max_connections_per_hour  INTEGER NOT NULL DEFAULT 0 CHECK (max_connections_per_hour >= 0),                                -- WITH MAX_CONNECTIONS_PER_HOUR
  max_user_connections      INTEGER NOT NULL DEFAULT 0 CHECK (max_user_connections >= 0),                                    -- WITH MAX_USER_CONNECTIONS
  password_expire           TEXT,                                                                                            -- PASSWORD EXPIRE, as written (DEFAULT, NEVER, INTERVAL 90 DAY); NULL where not written
  password_history          TEXT,                                                                                            -- PASSWORD HISTORY, where written (8.0 and later)
  password_reuse_interval   TEXT,                                                                                            -- PASSWORD REUSE INTERVAL, where written
  password_require_current  TEXT,                                                                                            -- PASSWORD REQUIRE CURRENT, where written
  failed_login_attempts     INTEGER,                                                                                         -- FAILED_LOGIN_ATTEMPTS, where written (8.0.19 and later)
  password_lock_time        TEXT,                                                                                            -- PASSWORD_LOCK_TIME, where written (a number of days or UNBOUNDED)
  locked                    BOOLEAN NOT NULL DEFAULT false,                                                                  -- ACCOUNT LOCK
  attributes                JSONB,                                                                                           -- its ATTRIBUTE or COMMENT, a JSON value as the server keeps it (8.0.21 and later)
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);
