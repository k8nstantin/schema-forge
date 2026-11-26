-- cortex.views: a view's query, as the server writes it, and what it guarantees of rows written through it. Owner: cortex.
CREATE TABLE cortex.views (
  id            UUID NOT NULL PRIMARY KEY,                                                                     -- the view
  design        UUID NOT NULL REFERENCES cortex.designs (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the design it belongs to
  query         TEXT NOT NULL CHECK (length(query) >= 1),                                                      -- the query, as the server writes it
  check_option  TEXT CHECK (check_option IN ('local', 'cascaded')),                                            -- whether rows written through it must match it; NULL for none
  options       JSONB NOT NULL DEFAULT '{}',                                                                   -- what the design's engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}
  UNIQUE (design, id),
  FOREIGN KEY (design, id) REFERENCES cortex.objects (design, id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED
);

COMMENT ON TABLE cortex.views IS 'a view''s query, as the server writes it, and what it guarantees of rows written through it.';
COMMENT ON COLUMN cortex.views.id IS 'the view';
COMMENT ON COLUMN cortex.views.design IS 'the design it belongs to';
COMMENT ON COLUMN cortex.views.query IS 'the query, as the server writes it';
COMMENT ON COLUMN cortex.views.check_option IS 'whether rows written through it must match it; NULL for none';
COMMENT ON COLUMN cortex.views.options IS 'what the design''s engine adds to it, each key an option the engine declares for this part (cortex.option_declarations), checked as the row is written: {"row_format": "DYNAMIC"}';
