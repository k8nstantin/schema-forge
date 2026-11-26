-- perspective-columns-of-their-object: A column a perspective shows alone is a column of the object it shows. Owner: ui.
-- The rows breaking it. cortex.enforce_rules('ui') makes the database refuse any commit while it has one.
CREATE VIEW ui.broken_perspective_columns_of_their_object AS
SELECT 'perspective-columns-of-their-object' AS rule, (m.id)::text AS id FROM ui.perspective_members m JOIN cortex.columns c ON c.id = m."column" WHERE c.object <> m.object;

COMMENT ON VIEW ui.broken_perspective_columns_of_their_object IS 'A column a perspective shows alone is a column of the object it shows.';
