-- cortex.layout_pins: a table's place pinned in one view of the canvas; everything not pinned is laid out afresh each time. Owner: cortex.
-- Part of the design (decision canvas-state). The view is the perspective and its focus as the canvas's address writes them.
CREATE TABLE cortex.layout_pins (
  id      TEXT    NOT NULL PRIMARY KEY CHECK (id ~ '^pin[1-9][0-9]*$'),         -- pin<n>, n given once from id_counters and never reused: pin1
  view    TEXT    NOT NULL CHECK (view ~ '^[a-z_]+(/[a-z0-9_.]+)?$'),           -- the view: a perspective and its focus (map, map/billing, table/o_orders) or a custom perspective's id (p_billing_review)
  object  TEXT    NOT NULL REFERENCES cortex.objects (id) ON DELETE CASCADE,    -- the table or view pinned
  x       NUMERIC NOT NULL,                                                     -- across, in the layout's grid units from its left
  y       NUMERIC NOT NULL,                                                     -- down, in the layout's grid units from its top
  UNIQUE (view, object)
);

COMMENT ON TABLE cortex.layout_pins IS 'a table''s place pinned in one view of the canvas; everything not pinned is laid out afresh each time. Part of the design (decision canvas-state). The view is the perspective and its focus as the canvas''s address writes them.';
COMMENT ON COLUMN cortex.layout_pins.id IS 'pin<n>, n given once from id_counters and never reused: pin1';
COMMENT ON COLUMN cortex.layout_pins.view IS 'the view: a perspective and its focus (map, map/billing, table/o_orders) or a custom perspective''s id (p_billing_review)';
COMMENT ON COLUMN cortex.layout_pins.object IS 'the table or view pinned';
COMMENT ON COLUMN cortex.layout_pins.x IS 'across, in the layout''s grid units from its left';
COMMENT ON COLUMN cortex.layout_pins.y IS 'down, in the layout''s grid units from its top';
