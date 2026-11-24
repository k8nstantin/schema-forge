-- record-options-on-records: Record options belong to an object of the kind record. Owner: engine_quill.
-- The rows breaking it. cortex.enforce_rules('engine_quill') makes the database refuse any commit while it has one.
CREATE VIEW engine_quill.broken_record_options_on_records AS
SELECT 'record-options-on-records' AS rule, (r.id)::text AS id FROM engine_quill.record_options r JOIN cortex.objects o ON o.id = r.id WHERE o.kind <> 'record';

COMMENT ON VIEW engine_quill.broken_record_options_on_records IS 'Record options belong to an object of the kind record.';
