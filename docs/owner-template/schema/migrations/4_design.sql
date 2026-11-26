-- 4_design: version 4 of example: every table of a design carries its design (decision database-per-schema). Owner: example.
-- Each table gains the column design, filled from the cortex row it belongs to in the same transaction, then made NOT
-- NULL; UNIQUE (design, id) is added, and every reference to a design's table becomes (design, column) to (design, id),
-- with its index, so no row can point into another design and a design's rows are read by its index alone.
ALTER TABLE engine_example.column_codecs ADD COLUMN design UUID REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
UPDATE engine_example.column_codecs x SET design = c.design FROM cortex.columns c WHERE c.id = x."column";
ALTER TABLE engine_example.column_codecs ALTER COLUMN design SET NOT NULL, ADD UNIQUE (design, id),
  DROP CONSTRAINT column_codecs_column_fkey,
  ADD FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE;
CREATE INDEX column_codecs_column ON engine_example.column_codecs (design, "column");
COMMENT ON COLUMN engine_example.column_codecs.design IS 'the design it belongs to';

ALTER TABLE engine_example.nested_fields ADD COLUMN design UUID REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
UPDATE engine_example.nested_fields x SET design = c.design FROM cortex.columns c WHERE c.id = x."column";
ALTER TABLE engine_example.nested_fields ALTER COLUMN design SET NOT NULL, ADD UNIQUE (design, id),
  DROP CONSTRAINT nested_fields_column_fkey, DROP CONSTRAINT nested_fields_parent_fkey,
  ADD FOREIGN KEY (design, "column") REFERENCES cortex.columns (design, id) ON DELETE CASCADE,
  ADD FOREIGN KEY (design, parent) REFERENCES engine_example.nested_fields (design, id) ON DELETE CASCADE;
CREATE INDEX nested_fields_column ON engine_example.nested_fields (design, "column");
CREATE INDEX nested_fields_parent ON engine_example.nested_fields (design, parent);
COMMENT ON COLUMN engine_example.nested_fields.design IS 'the design it belongs to';

ALTER TABLE engine_example.storage_pools ADD COLUMN design UUID REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
UPDATE engine_example.storage_pools x SET design = o.design FROM cortex.objects o WHERE o.id = x.id;
ALTER TABLE engine_example.storage_pools ALTER COLUMN design SET NOT NULL, ADD UNIQUE (design, id),
  DROP CONSTRAINT storage_pools_id_fkey,
  ADD FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE;
COMMENT ON COLUMN engine_example.storage_pools.design IS 'the design it belongs to';

ALTER TABLE engine_example.table_options ADD COLUMN design UUID REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;
UPDATE engine_example.table_options x SET design = o.design FROM cortex.objects o WHERE o.id = x.id;
ALTER TABLE engine_example.table_options ALTER COLUMN design SET NOT NULL, ADD UNIQUE (design, id),
  DROP CONSTRAINT table_options_id_fkey,
  ADD FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE;
COMMENT ON COLUMN engine_example.table_options.design IS 'the design it belongs to';
