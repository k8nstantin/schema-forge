-- Version 6: the guard of references (decision reference-kinds) on every table of the owner that holds a design's rows,
-- as loading the table files puts it there. The guard reads what the engine's seeds declare in cortex.reference_kinds.
SELECT cortex.guard_references('engine_example');
