-- cortex.engine_flavors: the flavors of each engine a design may be made for: the engine itself, and each fork or managed service that is a subset of it (Percona Server, Cloud SQL, RDS, Aurora, AlloyDB), with what each refuses and the options it adds, declared by its plugin and checked by it.
CREATE TABLE cortex.engine_flavors (
  id       TEXT NOT NULL PRIMARY KEY,                                                         -- <engine>/<flavor>: mysql/aurora
  engine   TEXT NOT NULL REFERENCES cortex.engines (id) ON DELETE CASCADE,                    -- the engine it is a flavor of
  flavor   TEXT NOT NULL CHECK (flavor ~ '^[a-z][a-z0-9_]*$'),                                -- as the plugin names it; the engine's own is named as the engine (mysql)
  name     TEXT NOT NULL CHECK (length(name) >= 1),                                           -- as people say it (Amazon Aurora MySQL)
  refuses  JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(refuses) = 'object'),              -- what a design of it may not hold, by what the plugin checks: {"engines": ["MyISAM"], "kinds": ["resource_group"], "privileges": ["SUPER"]}
  options  JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(options) = 'object'),              -- the flavor_options keys it adds, by table, each with its JSON type: {"tables": {"compression_dictionary": "string"}}
  sources  JSONB NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(sources) = 'array'),               -- the documentation pages its facts come from
  UNIQUE (engine, flavor),
  CHECK (id = engine || '/' || flavor)
);
