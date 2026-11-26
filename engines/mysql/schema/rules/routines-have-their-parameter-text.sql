-- routines-have-their-parameter-text: Every routine has its parameter list as written. Owner: engine_mysql.
-- The rows breaking it. cortex.enforce_rules('engine_mysql') makes the database refuse any commit while it has one.
CREATE VIEW engine_mysql.broken_routines_have_their_parameter_text AS
SELECT 'routines-have-their-parameter-text' AS rule, (r.id)::text AS id FROM cortex.routines r WHERE NOT EXISTS (SELECT 1 FROM engine_mysql.routines m WHERE m.id = r.id);

COMMENT ON VIEW engine_mysql.broken_routines_have_their_parameter_text IS 'Every routine has its parameter list as written.';
