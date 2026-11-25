-- cortex.views: a view's query, as the server writes it, and what it guarantees of rows written through it. Owner: cortex.
CREATE TABLE cortex.views (
  id            BIGINT NOT NULL PRIMARY KEY REFERENCES cortex.objects (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,  -- the view
  query         TEXT NOT NULL CHECK (length(query) >= 1),                                                                    -- the query, as the server writes it
  check_option  TEXT CHECK (check_option IN ('local', 'cascaded'))                                                           -- whether rows written through it must match it; NULL for none
);

COMMENT ON TABLE cortex.views IS 'a view''s query, as the server writes it, and what it guarantees of rows written through it.';
COMMENT ON COLUMN cortex.views.id IS 'the view';
COMMENT ON COLUMN cortex.views.query IS 'the query, as the server writes it';
COMMENT ON COLUMN cortex.views.check_option IS 'whether rows written through it must match it; NULL for none';
