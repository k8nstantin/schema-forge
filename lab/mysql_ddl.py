"""MySQL CREATE TABLE generated from a table's structured parts (columns, indexes, keys, checks, partitions, options),
compared with the server's SHOW CREATE TABLE. Tells which facts the store must hold to write a table without
keeping its text.

  python3 lab/mysql_ddl.py <snapshot.json> [...]      lab/out/mysql-*.json or a private snapshot
"""
import json
import re
import sys
from collections import Counter, defaultdict


def q(n):
    return "`" + n.replace("`", "``") + "`"


def text_lit(s):
    """A string as SHOW CREATE writes it: quote doubled, backslash and control characters escaped."""
    out = s.replace("\\", "\\\\").replace("'", "''").replace("\n", "\\n").replace("\r", "\\r").replace("\0", "\\0").replace("\x1a", "\\Z")
    return "'" + out + "'"


def mysql8(version):
    return not version.startswith("5.")


NO_DEFAULT_NULL = ("text", "tinytext", "mediumtext", "longtext", "blob", "tinyblob", "mediumblob", "longblob",
                   "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
                   "geometrycollection", "geomcollection")


def column(c, table_cs, table_coll, version, charset_default):
    t = c["COLUMN_TYPE"]
    out = f"  {q(c['COLUMN_NAME'])} {t}"
    cs, coll = c.get("CHARACTER_SET_NAME"), c.get("COLLATION_NAME")
    extra = c.get("EXTRA") or ""
    if cs:
        if coll != table_coll:
            out += f" CHARACTER SET {cs}"
            if coll != charset_default.get(cs) or (mysql8(version) and cs != table_cs):
                out += f" COLLATE {coll}"
        elif coll != charset_default.get(cs):
            out += f" COLLATE {coll}"
    gen = c.get("GENERATION_EXPRESSION")
    if gen:
        kind = "STORED" if "STORED" in extra else "VIRTUAL"
        out += f" GENERATED ALWAYS AS ({gen}) {kind}"
    nullable = c["IS_NULLABLE"] == "YES"
    if not nullable:
        out += " NOT NULL"
    elif c["DATA_TYPE"] == "timestamp" and not gen:
        out += " NULL"
    if c.get("SRS_ID") is not None:
        out += f" /*!80003 SRID {c['SRS_ID']} */"
    d = c.get("COLUMN_DEFAULT")
    if not gen:
        if "DEFAULT_GENERATED" in extra and d is not None:
            if re.fullmatch(r"CURRENT_TIMESTAMP(\(\d\))?", d):
                out += f" DEFAULT {d}"
            else:
                out += f" DEFAULT ({d})"
        elif d is not None:
            if c["DATA_TYPE"] == "bit":
                out += f" DEFAULT {d}"
            elif not mysql8(version) and re.fullmatch(r"CURRENT_TIMESTAMP(\(\d\))?", d):
                out += f" DEFAULT {d}"
            else:
                out += f" DEFAULT {text_lit(d)}"
        elif nullable and c["DATA_TYPE"] not in NO_DEFAULT_NULL and "auto_increment" not in extra:
            out += " DEFAULT NULL"
    m = re.search(r"on update (CURRENT_TIMESTAMP(\(\d\))?)", extra, re.I)
    if m:
        out += f" ON UPDATE {m.group(1)}"
    if "auto_increment" in extra:
        out += " AUTO_INCREMENT"
    if c.get("COLUMN_COMMENT"):
        out += f" COMMENT {text_lit(c['COLUMN_COMMENT'])}"
    if "INVISIBLE" in extra:
        out += " /*!80023 INVISIBLE */"
    return out


def index(name, rows, version):
    first = rows[0]
    parts = []
    for r in sorted(rows, key=lambda r: int(r["SEQ_IN_INDEX"])):
        sub = r.get("SUB_PART") if first["INDEX_TYPE"] != "SPATIAL" else None  # a spatial key reports a length it never takes
        p = f"({r['EXPRESSION']})" if r.get("EXPRESSION") else q(r["COLUMN_NAME"]) + (f"({sub})" if sub else "")
        if r.get("COLLATION") == "D":
            p += " DESC"
        parts.append(p)
    if name == "PRIMARY":
        head = "PRIMARY KEY"
    elif first["INDEX_TYPE"] == "FULLTEXT":
        head = f"FULLTEXT KEY {q(name)}"
    elif first["INDEX_TYPE"] == "SPATIAL":
        head = f"SPATIAL KEY {q(name)}"
    elif str(first["NON_UNIQUE"]) == "0":
        head = f"UNIQUE KEY {q(name)}"
    else:
        head = f"KEY {q(name)}"
    out = f"  {head} ({','.join(parts)})"
    if first.get("__using"):
        out += f" USING {first['INDEX_TYPE']}"
    if first.get("INDEX_COMMENT"):
        out += f" COMMENT {text_lit(first['INDEX_COMMENT'])}"
    if first.get("IS_VISIBLE") == "NO":
        out += " /*!80000 INVISIBLE */"
    return out


ENGINE_NAMES = {"MRG_MYISAM": "MRG_MyISAM"}  # information_schema writes it upper case, SHOW CREATE as registered
OPTION_ORDER = ["min_rows", "max_rows", "pack_keys", "stats_persistent", "stats_auto_recalc", "stats_sample_pages",
                "avg_row_length", "checksum", "delay_key_write", "row_format", "key_block_size", "compression", "encryption"]


def table_options(t, version, charset_default):
    out = f") ENGINE={ENGINE_NAMES.get(t['ENGINE'], t['ENGINE'])}"
    if t.get("__auto_increment"):
        out += f" AUTO_INCREMENT={t['__auto_increment']}"
    cs = t["TABLE_COLLATION"].split("_")[0]
    out += f" DEFAULT CHARSET={cs}"
    if t["TABLE_COLLATION"] != charset_default.get(cs) or (mysql8(version) and cs == "utf8mb4"):
        out += f" COLLATE={t['TABLE_COLLATION']}"
    opts = dict(o.split("=", 1) if "=" in o else (o, None) for o in (t.get("CREATE_OPTIONS") or "").split())
    for k in OPTION_ORDER:
        if k in opts:
            out += f" {k.upper()}={opts[k]}"
    if t.get("TABLE_COMMENT"):
        out += f" COMMENT={text_lit(t['TABLE_COMMENT'])}"
    if t.get("__insert_method"):
        out += f" INSERT_METHOD={t['__insert_method']}"
    if t.get("__merge_union"):
        out += f" UNION=({','.join(q(n) for n in t['__merge_union'])})"
    return out


def partitions(rows, engine):
    """The PARTITION BY clause from information_schema.PARTITIONS rows."""
    if not rows:
        return ""
    rows = sorted(rows, key=lambda r: (int(r["PARTITION_ORDINAL_POSITION"]), int(r.get("SUBPARTITION_ORDINAL_POSITION") or 0)))
    first = rows[0]
    out = f"\n/*!50100 PARTITION BY {first['PARTITION_METHOD']} ({first['PARTITION_EXPRESSION']})"
    names = list(dict.fromkeys(r["PARTITION_NAME"] for r in rows))
    subs = [r for r in rows if r["PARTITION_NAME"] == names[0] and r.get("SUBPARTITION_NAME")]
    if first.get("SUBPARTITION_METHOD"):
        out += f"\nSUBPARTITION BY {first['SUBPARTITION_METHOD']} ({first['SUBPARTITION_EXPRESSION']})"
        if all(r["SUBPARTITION_NAME"] == f"{r['PARTITION_NAME']}sp{int(r['SUBPARTITION_ORDINAL_POSITION']) - 1}" for r in rows):
            out += f"\nSUBPARTITIONS {len(subs)}"
    if first["PARTITION_METHOD"] in ("HASH", "KEY", "LINEAR HASH", "LINEAR KEY") and names == [f"p{i}" for i in range(len(names))]:
        return out + f"\nPARTITIONS {len(names)} */"
    items = []
    for n in names:
        r = next(x for x in rows if x["PARTITION_NAME"] == n)
        d = r.get("PARTITION_DESCRIPTION")
        if r["PARTITION_METHOD"].startswith("RANGE"):
            v = " VALUES LESS THAN MAXVALUE" if d == "MAXVALUE" else f" VALUES LESS THAN ({d})"
        elif r["PARTITION_METHOD"].startswith("LIST"):
            v = f" VALUES IN ({d})"
        else:
            v = ""
        items.append(f"PARTITION {n}{v} ENGINE = {engine}")
    return out + "\n(" + ",\n ".join(items) + ") */"


def create_table(t, cols, idx, fks, checks, version, charset_default, parts=()):
    cs = t["TABLE_COLLATION"].split("_")[0]
    lines = [column(c, cs, t["TABLE_COLLATION"], version, charset_default)
             for c in sorted(cols, key=lambda c: int(c["ORDINAL_POSITION"]))]
    order = t.get("__index_order") or list(idx)
    for name in order:
        lines.append(index(name, idx[name], version))
    for fk in sorted(fks):  # SHOW CREATE writes foreign keys by name
        lines.append(fk)
    for ck in sorted(checks):  # and checks by name
        lines.append(ck)
    return (f"CREATE TABLE {q(t['TABLE_NAME'])} (\n" + ",\n".join(lines) + "\n" + table_options(t, version, charset_default)
            + partitions(parts, ENGINE_NAMES.get(t["ENGINE"], t["ENGINE"])))


def foreign_key(rc, kcu, own_schema, version):
    cols = sorted(kcu, key=lambda r: int(r["ORDINAL_POSITION"]))
    ref_schema = cols[0]["REFERENCED_TABLE_SCHEMA"]
    ref = (q(ref_schema) + "." if ref_schema != own_schema else "") + q(rc["REFERENCED_TABLE_NAME"])
    out = (f"  CONSTRAINT {q(rc['CONSTRAINT_NAME'])} FOREIGN KEY ({', '.join(q(c['COLUMN_NAME']) for c in cols)}) "
           f"REFERENCES {ref} ({', '.join(q(c['REFERENCED_COLUMN_NAME']) for c in cols)})")
    implied = "NO ACTION" if mysql8(version) else "RESTRICT"  # the rule a key has when none is written
    if rc["DELETE_RULE"] != implied:
        out += f" ON DELETE {rc['DELETE_RULE']}"
    if rc["UPDATE_RULE"] != implied:
        out += f" ON UPDATE {rc['UPDATE_RULE']}"
    return out


def tables_of(snap):
    """Every base table with its parts, from a snapshot: {key: (table, cols, idx, fks, checks)}."""
    by = defaultdict(lambda: defaultdict(list))
    for p in snap["parts"]:
        by[p["kind"]][p["parent"]].append(p["props"])
    key_columns, index_parts = defaultdict(list), defaultdict(list)  # their parent is the constraint or index
    for p in snap["parts"]:
        if p["kind"] in ("key_column", "index_part"):
            (key_columns if p["kind"] == "key_column" else index_parts)[f"{p['props']['TABLE_SCHEMA']}.{p['props']['TABLE_NAME']}"].append(p["props"])
    out = {}
    for p in snap["parts"]:
        t = p["props"]
        if p["kind"] != "table" or t.get("TABLE_TYPE") != "BASE TABLE":
            continue
        key = p["key"]
        idx = {}
        for r in index_parts[key]:
            idx.setdefault(r["INDEX_NAME"], []).append(r)
        kcu = defaultdict(list)
        for r in key_columns[key]:
            kcu[r["CONSTRAINT_NAME"]].append(r)
        fks = [foreign_key(rc, kcu[rc["CONSTRAINT_NAME"]], t["TABLE_SCHEMA"], snap["version"]) for rc in by["foreign_key"][f"{t['TABLE_SCHEMA']}.{t['TABLE_NAME']}"]]
        checks = []
        tc = {r["CONSTRAINT_NAME"]: r for r in by["constraint"][key] if r["CONSTRAINT_TYPE"] == "CHECK"}
        for r in by["check"][t["TABLE_SCHEMA"]]:
            if r["CONSTRAINT_NAME"] in tc:
                checks.append(f"  CONSTRAINT {q(r['CONSTRAINT_NAME'])} CHECK ({r['CHECK_CLAUSE']})"
                              + (" /*!80016 NOT ENFORCED */" if tc[r["CONSTRAINT_NAME"]].get("ENFORCED") == "NO" else ""))
        out[key] = (t, by["column"][key], idx, fks, checks, by["partition"][key])
    return out


def normal(s):
    """The server's text without what is state, not design: the AUTO_INCREMENT counter."""
    return re.sub(r" AUTO_INCREMENT=\d+", "", s)


def main():
    for path in sys.argv[1:]:
        snap = json.load(open(path))
        version = snap["version"]
        charset_default = {"latin1": "latin1_swedish_ci", "utf8": "utf8_general_ci", "utf8mb3": "utf8mb3_general_ci",
                           "utf8mb4": "utf8mb4_0900_ai_ci" if mysql8(version) else "utf8mb4_general_ci",
                           "ascii": "ascii_general_ci", "binary": "binary", "ucs2": "ucs2_general_ci", "utf16": "utf16_general_ci"}
        exact, why, first = 0, Counter(), {}
        tables = tables_of(snap)
        for key, (t, cols, idx, fks, checks, parts) in tables.items():
            want = normal(t.get("__show_create", ""))
            got = create_table(t, cols, idx, fks, checks, version, charset_default, parts)
            if got == want:
                exact += 1
                continue
            wl, gl = want.split("\n"), got.split("\n")
            if len(wl) != len(gl):
                why["line count"] += 1
                first.setdefault("line count", (key, want, got))
                continue
            for a, b in zip(wl, gl):
                if a != b:
                    kind = "option line" if a.startswith(")") else ("key line" if re.match(r"  (PRIMARY|UNIQUE|KEY|FULLTEXT|SPATIAL|CONSTRAINT)", a) else "column line")
                    why[kind] += 1
                    first.setdefault(kind, (key, a, b))
        print(f"mysql {version}: {exact} of {len(tables)} tables generated exactly")
        for k, n in why.most_common():
            print(f"  {n:5} {k}")
            ex = first[k]
            if k == "line count":
                print("        want:\n" + ex[1] + "\n        got:\n" + ex[2])
            else:
                print(f"        want {ex[1][:150]!r}\n        got  {ex[2][:150]!r}")


if __name__ == "__main__":
    main()
