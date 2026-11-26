-- engine_postgresql.ts_config_mappings: which dictionaries a text search configuration consults for a token type, in order (ALTER TEXT SEARCH CONFIGURATION ... ADD MAPPING FOR token WITH d1, d2): a dictionary the design holds is a reference, a built-in its name. Owner: postgresql.
CREATE TABLE engine_postgresql.ts_config_mappings (
  id               UUID NOT NULL PRIMARY KEY DEFAULT uuidv7() CHECK (uuid_extract_version(id) = 7),              -- UUIDv7, made with the row
  design           UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, -- the design it belongs to
  configuration    UUID NOT NULL,                                                                                -- the text search configuration
  token            TEXT NOT NULL CHECK (length(token) >= 1),                                                     -- the parser's token type, by its alias (asciiword)
  dictionary       UUID,                                                                                         -- the dictionary; NULL when named instead
  dictionary_name  TEXT CHECK (length(dictionary_name) >= 1),                                                    -- the dictionary by schema.name, a built-in (pg_catalog.simple); NULL when dictionary is set
  position         NUMERIC NOT NULL CHECK (position > 0),                                                        -- its place: the configuration's token types in the parser's order, each one's dictionaries in theirs; an order key
  CHECK (num_nonnulls(dictionary, dictionary_name) = 1),
  UNIQUE (design, id),
  FOREIGN KEY (design, configuration) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (design, dictionary) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX ts_config_mappings_configuration ON engine_postgresql.ts_config_mappings (design, configuration);
CREATE INDEX ts_config_mappings_dictionary ON engine_postgresql.ts_config_mappings (design, dictionary);

COMMENT ON TABLE engine_postgresql.ts_config_mappings IS 'which dictionaries a text search configuration consults for a token type, in order (ALTER TEXT SEARCH CONFIGURATION ... ADD MAPPING FOR token WITH d1, d2): a dictionary the design holds is a reference, a built-in its name.';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.id IS 'UUIDv7, made with the row';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.configuration IS 'the text search configuration';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.token IS 'the parser''s token type, by its alias (asciiword)';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.dictionary IS 'the dictionary; NULL when named instead';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.dictionary_name IS 'the dictionary by schema.name, a built-in (pg_catalog.simple); NULL when dictionary is set';
COMMENT ON COLUMN engine_postgresql.ts_config_mappings.position IS 'its place: the configuration''s token types in the parser''s order, each one''s dictionaries in theirs; an order key';
