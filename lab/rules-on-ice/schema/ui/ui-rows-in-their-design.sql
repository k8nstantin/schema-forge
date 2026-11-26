-- ui-rows-in-their-design: What the tool keeps of a design ties together parts of that design only: an object's area, a perspective's members, a pin's perspective, a note's target. Owner: ui.
-- The rows breaking it. cortex.enforce_rules('ui') makes the database refuse any commit while it has one.
CREATE VIEW ui.broken_ui_rows_in_their_design AS
SELECT 'ui-rows-in-their-design' AS rule, (p.id)::text AS id FROM ui.object_places p JOIN ui.subject_areas a ON a.id = p.area
  WHERE a.design <> (SELECT n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.id = p.id)
UNION ALL
SELECT 'ui-rows-in-their-design', (m.id)::text FROM ui.perspective_members m JOIN ui.custom_perspectives c ON c.id = m.perspective
  WHERE c.design <> (SELECT n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.id = m.object)
UNION ALL
SELECT 'ui-rows-in-their-design', (l.id)::text FROM ui.layout_pins l JOIN ui.custom_perspectives c ON c.id = l.perspective
  WHERE c.design <> (SELECT n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.id = l.object)
UNION ALL
SELECT 'ui-rows-in-their-design', (pn.id)::text FROM ui.pinned_notes pn
  WHERE (pn.object IS NOT NULL AND pn.design <> (SELECT n.design FROM cortex.objects o JOIN cortex.namespaces n ON n.id = o.namespace WHERE o.id = pn.object))
     OR (pn.namespace IS NOT NULL AND pn.design <> (SELECT design FROM cortex.namespaces WHERE id = pn.namespace))
     OR (pn.area IS NOT NULL AND pn.design <> (SELECT design FROM ui.subject_areas WHERE id = pn.area))
     OR (pn.perspective IS NOT NULL AND pn.design <> (SELECT design FROM ui.custom_perspectives WHERE id = pn.perspective));

COMMENT ON VIEW ui.broken_ui_rows_in_their_design IS 'What the tool keeps of a design ties together parts of that design only: an object''s area, a perspective''s members, a pin''s perspective, a note''s target.';
