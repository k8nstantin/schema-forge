-- engine_mysql.views: what MySQL says of a view beyond its query. Owner: mysql.
CREATE TABLE engine_mysql.views (
  id         BIGINT NOT NULL PRIMARY KEY,                                                                   -- the view
  design     UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  algorithm  TEXT NOT NULL DEFAULT 'UNDEFINED' CHECK (algorithm IN ('UNDEFINED', 'MERGE', 'TEMPTABLE')),    -- how its query is run: SHOW CREATE VIEW alone holds it
  security   TEXT NOT NULL DEFAULT 'DEFINER' CHECK (security IN ('DEFINER', 'INVOKER')),                    -- whose rights it runs with
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.views (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE engine_mysql.views IS 'what MySQL says of a view beyond its query.';
COMMENT ON COLUMN engine_mysql.views.id IS 'the view';
COMMENT ON COLUMN engine_mysql.views.design IS 'the design it belongs to';
COMMENT ON COLUMN engine_mysql.views.algorithm IS 'how its query is run: SHOW CREATE VIEW alone holds it';
COMMENT ON COLUMN engine_mysql.views.security IS 'whose rights it runs with';
