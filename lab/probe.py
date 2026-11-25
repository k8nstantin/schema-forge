"""The lab's probe and selective read: first a cheap probe (the version, the roster of objects by kind and name, and
every statistics group the plugin declares, each detected on the live server as available, off with how to turn it
on, or not in this version); then the person's choice (definitions only, some objects, some statistics groups, or
all); then a read of only that. Every statement sent is counted, so a test can prove nothing unchosen is asked.

  python3 lab/probe.py      probe and read every server of the lab, in every mode
"""
import json
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PW = next(l.split('"')[1] for l in open(os.path.join(ROOT, "engines/mysql/tests/live.rs")) if l.startswith("const ROOT"))
SCHEMAS = tuple(os.environ.get("LAB_SCHEMAS", "shop,torture,Gotcha Zone").split(","))  # the schemas a run reads


class Server:
    """One live server, every statement it is sent counted."""

    def __init__(self, engine, container):
        self.engine, self.container, self.sent = engine, container, []

    def ask(self, sql):
        self.sent.append(sql)
        if self.engine == "mysql":
            args = ["docker", "exec", "-i", self.container, "mysql", "-uroot", f"-p{PW}", "-B", "-N", "--raw"]
        else:
            args = ["docker", "exec", "-i", self.container, "psql", "-U", "postgres", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1"]
        r = subprocess.run(args, input=sql, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(r.stderr.strip()[-300:])
        return [l.split("\t") for l in r.stdout.splitlines() if l]


def in_list(xs):
    return ",".join("'" + x.replace("'", "''") + "'" for x in xs)


# --- what each plugin declares: its roster query and its statistics groups ------------------------------------------

S = in_list(SCHEMAS)
PLUGINS = {
    "mysql": {
        "version": "SELECT VERSION()",
        "roster": f"""SELECT 'table', TABLE_SCHEMA, TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ({S}) AND TABLE_TYPE='BASE TABLE'
            UNION ALL SELECT 'view', TABLE_SCHEMA, TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA IN ({S})
            UNION ALL SELECT LOWER(ROUTINE_TYPE), ROUTINE_SCHEMA, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA IN ({S})
            UNION ALL SELECT 'trigger', TRIGGER_SCHEMA, TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA IN ({S})
            UNION ALL SELECT 'event', EVENT_SCHEMA, EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA IN ({S})""",
        # group: (what it gives, the check that says whether it is on (a row: on, why), the read when chosen)
        "groups": {
            "sizes": ("row estimates, data and index size, last write",
                      "SELECT 'on', 'always'",
                      f"SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, UPDATE_TIME FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ({S})"),
            "table_io": ("rows read and written per table, and the time spent",
                         "SELECT IF(@@performance_schema, 'on', 'off'), IF(@@performance_schema, 'performance_schema on', 'performance_schema is off: it is a startup setting (performance_schema = ON)')",
                         f"SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_READ, COUNT_WRITE, SUM_TIMER_WAIT FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA IN ({S})"),
            "index_use": ("reads per index, and indexes never read",
                          "SELECT IF(@@performance_schema, 'on', 'off'), IF(@@performance_schema, 'performance_schema on', 'performance_schema is off')",
                          f"SELECT OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME, COUNT_READ FROM performance_schema.table_io_waits_summary_by_index_usage WHERE OBJECT_SCHEMA IN ({S})"),
            "routine_calls": ("calls and time per procedure, function, trigger and event",
                              "SELECT IF(@@performance_schema, 'on', 'off'), IF(@@performance_schema, 'performance_schema on', 'performance_schema is off')",
                              f"SELECT OBJECT_TYPE, OBJECT_SCHEMA, OBJECT_NAME, COUNT_STAR, SUM_TIMER_WAIT FROM performance_schema.events_statements_summary_by_program WHERE OBJECT_SCHEMA IN ({S})"),
            "statements": ("each statement shape: calls, time, rows examined and sent",
                           "SELECT IF(@@performance_schema AND (SELECT ENABLED FROM performance_schema.setup_consumers WHERE NAME='statements_digest')='YES', 'on', 'off'), 'the statements_digest consumer'",
                           f"SELECT SCHEMA_NAME, DIGEST, DIGEST_TEXT, COUNT_STAR, SUM_TIMER_WAIT, SUM_ROWS_EXAMINED, SUM_ROWS_SENT FROM performance_schema.events_statements_summary_by_digest WHERE SCHEMA_NAME IN ({S})"),
            "innodb_stats": ("InnoDB's persistent statistics per table and index",
                             "SELECT 'on', 'mysql.innodb_table_stats'",
                             f"SELECT database_name, table_name, n_rows, clustered_index_size FROM mysql.innodb_table_stats WHERE database_name IN ({S})"),
            "histograms": ("column histograms (8.0 and later, after ANALYZE TABLE … UPDATE HISTOGRAM)",
                           "SELECT IF(COUNT(*) = 0, 'none', 'check'), IF(COUNT(*) = 0, 'not in this version', '') FROM information_schema.TABLES WHERE TABLE_SCHEMA='information_schema' AND TABLE_NAME='COLUMN_STATISTICS'",
                           f"SELECT SCHEMA_NAME, TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMN_STATISTICS WHERE SCHEMA_NAME IN ({S})"),
        },
    },
    "postgresql": {
        "version": "SELECT current_setting('server_version')",
        "roster": f"""SELECT CASE WHEN c.relispartition THEN 'partition' ELSE CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table' WHEN 'v' THEN 'view'
              WHEN 'm' THEN 'materialized view' WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'foreign table' END END, n.nspname, c.relname, c.oid::regclass::text
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ({S}) AND c.relkind IN ('r','p','v','m','S','f')
              AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'i'))
            UNION ALL SELECT CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END, n.nspname, p.oid::regprocedure::text, p.oid::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname IN ({S}) AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'i')
            UNION ALL SELECT 'trigger', n.nspname, c.relname || '.' || t.tgname, t.oid::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname IN ({S}) AND NOT t.tgisinternal
            UNION ALL SELECT 'type', n.nspname, t.typname, t.oid::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname IN ({S}) AND t.typtype IN ('e','d','r')""",
        # a group the account reads only part of: (the question, true when part is hidden; what the person is told)
        "partial": {
            "statements": ("SELECT NOT (pg_has_role(current_user, 'pg_read_all_stats', 'member') OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user))",
                           "other accounts' statement texts are hidden from this account: grant it pg_read_all_stats"),
        },
        "groups": {
            "sizes": ("row estimates, table, index and total size",
                      "SELECT 'on', 'always'",
                      f"SELECT n.nspname, c.relname, c.reltuples, pg_table_size(c.oid), pg_indexes_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ({S}) AND c.relkind IN ('r','p','m')"),
            "table_io": ("scans, rows read and written, live and dead rows, last vacuum and analyze",
                         "SELECT CASE WHEN current_setting('track_counts') = 'on' THEN 'on' ELSE 'off' END, CASE WHEN current_setting('track_counts') = 'on' THEN 'track_counts on' ELSE 'track_counts is off: set track_counts = on' END",
                         f"SELECT schemaname, relname, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze FROM pg_stat_user_tables WHERE schemaname IN ({S})"),
            "index_use": ("scans per index, and indexes never scanned",
                          "SELECT CASE WHEN current_setting('track_counts') = 'on' THEN 'on' ELSE 'off' END, 'track_counts'",
                          f"SELECT schemaname, relname, indexrelname, idx_scan, idx_tup_read FROM pg_stat_user_indexes WHERE schemaname IN ({S})"),
            "cache": ("blocks found in memory against blocks read from disk",
                      "SELECT CASE WHEN current_setting('track_counts') = 'on' THEN 'on' ELSE 'off' END, 'track_counts'",
                      f"SELECT schemaname, relname, heap_blks_read, heap_blks_hit, idx_blks_read, idx_blks_hit FROM pg_statio_user_tables WHERE schemaname IN ({S})"),
            "routine_calls": ("calls and time per function",
                              "SELECT CASE current_setting('track_functions') WHEN 'none' THEN 'off' ELSE 'on' END, CASE current_setting('track_functions') WHEN 'none' THEN 'track_functions is none: set track_functions = ''all'' (SQL and procedural functions) or ''pl'' (procedural only), no restart' WHEN 'pl' THEN 'track_functions = pl: procedural functions only, plain SQL ones are not counted' ELSE 'track_functions = all' END",
                              f"SELECT schemaname, funcname, calls, total_time, self_time FROM pg_stat_user_functions WHERE schemaname IN ({S})"),
            "statements": ("each statement shape: calls, time, rows",
                           "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN 'on' ELSE 'off' END, CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN 'pg_stat_statements' WHEN current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%' THEN 'loaded, not created: CREATE EXTENSION pg_stat_statements' ELSE 'pg_stat_statements not loaded: add it to shared_preload_libraries (a restart), then CREATE EXTENSION pg_stat_statements' END",
                           "SELECT queryid, left(query, 120), calls, total_exec_time, rows FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())"),
            "column_stats": ("each column's nulls, distinct values, most common values (once the server has analyzed it)",
                             f"SELECT CASE WHEN count(*) > 0 THEN 'on' ELSE 'empty' END, CASE WHEN count(*) > 0 THEN 'pg_stats' ELSE 'nothing analyzed yet: the server fills it as it analyzes' END FROM pg_stats WHERE schemaname IN ({S})",
                             f"SELECT schemaname, tablename, attname, null_frac, n_distinct FROM pg_stats WHERE schemaname IN ({S})"),
        },
    },
}

def lit(s):
    """A string literal, its quotes doubled."""
    return "'" + str(s).replace("'", "''") + "'"


def q_my(schema, name):
    """A MySQL name, its backticks doubled."""
    return ".".join("`" + p.replace("`", "``") + "`" for p in (schema, name))


def pg_rel(o):
    return f"{lit(o['id'])}::regclass"


DEFINITIONS = {
    "mysql": {
        "table": lambda o: [f"SHOW CREATE TABLE {q_my(o['schema'], o['name'])}",
                            f"SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA={lit(o['schema'])} AND TABLE_NAME={lit(o['name'])}"],
        "view": lambda o: [f"SHOW CREATE VIEW {q_my(o['schema'], o['name'])}"],
        "procedure": lambda o: [f"SHOW CREATE PROCEDURE {q_my(o['schema'], o['name'])}"],
        "function": lambda o: [f"SHOW CREATE FUNCTION {q_my(o['schema'], o['name'])}"],
        "trigger": lambda o: [f"SHOW CREATE TRIGGER {q_my(o['schema'], o['name'])}"],
        "event": lambda o: [f"SHOW CREATE EVENT {q_my(o['schema'], o['name'])}"],
    },
    "postgresql": {
        "table": lambda o: [pg_columns(o), pg_constraints(o), pg_indexes(o)],
        "partitioned table": lambda o: [pg_columns(o), pg_constraints(o), pg_indexes(o), f"SELECT pg_get_partkeydef({pg_rel(o)})"],
        "partition": lambda o: [f"SELECT pg_get_expr(relpartbound, oid), (SELECT inhparent::regclass::text FROM pg_inherits WHERE inhrelid = c.oid) FROM pg_class c WHERE oid = {pg_rel(o)}"],
        "view": lambda o: [f"SELECT pg_get_viewdef({pg_rel(o)})", pg_columns(o)],
        "materialized view": lambda o: [f"SELECT pg_get_viewdef({pg_rel(o)})", pg_columns(o), pg_indexes(o)],
        "sequence": lambda o: [f"SELECT seqstart, seqincrement, seqmin, seqmax, seqcache, seqcycle FROM pg_sequence WHERE seqrelid = {pg_rel(o)}"],
        "function": lambda o: [f"SELECT pg_get_functiondef({o['id']})"],
        "procedure": lambda o: [f"SELECT pg_get_functiondef({o['id']})"],
        "trigger": lambda o: [f"SELECT pg_get_triggerdef({o['id']})"],
        "type": lambda o: [f"SELECT t.typtype, format_type(t.typbasetype, t.typtypmod), (SELECT array_agg(enumlabel ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = t.oid) FROM pg_type t WHERE t.oid = {o['id']}"],
    },
}


def pg_columns(o):
    return f"SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_get_expr(d.adbin, d.adrelid), a.attidentity, a.attgenerated FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum WHERE a.attrelid = {pg_rel(o)} AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum"


def pg_constraints(o):
    return f"SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = {pg_rel(o)}"


def pg_indexes(o):
    return f"SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = {pg_rel(o)}"


# --- the three phases -----------------------------------------------------------------------------------------------

def broken_views(server, version, roster):
    """MySQL: the views that no longer work (a table they read is gone), with the server's reason. From 8.0 the reason
    is on the view's own row of information_schema.TABLES; 5.7 says it only when the views are checked, all at once."""
    views = [o for o in roster if o["kind"] == "view"]
    if server.engine != "mysql" or not views:
        return {}
    if not version.startswith("5."):
        rows = server.ask(f"SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA IN ({S}) "
                          "AND TABLE_TYPE = 'VIEW' AND TABLE_COMMENT LIKE 'View % references invalid%'")
        return {f"{r[0]}.{r[1]}": r[2] for r in rows}
    rows = server.ask("CHECK TABLE " + ", ".join(q_my(o["schema"], o["name"]) for o in views))
    out = {}
    for name, _, kind, said in rows:
        if kind == "Error" and name not in out:
            out[name] = said
    return out


def probe(server):
    """The version, the roster and every group's state: cheap, nothing else."""
    p = PLUGINS[server.engine]
    version = server.ask(p["version"])[0][0]
    roster = []
    for row in server.ask(p["roster"]):
        kind, schema, name = row[:3]
        roster.append({"kind": kind, "schema": schema, "name": name, "id": row[3] if len(row) > 3 else None,
                       "display": f"{schema}.{name}"})
    broken = broken_views(server, version, roster)
    for o in roster:
        if o["display"] in broken:
            o["broken"] = broken[o["display"]]
    groups = []
    for name, (gives, check, source) in p["groups"].items():
        try:
            state, why = server.ask(check)[0][:2]
            if state == "check":
                n = int(server.ask(f"SELECT COUNT(*) FROM information_schema.COLUMN_STATISTICS WHERE SCHEMA_NAME IN ({S})")[0][0])
                state, why = ("on", "information_schema.COLUMN_STATISTICS") if n else ("empty", "no histogram yet: they are made by ANALYZE TABLE … UPDATE HISTOGRAM")
            if state == "on":
                # the server keeps it; may this account read it? its source asked for no rows answers that, reading nothing
                server.ask(f"SELECT 1 FROM ({source}) x LIMIT 0")
                partial = PLUGINS[server.engine].get("partial", {}).get(name)
                if partial:
                    hidden = server.ask(partial[0])[0][0]
                    if hidden == "t":
                        state, why = "partial", partial[1]
        except RuntimeError as e:
            state, why = "no access", f"the account cannot read it: {str(e).splitlines()[-1][:120]}"
        groups.append({"group": name, "gives": gives, "state": state, "why": why})
    return {"engine": server.engine, "version": version, "roster": roster, "groups": groups}


def read(server, probed, choice):
    """Only what was chosen: {"objects": "all" | [names] | None, "groups": "all" | [names] | None}."""
    p = PLUGINS[server.engine]
    out = {"definitions": {}, "statistics": {}}
    objs = probed["roster"] if choice.get("objects") == "all" else [o for o in probed["roster"] if o["display"] in (choice.get("objects") or [])]
    for o in objs:
        key = f"{o['kind']} {o['display']}"
        try:
            out["definitions"][key] = [server.ask(sql) for sql in DEFINITIONS[server.engine][o["kind"]](o)]
        except RuntimeError as e:
            out.setdefault("unread", {})[key] = str(e).splitlines()[-1][:200]
    on = [g["group"] for g in probed["groups"] if g["state"] in ("on", "partial")]
    wanted = on if choice.get("groups") == "all" else [g for g in (choice.get("groups") or []) if g in on]
    for g in wanted:
        try:
            out["statistics"][g] = server.ask(p["groups"][g][2])
        except RuntimeError as e:
            out.setdefault("failed", {})[g] = str(e).splitlines()[-1][:160]
    return out


SERVERS = [("mysql", "sf-mysql-5-7"), ("mysql", "sf-mysql-8-0"), ("mysql", "sf-mysql-8-4"), ("mysql", "sf-mysql-9-7"),
           ("postgresql", "sf-pg-14"), ("postgresql", "sf-pg-15"), ("postgresql", "sf-pg-16"), ("postgresql", "sf-pg-17"),
           ("postgresql", "sf-pg-18")]

MODES = {
    "definitions only, every object": {"objects": "all", "groups": None},
    "two objects only": {"objects": ["shop.orders", "shop.customers"], "groups": None},
    "one statistics group only (index use)": {"objects": None, "groups": ["index_use"]},
    "all": {"objects": "all", "groups": "all"},
}


def main():
    results = []
    for engine, container in SERVERS:
        s = Server(engine, container)
        t = time.time()
        probed = probe(s)
        probe_ms, probe_n = (time.time() - t) * 1000, len(s.sent)
        row = {"server": f"{engine} {probed['version'].split('-')[0].split(' ')[0]}", "probe": (probe_n, probe_ms),
               "roster": len(probed["roster"]), "groups": {g["group"]: (g["state"], g["why"]) for g in probed["groups"]}, "modes": {}}
        for mode, choice in MODES.items():
            s.sent = []
            t = time.time()
            got = read(s, probed, choice)
            stats_sent = [x for x in s.sent if any(src in x for src in ("performance_schema", "pg_stat", "pg_statio", "innodb_table_stats", "COLUMN_STATISTICS", "reltuples", "TABLE_ROWS"))]
            row["modes"][mode] = {"sent": len(s.sent), "ms": (time.time() - t) * 1000, "objects": len(got["definitions"]),
                                  "groups": sorted(got["statistics"]), "statistics_statements": len(stats_sent)}
        results.append(row)
    json.dump(results, open(os.path.join(HERE, "out", "probe.json"), "w"), indent=1, default=str)
    print("== the probe: statements sent, time, objects in the roster, and each statistics group's state")
    for r in results:
        states = "  ".join(f"{g}:{st}" for g, (st, _) in r["groups"].items())
        print(f"  {r['server']:16} {r['probe'][0]} statements {r['probe'][1]:5.0f} ms  {r['roster']:2} objects  {states}")
    print("== why a group is off, as the person is told")
    seen = set()
    for r in results:
        for g, (st, why) in r["groups"].items():
            if st != "on" and (g, why) not in seen:
                seen.add((g, why))
                print(f"  {r['server']}: {g}: {why}")
    print("== each mode: statements sent, of them statistics statements, time, objects read, statistics groups read")
    for r in results:
        print(f"  {r['server']}")
        for mode, m in r["modes"].items():
            print(f"    {mode:40} {m['sent']:3} sent ({m['statistics_statements']} for statistics) {m['ms']:6.0f} ms  {m['objects']:2} objects  {', '.join(m['groups']) or '-'}")


if __name__ == "__main__":
    main()
