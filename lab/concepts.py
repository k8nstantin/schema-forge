"""The lab's concept map: what MySQL and PostgreSQL share, attribute by attribute, and what is each one's own.

Every part an extractor gives (lab/out/*.json) belongs to one concept; a concept's shared attributes are named once,
with the native property of each engine that holds them; every other property is that engine's own. The map is the
evidence the storage approaches are built and judged on.
"""

# engine part kind -> concept
CONCEPT_OF = {
    "mysql": {"namespace": "namespace", "table": "object", "view": "object", "routine": "object", "trigger": "object",
              "event": "object", "column": "column", "index_part": "index_part", "constraint": "constraint",
              "key_column": "constraint_column", "foreign_key": "foreign_key", "check": "check",
              "parameter": "parameter", "partition": "partition"},
    "postgresql": {"namespace": "namespace", "relation": "object", "routine": "object", "trigger": "object",
                   "sequence": "object", "type": "object", "policy": "object", "rule": "object",
                   "extension": "object", "collation": "object", "column": "column", "index": "index",
                   "constraint": "constraint"},
}

# concept -> shared attribute -> {engine: native property}. An attribute is shared only when both engines hold the same
# idea; its value is kept as each engine writes it (the engine reads and writes its own words).
SHARED = {
    "namespace": {"name": {"mysql": "SCHEMA_NAME", "postgresql": "nspname"}},
    "object": {
        "name": {"mysql": "TABLE_NAME|ROUTINE_NAME|TRIGGER_NAME|EVENT_NAME", "postgresql": "relname|proname|tgname|policyname|rulename|collname"},
        "comment": {"mysql": "TABLE_COMMENT|ROUTINE_COMMENT|EVENT_COMMENT", "postgresql": "comment"},
        "definition": {"mysql": "__show_create|VIEW_DEFINITION|ROUTINE_DEFINITION|ACTION_STATEMENT|EVENT_DEFINITION",
                       "postgresql": "view_definition|prosrc|definition"},
        "security": {"mysql": "SECURITY_TYPE", "postgresql": "prosecdef"},
        "check_option": {"mysql": "CHECK_OPTION", "postgresql": "reloptions"},
        "returns": {"mysql": "DTD_IDENTIFIER", "postgresql": "returns"},
        "timing": {"mysql": "ACTION_TIMING", "postgresql": "tgtype"},
    },
    "column": {
        "name": {"mysql": "COLUMN_NAME", "postgresql": "attname"},
        "position": {"mysql": "ORDINAL_POSITION", "postgresql": "attnum"},
        "type": {"mysql": "COLUMN_TYPE", "postgresql": "type"},
        "nullable": {"mysql": "IS_NULLABLE", "postgresql": "attnotnull"},
        "default": {"mysql": "COLUMN_DEFAULT", "postgresql": "default"},
        "comment": {"mysql": "COLUMN_COMMENT", "postgresql": "comment"},
        "collation": {"mysql": "COLLATION_NAME", "postgresql": "collation"},
        "generated": {"mysql": "GENERATION_EXPRESSION", "postgresql": "attgenerated"},
        "identity": {"mysql": "EXTRA", "postgresql": "attidentity"},
    },
    "index": {"name": {"mysql": "INDEX_NAME", "postgresql": "definition"}, "unique": {"mysql": "NON_UNIQUE", "postgresql": "indisunique"},
              "method": {"mysql": "INDEX_TYPE", "postgresql": "am"}},
    "index_part": {"name": {"mysql": "INDEX_NAME", "postgresql": None}, "unique": {"mysql": "NON_UNIQUE", "postgresql": None},
                   "method": {"mysql": "INDEX_TYPE", "postgresql": None}, "column": {"mysql": "COLUMN_NAME", "postgresql": None},
                   "expression": {"mysql": "EXPRESSION", "postgresql": None}, "position": {"mysql": "SEQ_IN_INDEX", "postgresql": None},
                   "direction": {"mysql": "COLLATION", "postgresql": None}, "comment": {"mysql": "INDEX_COMMENT", "postgresql": None}},
    "constraint": {"name": {"mysql": "CONSTRAINT_NAME", "postgresql": "conname"},
                   "type": {"mysql": "CONSTRAINT_TYPE", "postgresql": "contype"},
                   "enforced": {"mysql": "ENFORCED", "postgresql": "conenforced"},
                   "definition": {"mysql": None, "postgresql": "definition"},
                   "on_delete": {"mysql": None, "postgresql": "confdeltype"}, "on_update": {"mysql": None, "postgresql": "confupdtype"},
                   "match": {"mysql": None, "postgresql": "confmatchtype"}},
    "foreign_key": {"name": {"mysql": "CONSTRAINT_NAME", "postgresql": None}, "on_delete": {"mysql": "DELETE_RULE", "postgresql": None},
                    "on_update": {"mysql": "UPDATE_RULE", "postgresql": None}, "match": {"mysql": "MATCH_OPTION", "postgresql": None}},
    "check": {"name": {"mysql": "CONSTRAINT_NAME", "postgresql": None}, "definition": {"mysql": "CHECK_CLAUSE", "postgresql": None}},
    "constraint_column": {"column": {"mysql": "COLUMN_NAME", "postgresql": None}, "position": {"mysql": "ORDINAL_POSITION", "postgresql": None}},
    "parameter": {"name": {"mysql": "PARAMETER_NAME", "postgresql": None}, "type": {"mysql": "DTD_IDENTIFIER", "postgresql": None},
                  "mode": {"mysql": "PARAMETER_MODE", "postgresql": None}, "position": {"mysql": "ORDINAL_POSITION", "postgresql": None}},
    "partition": {"name": {"mysql": "PARTITION_NAME", "postgresql": None}, "method": {"mysql": "PARTITION_METHOD", "postgresql": None},
                  "bounds": {"mysql": "PARTITION_DESCRIPTION", "postgresql": None}},
}

# What names a part, never a property of it: catalog and schema columns the key and parent already carry.
STRUCTURAL = {"TABLE_CATALOG", "TABLE_SCHEMA", "CONSTRAINT_CATALOG", "CONSTRAINT_SCHEMA", "ROUTINE_CATALOG", "ROUTINE_SCHEMA",
              "TRIGGER_CATALOG", "TRIGGER_SCHEMA", "EVENT_CATALOG", "EVENT_SCHEMA", "SPECIFIC_CATALOG", "SPECIFIC_SCHEMA",
              "SPECIFIC_NAME", "INDEX_SCHEMA", "CATALOG_NAME", "EVENT_OBJECT_CATALOG", "EVENT_OBJECT_SCHEMA",
              "EVENT_OBJECT_TABLE", "UNIQUE_CONSTRAINT_CATALOG", "UNIQUE_CONSTRAINT_SCHEMA", "TABLE_NAME", "SCHEMA_NAME",
              "REFERENCED_TABLE_SCHEMA", "attisdropped", "nspacl", "relacl"}


def split(engine, concept, props):
    """A part's properties as (shared {attribute: value}, own {native: value}): the shared attributes by the map, the
    rest the engine's own; what only names the part is dropped."""
    shared, own = {}, {}
    used = set()
    for attr, by in SHARED.get(concept, {}).items():
        native = by.get(engine)
        if not native:
            continue
        for n in native.split("|"):
            if n in props:
                shared[attr] = props[n]
                used.add(n)
                break
    for k, v in props.items():
        if k not in used and k not in STRUCTURAL:
            own[k] = v
    return shared, own
