"""The lab's extractor: every property each catalog gives of every part of a schema, under its own names, nothing
interpreted. One snapshot per server: lab/out/<engine>-<version>.json, {engine, version, parts: [{kind, key, parent,
props}]}. Volatile properties (row counts, sizes, times, oids) are left out: they are usage, not design.

  python3 lab/extract.py [--mysql | --postgresql]      every server, or one engine's
"""
import base64
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PW = next(l.split('"')[1] for l in open(os.path.join(ROOT, "engines/mysql/tests/live.rs")) if l.startswith("const ROOT"))
MYSQL = [("5.7", "sf-mysql-5.7"), ("8.0", "sf-mysql-8.0"), ("8.4", "sf-mysql-8.4"), ("9.7", "sf-mysql-9.7")]
POSTGRES = [(v, f"sf-pg-{v}") for v in ("15", "16", "17", "18")]
SOURCE_DB = "engine_postgresql"  # where a PostgreSQL target's schemas are read from: never postgres, the server's own
SCHEMAS = tuple(os.environ.get("LAB_SCHEMAS", "shop,features,features_js,audit").split(","))  # the schemas a run reads
OUT = os.path.expanduser(os.environ.get("LAB_OUT", os.path.join(HERE, "out")))  # private schemas go outside the repository

# MySQL: information_schema tables by the part they describe, the columns that name the part, and the volatile ones.
MY_TABLES = [
    ("namespace", "SCHEMATA", "SCHEMA_NAME IN ({s})", ["SCHEMA_NAME"], None, []),
    ("table", "TABLES", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME"], ["TABLE_SCHEMA"],
     ["TABLE_ROWS", "AVG_ROW_LENGTH", "DATA_LENGTH", "MAX_DATA_LENGTH", "INDEX_LENGTH", "DATA_FREE", "CREATE_TIME",
      "UPDATE_TIME", "CHECK_TIME", "CHECKSUM", "AUTO_INCREMENT"]),
    ("column", "COLUMNS", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME", "COLUMN_NAME"], ["TABLE_SCHEMA", "TABLE_NAME"], []),
    ("index_part", "STATISTICS", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME", "INDEX_NAME", "SEQ_IN_INDEX"],
     ["TABLE_SCHEMA", "TABLE_NAME", "INDEX_NAME"], ["CARDINALITY"]),
    ("constraint", "TABLE_CONSTRAINTS", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME", "CONSTRAINT_NAME", "CONSTRAINT_TYPE"],
     ["TABLE_SCHEMA", "TABLE_NAME"], []),
    ("key_column", "KEY_COLUMN_USAGE", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME", "CONSTRAINT_NAME", "ORDINAL_POSITION"],
     ["TABLE_SCHEMA", "TABLE_NAME", "CONSTRAINT_NAME"], []),
    ("foreign_key", "REFERENTIAL_CONSTRAINTS", "CONSTRAINT_SCHEMA IN ({s})", ["CONSTRAINT_SCHEMA", "TABLE_NAME", "CONSTRAINT_NAME"],
     ["CONSTRAINT_SCHEMA", "TABLE_NAME"], []),
    ("check", "CHECK_CONSTRAINTS", "CONSTRAINT_SCHEMA IN ({s})", ["CONSTRAINT_SCHEMA", "CONSTRAINT_NAME"], ["CONSTRAINT_SCHEMA"], []),
    ("view", "VIEWS", "TABLE_SCHEMA IN ({s})", ["TABLE_SCHEMA", "TABLE_NAME"], ["TABLE_SCHEMA"], []),
    ("routine", "ROUTINES", "ROUTINE_SCHEMA IN ({s})", ["ROUTINE_SCHEMA", "ROUTINE_NAME", "ROUTINE_TYPE"], ["ROUTINE_SCHEMA"],
     ["CREATED", "LAST_ALTERED"]),
    ("parameter", "PARAMETERS", "SPECIFIC_SCHEMA IN ({s})", ["SPECIFIC_SCHEMA", "SPECIFIC_NAME", "ROUTINE_TYPE", "ORDINAL_POSITION"],
     ["SPECIFIC_SCHEMA", "SPECIFIC_NAME"], []),
    # MySQL 9.7's libraries, and which a routine uses; the order and the alias of each are in SHOW CREATE alone
    ("library", "LIBRARIES", "LIBRARY_SCHEMA IN ({s})", ["LIBRARY_SCHEMA", "LIBRARY_NAME"], ["LIBRARY_SCHEMA"],
     ["CREATED", "LAST_ALTERED", "CREATOR"]),  # CREATOR: the account that ran CREATE LIBRARY, which no statement writes
    ("routine_library", "ROUTINE_LIBRARIES", "ROUTINE_SCHEMA IN ({s})",
     ["ROUTINE_SCHEMA", "ROUTINE_NAME", "ROUTINE_TYPE", "LIBRARY_SCHEMA", "LIBRARY_NAME"], ["ROUTINE_SCHEMA", "ROUTINE_NAME"], []),
    ("trigger", "TRIGGERS", "TRIGGER_SCHEMA IN ({s})", ["TRIGGER_SCHEMA", "TRIGGER_NAME"], ["EVENT_OBJECT_SCHEMA", "EVENT_OBJECT_TABLE"],
     ["CREATED"]),
    ("event", "EVENTS", "EVENT_SCHEMA IN ({s})", ["EVENT_SCHEMA", "EVENT_NAME"], ["EVENT_SCHEMA"],
     ["CREATED", "LAST_ALTERED", "LAST_EXECUTED", "ORIGINATOR"]),  # ORIGINATOR: the server id it was made on
    ("partition", "PARTITIONS", "TABLE_SCHEMA IN ({s}) AND PARTITION_NAME IS NOT NULL",
     ["TABLE_SCHEMA", "TABLE_NAME", "PARTITION_NAME", "SUBPARTITION_NAME"], ["TABLE_SCHEMA", "TABLE_NAME"],
     ["TABLE_ROWS", "AVG_ROW_LENGTH", "DATA_LENGTH", "MAX_DATA_LENGTH", "INDEX_LENGTH", "DATA_FREE", "CREATE_TIME",
      "UPDATE_TIME", "CHECK_TIME", "CHECKSUM"]),
]


def unescape(field):
    """A field as mysql -B writes it without --raw: newline, tab, backslash and NUL escaped, so one row is one line."""
    out, i = [], 0
    while i < len(field):
        c = field[i]
        if c == "\\" and i + 1 < len(field):
            out.append({"n": "\n", "t": "\t", "0": "\0", "\\": "\\"}.get(field[i + 1], field[i + 1]))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def unbinary(v):
    """8.0 and later: JSON_OBJECT writes a value it holds as binary as base64:type<n>:<base64> (an event's interval
    of '5' came out as base64:type15:NQ==); the text is what the server holds."""
    if isinstance(v, str) and v.startswith("base64:type"):
        try:
            return base64.b64decode(v.split(":", 2)[2]).decode()
        except (ValueError, UnicodeDecodeError):
            return v
    return v


def mysql(container, sql, force=False):
    # every version sends its results in utf8mb4, so text from 5.7 and 9.7 compares; bytes it cannot decode are kept
    args = ["docker", "exec", "-i", container, "mysql", "-uroot", f"-p{PW}", "-B", "-N", "--default-character-set=utf8mb4"]
    r = subprocess.run(args + (["--force"] if force else []), input=sql.encode(), capture_output=True)
    if r.returncode and not force:
        raise SystemExit(f"{container}: {r.stderr.decode(errors='replace').strip()[-300:]}")
    return [[unescape(f) for f in l.split("\t")] for l in r.stdout.decode(errors="surrogateescape").split("\n") if l]


KEY_LINE = re.compile(r"^  (PRIMARY KEY|(?:UNIQUE |FULLTEXT |SPATIAL )?KEY `((?:[^`]|``)*)`)")


def table_facts(props):
    """What a table's SHOW CREATE alone holds: the order of its indexes (information_schema sorts them by name), and a
    MERGE table's UNION and INSERT_METHOD."""
    text = props["__show_create"]
    order = []
    for line in text.split("\n"):
        m = KEY_LINE.match(line)
        if m:
            order.append("PRIMARY" if m.group(1) == "PRIMARY KEY" else m.group(2).replace("``", "`"))
    props["__index_order"] = order
    last = text[text.rfind("\n)"):]
    m = re.search(r" UNION=\((.*?)\)", last)
    if m:
        props["__merge_union"] = [n.strip().strip("`").replace("``", "`") for n in m.group(1).split(",")]
    m = re.search(r" AUTO_INCREMENT=(\d+)", last)  # TABLES.AUTO_INCREMENT is cached on 8.0 and later; this is not
    if m:
        props["__auto_increment"] = int(m.group(1))
    m = re.search(r"^\) /\*!50100 TABLESPACE `((?:[^`]|``)+)` \*/", last.lstrip("\n"))
    if m:
        props["__tablespace"] = m.group(1).replace("``", "`")
    m = re.search(r" INSERT_METHOD=(\w+)", last)
    if m:
        props["__insert_method"] = m.group(1)


def server_parts(container, have):
    """What the server holds beside its databases, whatever databases a run reads: general tablespaces, the loadable
    functions people registered (mysql.func; a component's own are not made by a statement), and the spatial reference
    systems people defined (8.0 and later: those outside the ranges MySQL reserves for its own)."""
    out = []
    spaces = "INNODB_TABLESPACES" if "INNODB_TABLESPACES" in have else "INNODB_SYS_TABLESPACES"
    cols = {c[0] for c in mysql(container, f"SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='information_schema' AND TABLE_NAME='{spaces}'")}
    extra = "".join(f",'{c}',t.{c}" for c in ("ENCRYPTION", "AUTOEXTEND_SIZE") if c in cols)
    # general tablespaces but mysql, 8.0's data dictionary: the server's own
    for (row,) in mysql(container, f"SELECT JSON_OBJECT('NAME',t.NAME,'FILE_NAME',f.FILE_NAME,'ENGINE',f.ENGINE,'ZIP_PAGE_SIZE',t.ZIP_PAGE_SIZE{extra}) "
                                   f"FROM information_schema.{spaces} t JOIN information_schema.FILES f ON f.TABLESPACE_NAME = t.NAME "
                                   f"WHERE t.SPACE_TYPE = 'General' AND t.NAME <> 'mysql'"):
        p = json.loads(row)
        out.append({"kind": "tablespace", "key": p["NAME"], "parent": None, "props": p})
    for (row,) in mysql(container, "SELECT JSON_OBJECT('NAME',name,'RET',ret,'DL',dl,'TYPE',type) FROM mysql.func"):
        p = json.loads(row)
        out.append({"kind": "loadable_function", "key": p["NAME"], "parent": None, "props": p})
    if "ST_SPATIAL_REFERENCE_SYSTEMS" in have:
        for (row,) in mysql(container, "SELECT JSON_OBJECT('SRS_NAME',SRS_NAME,'SRS_ID',SRS_ID,'ORGANIZATION',ORGANIZATION,"
                                       "'ORGANIZATION_COORDSYS_ID',ORGANIZATION_COORDSYS_ID,'DEFINITION',DEFINITION,'DESCRIPTION',DESCRIPTION) "
                                       "FROM information_schema.ST_SPATIAL_REFERENCE_SYSTEMS WHERE SRS_ID BETWEEN 32768 AND 59999999 "
                                       "OR SRS_ID BETWEEN 70000000 AND 1999999999"):
            p = json.loads(row)
            out.append({"kind": "spatial_reference_system", "key": str(p["SRS_ID"]), "parent": None, "props": p})
    return out


def extract_mysql(version, container):
    parts = []
    s = ",".join("'" + x.replace("'", "''") + "'" for x in SCHEMAS)
    have = {r[0] for r in mysql(container, "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='information_schema'")}
    for kind, table, where, key, parent, volatile in MY_TABLES:
        if table not in have:
            continue
        cols = [c[0] for c in mysql(container, f"SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA="
                                                f"'information_schema' AND TABLE_NAME='{table}' ORDER BY ORDINAL_POSITION")]
        obj = "JSON_OBJECT(" + ",".join(f"'{c}',`{c}`" for c in cols) + ")"
        for (row,) in mysql(container, f"SELECT {obj} FROM information_schema.{table} WHERE {where.format(s=s)}"):
            p = {k: unbinary(v) for k, v in json.loads(row).items()}
            if kind == "index_part" and p.get("EXPRESSION"):
                p["EXPRESSION"] = p["EXPRESSION"].replace("\\'", "'")  # STATISTICS escapes the quotes in an expression
            for v in volatile:
                p.pop(v, None)
            parts.append({"kind": kind, "key": ".".join(str(p.get(k)) for k in key),
                          "parent": ".".join(str(p.get(k)) for k in parent) if parent else None, "props": p})
    parts += server_parts(container, have)
    # the definition as the server writes it, beside the catalog: every SHOW CREATE in one session, each after a
    # marker, so a statement the server refuses leaves its part without one and moves nothing else
    wants = []
    for p in parts:
        pr = p["props"]
        if p["kind"] == "view" or (p["kind"] == "table" and pr.get("TABLE_TYPE") != "VIEW"):
            what, sch, name = ("VIEW" if p["kind"] == "view" else "TABLE"), pr["TABLE_SCHEMA"], pr["TABLE_NAME"]
        elif p["kind"] == "routine":
            what, sch, name = pr["ROUTINE_TYPE"], pr["ROUTINE_SCHEMA"], pr["ROUTINE_NAME"]
        elif p["kind"] == "trigger":
            what, sch, name = "TRIGGER", pr["TRIGGER_SCHEMA"], pr["TRIGGER_NAME"]
        elif p["kind"] == "event":
            what, sch, name = "EVENT", pr["EVENT_SCHEMA"], pr["EVENT_NAME"]
        elif p["kind"] == "library":
            what, sch, name = "LIBRARY", pr["LIBRARY_SCHEMA"], pr["LIBRARY_NAME"]
        else:
            continue
        q = lambda n: "`" + n.replace("`", "``") + "`"
        wants.append((p, f"SHOW CREATE {what} {q(sch)}.{q(name)}"))
    rows = mysql(container, "".join(f"SELECT '#{i}';\n{stmt};\n" for i, (_, stmt) in enumerate(wants)), force=True)
    at = None
    for r in rows:
        if len(r) == 1 and r[0].startswith("#") and r[0][1:].isdigit():
            at = int(r[0][1:])
            continue
        p = wants[at][0]
        cell = {"table": 1, "view": 1, "routine": 2, "trigger": 2, "event": 3, "library": 2}[p["kind"]]
        if len(r) > cell:
            p["props"]["__show_create"] = r[cell]
            if p["kind"] == "table":
                table_facts(p["props"])
        if p["kind"] in ("routine", "trigger", "event", "library") and len(r) > 1:
            # the sql_mode the program runs under, as SHOW CREATE gives it: 5.7's ROUTINES.SQL_MODE writes
            # ALLOW_INVALID_DATES as INVALID_DATES, which no server accepts back
            p["props"]["__sql_mode"] = r[1]
    return parts


def pg(container, sql):
    r = subprocess.run(["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", SOURCE_DB, "-At", "-v", "ON_ERROR_STOP=1"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{container}: {r.stderr.strip()[-400:]}")
    return r.stdout


# PostgreSQL: one query per part, each giving {key, parent, props} with every column of its catalog row that is not
# an oid or volatile, names resolved, and the server's own rendering of its definition.
PG_PARTS = {
    "namespace": """SELECT n.nspname AS key, NULL AS parent, to_jsonb(n) - 'oid' - 'nspowner' || jsonb_build_object(
        'owner', pg_get_userbyid(n.nspowner), 'acl', n.nspacl::text[], 'comment', obj_description(n.oid, 'pg_namespace')) AS props
      FROM pg_namespace n WHERE n.nspname = ANY(%(s)s)""",
    "relation": """SELECT n.nspname || '.' || c.relname AS key, n.nspname AS parent, to_jsonb(c)
        - 'oid' - 'relnamespace' - 'reltype' - 'reloftype' - 'relowner' - 'relfilenode' - 'reltablespace' - 'relpages'
        - 'reltuples' - 'relallvisible' - 'relallfrozen' - 'reltoastrelid' - 'relfrozenxid' - 'relminmxid' - 'relam'
        - 'relrewrite' - 'relpartbound' - 'relhasindex' - 'relhastriggers' - 'relhasrules' - 'relhassubclass' - 'relnatts' - 'relchecks'
        || jsonb_build_object('owner', pg_get_userbyid(c.relowner), 'am', am.amname, 'acl', c.relacl::text[],
        'comment', obj_description(c.oid, 'pg_class'), 'partition_key', pg_get_partkeydef(c.oid),
        'partition_bound', pg_get_expr(c.relpartbound, c.oid),
        'inherits', (SELECT array_agg(pn.nspname || '.' || p.relname ORDER BY i.inhseqno) FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent JOIN pg_namespace pn ON pn.oid = p.relnamespace WHERE i.inhrelid = c.oid),
        'view_definition', CASE WHEN c.relkind IN ('v','m') THEN pg_get_viewdef(c.oid) END,
        'uses', CASE WHEN c.relkind IN ('v','m') THEN (SELECT jsonb_agg(DISTINCT un.nspname || '.' || u.relname) FROM pg_rewrite rw
          JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid AND d.refclassid = 'pg_class'::regclass
          JOIN pg_class u ON u.oid = d.refobjid JOIN pg_namespace un ON un.oid = u.relnamespace
          WHERE rw.ev_class = c.oid AND u.oid <> c.oid) END) AS props
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_am am ON am.oid = c.relam
      WHERE n.nspname = ANY(%(s)s) AND c.relkind IN ('r','p','v','m','f','S')""",
    "column": """SELECT n.nspname || '.' || c.relname || '.' || a.attname AS key, n.nspname || '.' || c.relname AS parent,
        to_jsonb(a) - 'attrelid' - 'atttypid' - 'attcollation' - 'attlen' - 'attbyval' - 'attalign' - 'attcacheoff'
        - 'atthasdef' - 'atthasmissing' - 'attmissingval' - 'attstattarget' - 'attndims' - 'attacl' - 'attoptions'
        - 'attfdwoptions' - 'atttypmod' - 'attcompression'
        || jsonb_build_object('type', format_type(a.atttypid, a.atttypmod), 'default', pg_get_expr(d.adbin, d.adrelid),
        'collation', CASE WHEN a.attcollation <> t.typcollation THEN quote_ident(cn.nspname) || '.' || quote_ident(co.collname) END, 'comment', col_description(c.oid, a.attnum),
        'acl', a.attacl::text[], 'options', (SELECT array_agg(o) FROM unnest(a.attoptions) o WHERE NOT starts_with(o, 'pg_attver='))) AS props
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_type t ON t.oid = a.atttypid LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      LEFT JOIN pg_collation co ON co.oid = a.attcollation LEFT JOIN pg_namespace cn ON cn.oid = co.collnamespace
      WHERE n.nspname = ANY(%(s)s) AND a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f')""",
    "index": """SELECT n.nspname || '.' || ic.relname AS key, n.nspname || '.' || tc.relname AS parent,
        to_jsonb(i) - 'indexrelid' - 'indrelid' - 'indcollation' - 'indclass' - 'indexprs' - 'indpred' - 'indkey' - 'indoption'
        || jsonb_build_object('definition', pg_get_indexdef(i.indexrelid), 'am', am.amname, 'options', ic.reloptions,
        'predicate', pg_get_expr(i.indpred, i.indrelid), 'comment', obj_description(i.indexrelid, 'pg_class'),
        'constraint', (SELECT co.conname FROM pg_constraint co WHERE co.conindid = i.indexrelid AND co.conrelid = i.indrelid AND co.contype IN ('p','u','x')),
        'parent_index', (SELECT pn.nspname || '.' || pc.relname FROM pg_inherits h JOIN pg_class pc ON pc.oid = h.inhparent
          JOIN pg_namespace pn ON pn.oid = pc.relnamespace WHERE h.inhrelid = i.indexrelid),
        'parts', (SELECT jsonb_agg(jsonb_build_object('position', k, 'column', a.attname,
            'expression', CASE WHEN i.indkey[k - 1] = 0 THEN pg_get_indexdef(i.indexrelid, k, true) END,
            'key', k <= i.indnkeyatts, 'descending', (i.indoption[k - 1] & 1) = 1, 'nulls_first', (i.indoption[k - 1] & 2) = 2,
            'opclass', CASE WHEN k <= i.indnkeyatts AND oc.oid IS DISTINCT FROM (
                         -- the default the server would choose for the column's type: exact, binary-compatible, or polymorphic
                         SELECT d.oid FROM pg_opclass d, pg_type ct
                         WHERE ct.oid = coalesce(nullif(bt.typbasetype, 0), a.atttypid, (SELECT ex.prorettype FROM pg_proc ex WHERE false))
                           AND d.opcmethod = oc.opcmethod AND d.opcdefault
                           AND (d.opcintype = ct.oid
                                OR EXISTS (SELECT 1 FROM pg_cast cs WHERE cs.castsource = ct.oid AND cs.casttarget = d.opcintype AND cs.castmethod = 'b')
                                OR (d.opcintype = 'anyarray'::regtype AND ct.typcategory = 'A')
                                OR (d.opcintype = 'anyrange'::regtype AND ct.typtype = 'r')
                                OR (d.opcintype = 'anymultirange'::regtype AND ct.typtype = 'm')
                                OR (d.opcintype = 'anyenum'::regtype AND ct.typtype = 'e'))
                         ORDER BY d.opcintype = ct.oid DESC, (SELECT pt.typispreferred FROM pg_type pt WHERE pt.oid = d.opcintype) DESC LIMIT 1)
                       THEN CASE WHEN ocn.nspname IN ('pg_catalog', 'public') THEN quote_ident(oc.opcname) ELSE quote_ident(ocn.nspname) || '.' || quote_ident(oc.opcname) END END,
            'opclass_name', CASE WHEN k <= i.indnkeyatts THEN CASE WHEN ocn.nspname IN ('pg_catalog', 'public') THEN quote_ident(oc.opcname) ELSE quote_ident(ocn.nspname) || '.' || quote_ident(oc.opcname) END END,
            'opclass_oid', CASE WHEN k <= i.indnkeyatts THEN oc.oid END,
            'index_collation', (SELECT CASE WHEN cn.nspname IN ('pg_catalog', 'public') THEN quote_ident(co.collname) ELSE quote_ident(cn.nspname) || '.' || quote_ident(co.collname) END
                                FROM pg_collation co JOIN pg_namespace cn ON cn.oid = co.collnamespace WHERE co.oid = i.indcollation[k - 1]),
            'collation', CASE WHEN i.indcollation[k - 1] <> 0 AND i.indcollation[k - 1] <> coalesce(a.attcollation, 0)
                         THEN (SELECT CASE WHEN cn.nspname IN ('pg_catalog', 'public') THEN quote_ident(co.collname) ELSE quote_ident(cn.nspname) || '.' || quote_ident(co.collname) END
                               FROM pg_collation co JOIN pg_namespace cn ON cn.oid = co.collnamespace WHERE co.oid = i.indcollation[k - 1]) END)
          ORDER BY k)
          FROM generate_series(1, i.indnatts) k
          LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[k - 1] AND i.indkey[k - 1] <> 0
          LEFT JOIN pg_type bt ON bt.oid = a.atttypid
          LEFT JOIN pg_opclass oc ON oc.oid = i.indclass[k - 1] LEFT JOIN pg_namespace ocn ON ocn.oid = oc.opcnamespace)) AS props
      FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_class tc ON tc.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = tc.relnamespace JOIN pg_am am ON am.oid = ic.relam WHERE n.nspname = ANY(%(s)s)""",
    "constraint": """SELECT n.nspname || '.' || coalesce(rc.relname, ty.typname) || '.' || co.conname AS key,
        n.nspname || '.' || coalesce(rc.relname, ty.typname) AS parent,
        to_jsonb(co) - 'oid' - 'connamespace' - 'conrelid' - 'contypid' - 'conindid' - 'conparentid' - 'confrelid'
        - 'conkey' - 'confkey' - 'conpfeqop' - 'conppeqop' - 'conffeqop' - 'conexclop' - 'conbin' - 'confdelsetcols'
        || jsonb_build_object('definition', pg_get_constraintdef(co.oid), 'comment', obj_description(co.oid, 'pg_constraint'),
        'columns', (SELECT jsonb_agg(a.attname ORDER BY k.n) FROM unnest(co.conkey) WITH ORDINALITY k(attnum, n)
                    JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.attnum),
        'ref_table', (SELECT quote_ident(fn.nspname) || '.' || quote_ident(fc.relname) FROM pg_class fc JOIN pg_namespace fn ON fn.oid = fc.relnamespace WHERE fc.oid = co.confrelid),
        'delete_set_columns', (SELECT jsonb_agg(a.attname ORDER BY k.n) FROM unnest(co.confdelsetcols) WITH ORDINALITY k(attnum, n)
                               JOIN pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.attnum),
        'ref_columns', (SELECT jsonb_agg(a.attname ORDER BY k.n) FROM unnest(co.confkey) WITH ORDINALITY k(attnum, n)
                        JOIN pg_attribute a ON a.attrelid = co.confrelid AND a.attnum = k.attnum),
        'expression', CASE WHEN co.contype = 'c' THEN pg_get_expr(co.conbin, coalesce(nullif(co.conrelid, 0), 0)) END,
        'operators', (SELECT jsonb_agg(o.oprname ORDER BY k.n) FROM unnest(co.conexclop) WITH ORDINALITY k(op, n) JOIN pg_operator o ON o.oid = k.op),
        'index', (SELECT ic.relname FROM pg_class ic WHERE ic.oid = co.conindid)) AS props
      FROM pg_constraint co JOIN pg_namespace n ON n.oid = co.connamespace LEFT JOIN pg_class rc ON rc.oid = co.conrelid
      LEFT JOIN pg_type ty ON ty.oid = co.contypid WHERE n.nspname = ANY(%(s)s)""",
    "sequence": """SELECT n.nspname || '.' || c.relname AS key, n.nspname AS parent,
        to_jsonb(s) - 'seqrelid' - 'seqtypid' || jsonb_build_object('type', format_type(s.seqtypid, NULL),
        'owned_by', (SELECT tc.relname || '.' || a.attname FROM pg_depend d JOIN pg_class tc ON tc.oid = d.refobjid
          JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
          WHERE d.objid = c.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a','i') LIMIT 1),
        'identity', EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.classid = 'pg_class'::regclass AND d.deptype = 'i')) AS props
      FROM pg_sequence s JOIN pg_class c ON c.oid = s.seqrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY(%(s)s)""",
    "type": """SELECT n.nspname || '.' || t.typname AS key, n.nspname AS parent,
        jsonb_build_object('typtype', t.typtype, 'base', CASE WHEN t.typtype = 'd' THEN format_type(t.typbasetype, t.typtypmod) END,
        'notnull', t.typnotnull, 'default', t.typdefault, 'comment', obj_description(t.oid, 'pg_type'),
        'labels', (SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid),
        'fields', (SELECT jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod)) ORDER BY a.attnum)
                   FROM pg_attribute a WHERE a.attrelid = t.typrelid AND a.attnum > 0),
        'range_subtype', (SELECT format_type(r.rngsubtype, NULL) FROM pg_range r WHERE r.rngtypid = t.oid),
        'multirange', (SELECT format_type(r.rngmultitypid, NULL) FROM pg_range r WHERE r.rngtypid = t.oid),
        'collation', (SELECT quote_ident(cn.nspname) || '.' || quote_ident(co.collname) FROM pg_collation co JOIN pg_namespace cn ON cn.oid = co.collnamespace WHERE co.oid = t.typcollation AND t.typcollation <> (SELECT typcollation FROM pg_type WHERE oid = t.typbasetype)),
        'owner', pg_get_userbyid(t.typowner), 'acl', t.typacl::text[]) AS props
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = ANY(%(s)s) AND t.typtype IN ('e','c','d','r')
        AND (t.typtype <> 'c' OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')""",
    "routine": """SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS key, n.nspname AS parent,
        to_jsonb(p) - 'oid' - 'pronamespace' - 'proowner' - 'prolang' - 'prorettype' - 'proargtypes' - 'proallargtypes'
        - 'proargdefaults' - 'protrftypes' - 'prosupport' - 'prosqlbody' - 'provariadic'
        || jsonb_build_object('language', l.lanname, 'returns', pg_get_function_result(p.oid),
        'arguments', pg_get_function_arguments(p.oid), 'owner', pg_get_userbyid(p.proowner),
        'comment', obj_description(p.oid, 'pg_proc'), 'acl', p.proacl::text[],
        'create', CASE WHEN p.prokind <> 'a' THEN pg_get_functiondef(p.oid) END,
        'argument_types', (SELECT jsonb_agg(format_type(t, NULL) ORDER BY n) FROM unnest(coalesce(p.proallargtypes, p.proargtypes::oid[])) WITH ORDINALITY x(t, n)),
        'argument_defaults', pg_get_expr(p.proargdefaults, 0),
        'made_by', (SELECT CASE d.deptype WHEN 'e' THEN 'extension' ELSE 'type' END FROM pg_depend d
          WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype IN ('i','e') LIMIT 1)) AS props
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang WHERE n.nspname = ANY(%(s)s)""",
    "trigger": """SELECT n.nspname || '.' || c.relname || '.' || tg.tgname AS key, n.nspname || '.' || c.relname AS parent,
        to_jsonb(tg) - 'oid' - 'tgrelid' - 'tgparentid' - 'tgfoid' - 'tgconstrrelid' - 'tgconstrindid' - 'tgconstraint'
        - 'tgattr' - 'tgargs' - 'tgqual' || jsonb_build_object('definition', pg_get_triggerdef(tg.oid),
        'function', (SELECT quote_ident(fn.nspname) || '.' || quote_ident(f.proname) FROM pg_proc f JOIN pg_namespace fn ON fn.oid = f.pronamespace WHERE f.oid = tg.tgfoid),
        'arguments', CASE WHEN tg.tgnargs > 0 THEN (SELECT jsonb_agg(x) FROM unnest(string_to_array(rtrim(encode(tg.tgargs, 'escape'), '\\000'), '\\000')) x) END,
        'update_columns', (SELECT jsonb_agg(a.attname ORDER BY k.n) FROM unnest(tg.tgattr) WITH ORDINALITY k(attnum, n)
                           JOIN pg_attribute a ON a.attrelid = tg.tgrelid AND a.attnum = k.attnum),
        'condition', substring(pg_get_triggerdef(tg.oid) FROM ' WHEN \\((.*)\\) EXECUTE '),
        'constraint_trigger', tg.tgconstraint <> 0,
        'from_table', CASE WHEN tg.tgconstrrelid <> 0 THEN tg.tgconstrrelid::regclass::text END) AS props
      FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = ANY(%(s)s) AND NOT tg.tgisinternal""",
    "policy": """SELECT schemaname || '.' || tablename || '.' || policyname AS key, schemaname || '.' || tablename AS parent,
        to_jsonb(p) - 'schemaname' - 'tablename' AS props FROM pg_policies p WHERE schemaname = ANY(%(s)s)""",
    "rule": """SELECT schemaname || '.' || tablename || '.' || rulename AS key, schemaname || '.' || tablename AS parent,
        to_jsonb(r) - 'schemaname' - 'tablename' AS props FROM pg_rules r WHERE schemaname = ANY(%(s)s)""",
    "extension": """SELECT e.extname AS key, NULL AS parent, jsonb_build_object('version', e.extversion,
        'schema', n.nspname, 'relocatable', e.extrelocatable) AS props
      FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname <> 'plpgsql'""",
    "collation": """SELECT n.nspname || '.' || c.collname AS key, n.nspname AS parent, to_jsonb(c) - 'oid' - 'collnamespace'
        - 'collowner' - 'collversion' AS props FROM pg_collation c JOIN pg_namespace n ON n.oid = c.collnamespace
      WHERE n.nspname = ANY(%(s)s)""",
}


DEFAULT_OPCLASS = """SELECT d.oid FROM pg_opclass d, pg_opclass oc, pg_type ct WHERE oc.oid = {opc} AND ct.oid = {typ}
  AND d.opcmethod = oc.opcmethod AND d.opcdefault
  AND (d.opcintype = ct.oid OR EXISTS (SELECT 1 FROM pg_cast cs WHERE cs.castsource = ct.oid AND cs.casttarget = d.opcintype AND cs.castmethod = 'b')
       OR (d.opcintype = 'anyarray'::regtype AND ct.typcategory = 'A') OR (d.opcintype = 'anyrange'::regtype AND ct.typtype = 'r')
       OR (d.opcintype = 'anymultirange'::regtype AND ct.typtype = 'm') OR (d.opcintype = 'anyenum'::regtype AND ct.typtype = 'e'))
  ORDER BY d.opcintype = ct.oid DESC, (SELECT pt.typispreferred FROM pg_type pt WHERE pt.oid = d.opcintype) DESC LIMIT 1"""


def expression_parts(container, parts):
    """An index expression's operator class and collation are written only when they are not what the expression
    itself gives: its type's default class and its own collation. The server says both, over a row of nulls."""
    for p in parts:
        if p["kind"] != "index":
            continue
        table = p["parent"]
        for part in p["props"].get("parts") or []:
            if not part.get("expression") or part.get("opclass_oid") is None:
                continue
            rel = next(x for x in parts if x["kind"] == "relation" and x["key"] == table)
            qrel = '"' + rel["parent"].replace('"', '""') + '"."' + rel["props"]["relname"].replace('"', '""') + '"'
            e = part["expression"]
            row = pg(container, f"SELECT json_build_object('type', pg_typeof({e})::oid, 'collation', pg_collation_for({e})) "
                                f"FROM (SELECT (NULL::{qrel}).*) t;").strip()
            got = json.loads(row)
            default = pg(container, DEFAULT_OPCLASS.format(opc=part["opclass_oid"], typ=got["type"]) + ";").strip()
            part["opclass"] = None if default == str(part["opclass_oid"]) else part["opclass_name"]
            own = (got["collation"] or "").replace('"pg_catalog".', "").replace('"public".', "")
            part["collation"] = None if not part.get("index_collation") or part["index_collation"] == own or \
                (own and own.replace('"', '') == part["index_collation"].replace('"', '')) else part["index_collation"]


def extract_pg(version, container):
    parts = []
    s = "ARRAY[" + ",".join(f"'{x}'" for x in SCHEMAS) + "]"
    for kind, q in PG_PARTS.items():
        sql = f"SELECT coalesce(json_agg(json_build_object('key', key, 'parent', parent, 'props', props)), '[]') FROM ({q % {'s': s}}) x;"
        for r in json.loads(pg(container, sql)):
            props = {k: v for k, v in r["props"].items() if v is not None}
            parts.append({"kind": kind, "key": r["key"], "parent": r["parent"], "props": props})
    expression_parts(container, parts)
    for p in parts:
        for part in p["props"].get("parts") or [] if p["kind"] == "index" else []:
            for k in ("opclass_name", "opclass_oid", "index_collation"):
                part.pop(k, None)  # what the decision above needed; the server's oids differ between servers
    return parts


def main():
    os.makedirs(OUT, exist_ok=True)
    only = [e for e in ("mysql", "postgresql") if f"--{e}" in sys.argv]
    for engine, servers, fn in (("mysql", MYSQL, extract_mysql), ("postgresql", POSTGRES, extract_pg)):
        if only and engine not in only:
            continue
        for version, container in servers:
            parts = fn(version, container)
            out = {"engine": engine, "version": version, "parts": parts}
            path = os.path.join(OUT, f"{engine}-{version}.json")
            json.dump(out, open(path, "w"), indent=1, sort_keys=True, default=str)
            kinds = {}
            for p in parts:
                kinds[p["kind"]] = kinds.get(p["kind"], 0) + 1
            print(f"{engine} {version}: {len(parts)} parts  " + ", ".join(f"{k} {n}" for k, n in sorted(kinds.items())))


if __name__ == "__main__":
    main()
