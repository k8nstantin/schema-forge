//! Every option MySQL holds beyond the shared section layout, declared as data: MySQL's own schema over the layout.
//! Values are kept as MySQL writes them, so a schema reads and writes back the same.

use schema_forge_engine::options::{OptionKind as K, OptionSpec as O, Part as P};

use crate::kinds::{
    EVENT, FUNCTION, LIBRARY, LOADABLE_FUNCTION, PROCEDURE, SPATIAL_REFERENCE_SYSTEM, TABLE, TABLESPACE, TRIGGER, VIEW,
};

const PROGRAMS: &[&str] = &[PROCEDURE, FUNCTION, TRIGGER, EVENT];
const ROUTINES: &[&str] = &[PROCEDURE, FUNCTION, LIBRARY];

pub const OPTIONS: &[O] = &[
    // A database.
    O::new(P::Namespace, "charset", K::Text, "Its default character set"),
    O::new(P::Namespace, "collation", K::Text, "Its default collation"),
    O::new(P::Namespace, "encryption", K::Flag, "Whether its tables are encrypted by default"),
    O::new(P::Namespace, "read_only", K::Flag, "Whether nothing in it may change"),
    // A table.
    O::new(P::Object, "engine", K::Text, "Its storage engine (InnoDB, MyISAM, …)").for_kinds(&[TABLE, TABLESPACE]),
    O::new(P::Object, "auto_increment", K::Integer, "The next number its AUTO_INCREMENT column gives")
        .for_kinds(&[TABLE]),
    O::new(P::Object, "autoextend_size", K::Text, "How much its file grows at a time").for_kinds(&[TABLE, TABLESPACE]),
    O::new(P::Object, "avg_row_length", K::Integer, "The row length it is sized for").for_kinds(&[TABLE]),
    O::new(P::Object, "charset", K::Text, "Its default character set").for_kinds(&[TABLE]),
    O::new(P::Object, "collation", K::Text, "Its default collation").for_kinds(&[TABLE]),
    O::new(P::Object, "checksum", K::Text, "Whether a live checksum of its rows is kept").for_kinds(&[TABLE]),
    O::new(P::Object, "compression", K::Text, "How its pages are compressed").for_kinds(&[TABLE]),
    O::new(P::Object, "connection", K::Text, "Where a FEDERATED table's rows are").for_kinds(&[TABLE]),
    O::new(P::Object, "data_directory", K::Text, "Where its data file is").for_kinds(&[TABLE]),
    O::new(P::Object, "index_directory", K::Text, "Where its index file is").for_kinds(&[TABLE]),
    O::new(P::Object, "delay_key_write", K::Text, "Whether index writes wait until it is closed").for_kinds(&[TABLE]),
    O::new(P::Object, "encryption", K::Text, "Whether it is encrypted").for_kinds(&[TABLE, TABLESPACE]),
    O::new(P::Object, "engine_attribute", K::Text, "What its storage engine is told about it")
        .for_kinds(&[TABLE, TABLESPACE]),
    O::new(P::Object, "secondary_engine", K::Text, "The secondary engine it is loaded into").for_kinds(&[TABLE]),
    O::new(P::Object, "secondary_engine_attribute", K::Text, "What its secondary engine is told about it")
        .for_kinds(&[TABLE]),
    O::new(P::Object, "insert_method", K::Text, "Where a MERGE table inserts").for_kinds(&[TABLE]),
    O::new(P::Object, "key_block_size", K::Integer, "The size of its compressed pages, in KB").for_kinds(&[TABLE]),
    O::new(P::Object, "max_rows", K::Integer, "The most rows it is sized for").for_kinds(&[TABLE]),
    O::new(P::Object, "min_rows", K::Integer, "The fewest rows it is sized for").for_kinds(&[TABLE]),
    O::new(P::Object, "pack_keys", K::Text, "Whether its indexes are packed").for_kinds(&[TABLE]),
    O::new(P::Object, "row_format", K::Text, "How its rows are stored (DYNAMIC, COMPACT, …)").for_kinds(&[TABLE]),
    O::new(P::Object, "stats_auto_recalc", K::Text, "Whether its statistics are recalculated on their own")
        .for_kinds(&[TABLE]),
    O::new(P::Object, "stats_persistent", K::Text, "Whether its statistics are kept on disk").for_kinds(&[TABLE]),
    O::new(P::Object, "stats_sample_pages", K::Text, "How many pages its statistics sample").for_kinds(&[TABLE]),
    O::new(P::Object, "tablespace", K::Text, "The tablespace it is stored in").for_kinds(&[TABLE]),
    O::new(P::Object, "union", K::Json, "The tables a MERGE table joins").for_kinds(&[TABLE]),
    O::new(P::Object, "outside_references", K::Json, "Its foreign keys to tables outside the schema, each as written")
        .for_kinds(&[TABLE]),
    // A view.
    O::new(P::Object, "algorithm", K::OneOf(&["UNDEFINED", "MERGE", "TEMPTABLE"]), "How its query is run")
        .for_kinds(&[VIEW]),
    O::new(
        P::Object,
        "check_option",
        K::OneOf(&["CASCADED", "LOCAL"]),
        "Whether rows written through it must match it",
    )
    .for_kinds(&[VIEW]),
    O::new(P::Object, "column_list", K::Json, "The names it gives its columns").for_kinds(&[VIEW]),
    // A view or a stored program.
    O::new(P::Object, "definer", K::Text, "The account whose rights it runs with")
        .for_kinds(&[VIEW, PROCEDURE, FUNCTION, TRIGGER, EVENT, LIBRARY]),
    O::new(P::Object, "security", K::OneOf(&["DEFINER", "INVOKER"]), "Whose rights it runs with").for_kinds(&[VIEW]),
    // What MySQL stores with each stored program, so its body means the same when written back.
    O::new(P::Object, "sql_mode", K::Text, "The SQL mode it was created under").for_kinds(PROGRAMS),
    O::new(P::Object, "character_set_client", K::Text, "The character set its text was written in")
        .for_kinds(&[VIEW, PROCEDURE, FUNCTION, TRIGGER, EVENT]),
    O::new(P::Object, "collation_connection", K::Text, "The collation it was created under")
        .for_kinds(&[VIEW, PROCEDURE, FUNCTION, TRIGGER, EVENT]),
    O::new(P::Object, "time_zone", K::Text, "The time zone its schedule is read in").for_kinds(&[EVENT]),
    // A trigger.
    O::new(P::Object, "follows", K::Text, "The trigger it runs after").for_kinds(&[TRIGGER]),
    O::new(P::Object, "precedes", K::Text, "The trigger it runs before").for_kinds(&[TRIGGER]),
    // An event.
    O::new(P::Object, "disabled_on_replica", K::Flag, "Whether it is disabled on replicas only").for_kinds(&[EVENT]),
    // A loadable function and a library.
    O::new(P::Object, "soname", K::Text, "The library file it is loaded from").for_kinds(&[LOADABLE_FUNCTION]),
    O::new(P::Object, "aggregate", K::Flag, "Whether it is an aggregate function").for_kinds(&[LOADABLE_FUNCTION]),
    O::new(P::Object, "returns", K::OneOf(&["STRING", "INTEGER", "REAL", "DECIMAL"]), "What it returns")
        .for_kinds(&[LOADABLE_FUNCTION]),
    // A tablespace and a spatial reference system.
    O::new(P::Object, "datafile", K::Text, "Its data file").for_kinds(&[TABLESPACE]),
    O::new(P::Object, "file_block_size", K::Text, "Its file's block size").for_kinds(&[TABLESPACE]),
    O::new(P::Object, "srid", K::Integer, "Its spatial reference system id").for_kinds(&[SPATIAL_REFERENCE_SYSTEM]),
    O::new(P::Object, "definition", K::Text, "Its definition, as well-known text")
        .for_kinds(&[SPATIAL_REFERENCE_SYSTEM]),
    O::new(P::Object, "organization", K::Text, "The organization that defined it")
        .for_kinds(&[SPATIAL_REFERENCE_SYSTEM]),
    O::new(P::Object, "organization_srid", K::Integer, "Its id at that organization")
        .for_kinds(&[SPATIAL_REFERENCE_SYSTEM]),
    // A routine.
    O::new(
        P::Routine,
        "data_access",
        K::OneOf(&["CONTAINS SQL", "NO SQL", "READS SQL DATA", "MODIFIES SQL DATA"]),
        "What it does with data",
    )
    .for_kinds(ROUTINES),
    O::new(P::Routine, "imports", K::Json, "The libraries it uses").for_kinds(&[PROCEDURE, FUNCTION, LIBRARY]),
    // A column.
    O::new(P::Column, "charset", K::Text, "Its character set"),
    O::new(P::Column, "collation", K::Text, "Its collation"),
    O::new(P::Column, "binary", K::Flag, "Whether it uses its character set's binary collation (BINARY, deprecated)"),
    O::new(P::Column, "on_update", K::Text, "What it becomes whenever its row changes"),
    O::new(P::Column, "srid", K::Integer, "The spatial reference system of its shapes"),
    O::new(P::Column, "invisible", K::Flag, "Whether SELECT * leaves it out"),
    O::new(P::Column, "column_format", K::OneOf(&["FIXED", "DYNAMIC", "DEFAULT"]), "How it is stored (NDB)"),
    O::new(P::Column, "storage", K::OneOf(&["DISK", "MEMORY"]), "Where it is stored (NDB)"),
    O::new(P::Column, "engine_attribute", K::Text, "What its storage engine is told about it"),
    O::new(P::Column, "secondary_engine_attribute", K::Text, "What its secondary engine is told about it"),
    // A key and an index.
    O::new(P::Key, "method", K::OneOf(&["BTREE", "HASH"]), "How it is built"),
    O::new(P::Key, "comment", K::Text, "What it is for"),
    O::new(P::Key, "key_block_size", K::Integer, "Its block size, in KB"),
    O::new(P::Key, "invisible", K::Flag, "Whether the optimizer ignores it"),
    O::new(P::Key, "engine_attribute", K::Text, "What its storage engine is told about it"),
    O::new(
        P::Key,
        "parts",
        K::Json,
        "How each column is indexed where it is not the whole column ascending: its prefix length, its order",
    ),
    O::new(P::Index, "comment", K::Text, "What it is for"),
    O::new(P::Index, "key_block_size", K::Integer, "Its block size, in KB"),
    O::new(P::Index, "parser", K::Text, "The full-text parser it uses (ngram, …)"),
    O::new(P::Index, "invisible", K::Flag, "Whether the optimizer ignores it"),
    O::new(P::Index, "engine_attribute", K::Text, "What its storage engine is told about it"),
    O::new(P::IndexPart, "length", K::Integer, "How many characters or bytes of the column it indexes"),
    O::new(P::Check, "not_enforced", K::Flag, "Whether it is declared but not checked"),
    // A link.
    O::new(P::Link, "inline", K::Flag, "Whether it is written on its column (REFERENCES) instead of as a constraint"),
    // Partitioning.
    O::new(P::Partitioning, "linear", K::Flag, "Whether its HASH or KEY is linear"),
    O::new(P::Partitioning, "algorithm", K::Integer, "The KEY hashing algorithm (1 or 2)"),
    O::new(P::Partitioning, "count", K::Integer, "How many partitions, when they are not named"),
    O::new(P::Partitioning, "columns", K::Flag, "Whether it is RANGE or LIST COLUMNS"),
    O::new(P::Partitioning, "subpartition", K::Json, "How each partition is split again: strategy, by, linear, count"),
    O::new(P::Partition, "engine", K::Text, "Its storage engine"),
    O::new(P::Partition, "comment", K::Text, "What it holds"),
    O::new(P::Partition, "data_directory", K::Text, "Where its data file is"),
    O::new(P::Partition, "index_directory", K::Text, "Where its index file is"),
    O::new(P::Partition, "max_rows", K::Integer, "The most rows it is sized for"),
    O::new(P::Partition, "min_rows", K::Integer, "The fewest rows it is sized for"),
    O::new(P::Partition, "tablespace", K::Text, "The tablespace it is stored in"),
    O::new(P::Partition, "subpartitions", K::Json, "Its subpartitions, by name, with their options"),
];
