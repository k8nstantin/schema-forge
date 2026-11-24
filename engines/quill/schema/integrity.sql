-- integrity: what Quill's tables require that a foreign key cannot say. Owner: quill.

-- name: record-options-on-records
-- Record options belong to an object of the kind record.
SELECT 'record-options-on-records', r.id FROM quill__record_options r JOIN objects o ON o.id = r.id WHERE o.kind <> 'record';
