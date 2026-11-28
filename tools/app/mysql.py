#!/usr/bin/env python3
"""The round trip, the proof of engine_mysql in Rust (SF-156 step 13), on one server image:

  1. the every-object samples (tools/mysql/samples) are loaded into server A, a MySQL or Percona in a container that
     also listens on a free port of 127.0.0.1
  2. schema-forge import reads A into the design rt_a of a store (PostgreSQL 18 in a container, published)
  3. schema-forge write prints the design as SQL, which is loaded into a fresh server B of the same image
  4. schema-forge import reads B into the design rt_b
  5. the two designs are compared as the task says they are equal: for every table of the mapping, the same rows once
     each row's id and design are dropped and every id replaced by the name path of the row it points to; both designs
     are read as cortex_reader, and each difference is listed by table and path
  6. every column that is NULL or its default in every row of rt_a and is not in the task's unfilled list is listed
     (a mapping that fills nothing shows); the pull request carries that list
  7. the ImportReport of A and the time of the write are printed

  python3 tools/app/mysql.py --server mysql:5.7|mysql:8.0|mysql:8.4|mysql:9.7|percona:5.7|percona:8.0|percona:8.4
                             [--private FILE] [--generated N [--import-limit S] [--write-limit S]]

  --private FILE   load the owner's private schema (never committed) in place of the samples: counts only, never a name
  --generated N    write into A a schema of N objects made here (tables with columns, keys, foreign keys and indexes,
                   views reading them, routines and triggers), the same every run and never committed; import it and
                   write it, and fail when the import takes more than --import-limit seconds or the write more than
                   --write-limit seconds (the comparison is left to the samples)
"""
import collections
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.dirname(HERE))
from sf.plugin import engine_folders, install_all, package  # noqa: E402
from sf.servers import MySQL  # noqa: E402
from sf.store import Failed, Store, docker  # noqa: E402

ARGS = sys.argv[1:]
SAMPLES = os.path.join(ROOT, "tools", "mysql", "samples")
CORTEX = ("cortex_service", "cortex_agent", "cortex_reader")


def option(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


SERVER = option("--server", "mysql:8.0")
PRIVATE = option("--private")
GENERATED = int(option("--generated", "0"))
IMPORT_LIMIT = float(option("--import-limit", "0"))
WRITE_LIMIT = float(option("--write-limit", "0"))


# --- the servers --------------------------------------------------------------------------------------------------------------


def image_of(server):
    """The image of a server named as the task names it: percona:8.0 is Docker Hub's percona/percona-server:8.0."""
    return "percona/percona-server:" + server.split(":")[1] if server.startswith("percona:") else server


class Published(MySQL):
    """A MySQL or Percona that also listens on a free port of 127.0.0.1 (self.port), where the binary signs in as root
    (the image allows an empty root password from any host)."""

    def __init__(self, server, name):
        super().__init__(image_of(server), name)

    def __enter__(self):
        r = docker("run", "-d", "--name", self.name, "-p", "127.0.0.1::3306", "-e", "MYSQL_ALLOW_EMPTY_PASSWORD=1", "-e", "MYSQL_ROOT_HOST=%",
                   self.image, "--log-bin-trust-function-creators=1", *self.options)
        if r.returncode:
            raise SystemExit(f"docker run {self.image}: {r.stderr.strip()}")
        self.port = docker("port", self.name, "3306/tcp").stdout.strip().splitlines()[0].rsplit(":", 1)[1]
        # the image first runs a bootstrap server with networking off, then restarts: wait for the real one, on 3306
        for _ in range(900):
            text = "\n".join((lambda l: l.stdout + l.stderr)(docker("logs", self.name)).splitlines())
            if "ready for connections" in text and "port: 3306" in text and docker("exec", self.name, "mysql", "-uroot", "-N", "-e", "SELECT 1").returncode == 0:
                return self
            time.sleep(0.5)
        self.__exit__()
        raise SystemExit(f"{self.image} did not answer within seven and a half minutes")


def sample_files(image):
    """The every-object samples a server of this image loads: common, then each version's own file up to its version."""
    version = image.split(":")[1]
    files = [os.path.join(SAMPLES, "common.sql")]
    for v in ("8.0", "8.4", "9.7"):
        if v <= version and os.path.exists(os.path.join(SAMPLES, f"{v}.sql")):
            files.append(os.path.join(SAMPLES, f"{v}.sql"))
    files.append(os.path.join(SAMPLES, "server.sql"))
    if version >= "8.0":
        files.append(os.path.join(SAMPLES, "server-8.0.sql"))
    if "percona" in image and os.path.exists(os.path.join(SAMPLES, f"percona-{version}.sql")):
        files.append(os.path.join(SAMPLES, f"percona-{version}.sql"))
    return files


# --- a generated schema -------------------------------------------------------------------------------------------------------------


def generated_schema(n, path):
    """A schema of n objects (60% tables, 15% views, 8% procedures, 7% functions, the rest triggers) over eight
    databases, written to path: the same every run."""
    tables, views, procedures, functions = n * 60 // 100, n * 15 // 100, n * 8 // 100, n * 7 // 100
    triggers = n - tables - views - procedures - functions
    databases = 8
    out = ["SET FOREIGN_KEY_CHECKS = 0;"] + [f"CREATE DATABASE IF NOT EXISTS `gen{d}`;" for d in range(databases)]
    per_database = [[] for _ in range(databases)]
    for i in range(tables):
        d = i % databases
        previous = per_database[d][-1] if per_database[d] else None
        per_database[d].append(i)
        fk = f",\n  CONSTRAINT `fk_t{i}` FOREIGN KEY (`parent_id`) REFERENCES `t{previous}` (`id`) ON DELETE SET NULL" if previous is not None else ""
        out.append(f"USE `gen{d}`;\nCREATE TABLE `t{i}` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT,\n  `parent_id` BIGINT NULL,\n  `name` VARCHAR(100) NOT NULL,\n"
                   f"  `code` CHAR(8) NOT NULL,\n  `amount` DECIMAL(12,2) NOT NULL DEFAULT 0,\n  `created` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,\n"
                   f"  `note` TEXT,\n  PRIMARY KEY (`id`),\n  KEY `k_name_{i}` (`name`),\n  UNIQUE KEY `u_code_{i}` (`code`){fk}\n) ENGINE=InnoDB COMMENT='generated {i}';")
    for i in range(views):
        d = i % databases
        mine = per_database[d]
        a, b = mine[i // databases % len(mine)], mine[(i // databases + 1) % len(mine)]
        out.append(f"USE `gen{d}`;\nCREATE VIEW `v{i}` AS SELECT `a`.`id`, `a`.`name`, `b`.`amount` FROM `t{a}` `a` JOIN `t{b}` `b` ON `b`.`parent_id` = `a`.`id`;")
    out.append("DELIMITER //")
    for i in range(procedures):
        out.append(f"USE `gen{i % databases}`//\nCREATE PROCEDURE `p{i}`(IN `a` INT, OUT `b` INT) BEGIN SET `b` = `a` + {i}; END//")
    for i in range(functions):
        out.append(f"USE `gen{i % databases}`//\nCREATE FUNCTION `f{i}`(`a` INT) RETURNS INT DETERMINISTIC RETURN `a` + {i}//")
    for i in range(triggers):
        d = i % databases
        mine = per_database[d]
        table = mine[(i // databases // 4) % len(mine)]
        timing, event = [("BEFORE", "INSERT"), ("AFTER", "INSERT"), ("BEFORE", "UPDATE"), ("AFTER", "UPDATE")][(i // databases) % 4]
        body = "SET NEW.`note` = IFNULL(NEW.`note`, '')" if timing == "BEFORE" else "SET @sf_last = NEW.`id`"
        out.append(f"USE `gen{d}`//\nCREATE TRIGGER `trg{i}` {timing} {event} ON `t{table}` FOR EACH ROW {body}//")
    out.append("DELIMITER ;")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return tables + views + procedures + functions + triggers


# --- the binary --------------------------------------------------------------------------------------------------------------------


def build_binary(release):
    cmd = ["cargo", "build", "--locked", "--quiet", "--bin", "schema-forge"] + (["--release"] if release else [])
    print(f"== build: {' '.join(cmd)}", flush=True)
    if subprocess.run(cmd, cwd=ROOT).returncode:
        raise SystemExit("FAIL  build")
    return os.path.join(ROOT, "target", "release" if release else "debug", "schema-forge")


class Binary:
    def __init__(self, path, store, accounts_file):
        self.path, self.base = path, ["--host", "127.0.0.1", "--port", str(store.port), "--accounts-file", accounts_file]

    def run(self, *args):
        """Runs the binary; returns (stdout, seconds). A failure is Failed with what the binary said."""
        start = time.monotonic()
        r = subprocess.run([self.path, *args, *self.base], capture_output=True, text=True, cwd=ROOT)
        took = time.monotonic() - start
        if r.returncode:
            raise Failed(f"schema-forge {args[0]}: {(r.stdout + r.stderr).strip()[:600]}")
        return r.stdout, took

    def import_from(self, server, design):
        out, took = self.run("import", "--engine", "mysql", "--source", f"mysql://root@127.0.0.1:{server.port}", "--design", design)
        return out, took

    def write(self, design):
        return self.run("write", "--design", design)


# --- the comparison ----------------------------------------------------------------------------------------------------------------

# the name path of each kind of id: what a row's id or reference is replaced by
PATHS = """
ns AS (SELECT n.id, CASE WHEN n.parent IS NULL THEN n.name ELSE p.name || '/' || n.name END AS path
       FROM cortex.namespaces n LEFT JOIN cortex.namespaces p ON p.id = n.parent WHERE n.design = '{d}'),
obj AS (SELECT o.id, ns.path || '|' || o.kind || '|' || o.name AS path FROM cortex.objects o JOIN ns ON ns.id = o.namespace WHERE o.design = '{d}'),
col AS (SELECT c.id, obj.path || '|' || c.name AS path FROM cortex.columns c JOIN obj ON obj.id = c.object WHERE c.design = '{d}'),
idx AS (SELECT i.id, obj.path || '|' || i.name AS path FROM cortex.indexes i JOIN obj ON obj.id = i.object WHERE i.design = '{d}'),
con AS (SELECT k.id, obj.path || '|' || coalesce(k.name, '') AS path FROM cortex.constraints k JOIN obj ON obj.id = k.object WHERE k.design = '{d}'),
ipart AS (SELECT p.id, idx.path || '|' || p.position AS path FROM cortex.index_parts p JOIN idx ON idx.id = p.index WHERE p.design = '{d}'),
part AS (SELECT p.id, obj.path || '|' || coalesce(pp.name, '') || '|' || p.name AS path FROM engine_mysql.partitions p
         JOIN obj ON obj.id = p.partitioning LEFT JOIN engine_mysql.partitions pp ON pp.id = p.parent WHERE p.design = '{d}')
"""

# every table of the mapping: (table, the paths its own id is (or None), {reference column: paths}, key expression)
# in the key, t is the row and r_<column> the path of what a reference column points to
TABLES = [
    ("cortex.namespaces", "ns", {"parent": "ns"}, "own.path"),
    ("cortex.objects", "obj", {"namespace": "ns", "parent": "obj"}, "own.path"),
    ("cortex.columns", "col", {"object": "obj"}, "own.path"),
    ("cortex.indexes", "idx", {"object": "obj"}, "own.path"),
    ("cortex.index_parts", None, {"index": "idx", "column": "col"}, "r_index.path || '|' || t.position"),
    ("cortex.constraints", "con", {"object": "obj", "to_object": "obj"}, "own.path"),
    ("cortex.constraint_columns", None, {"constraint": "con", "column": "col", "to_column": "col"}, "r_constraint.path || '|' || t.position"),
    ("cortex.dependencies", None, {"object": "obj", "uses": "obj"}, "r_object.path || '|' || r_uses.path || '|' || t.\"as\" || '|' || t.position"),
    ("engine_mysql.instances", "ns", {}, "own.path"),
    ("engine_mysql.databases", "ns", {}, "own.path"),
    ("engine_mysql.tables", "obj", {}, "own.path"),
    ("engine_mysql.columns", "col", {"compression_dictionary": "obj"}, "own.path"),
    ("engine_mysql.indexes", "idx", {}, "own.path"),
    ("engine_mysql.index_parts", "ipart", {}, "own.path"),
    ("engine_mysql.partitionings", "obj", {}, "own.path"),
    ("engine_mysql.partitions", "part", {"partitioning": "obj", "parent": "part"}, "own.path"),
    ("engine_mysql.views", "obj", {}, "own.path"),
    ("engine_mysql.routines", "obj", {}, "own.path"),
    ("engine_mysql.routine_parameters", None, {"routine": "obj"}, "r_routine.path || '|' || t.position"),
    ("engine_mysql.triggers", "obj", {}, "own.path"),
    ("engine_mysql.events", "obj", {}, "own.path"),
    ("engine_mysql.libraries", "obj", {}, "own.path"),
    ("engine_mysql.accounts", "obj", {}, "own.path"),
    ("engine_mysql.role_grants", None, {"grantee": "obj", "role": "obj"}, "r_grantee.path || '|' || r_role.path"),
    ("engine_mysql.privileges", None, {"grantee": "obj", "object": "obj", "proxied": "obj"},
     "r_grantee.path || '|' || t.level || '|' || t.privilege || '|' || coalesce(t.database_name, '') || '|' || coalesce(t.object_name, '') || '|' || "
     "coalesce(t.column_name, '') || '|' || coalesce(t.routine_kind, '') || '|' || coalesce(r_proxied.path, '') || '|' || t.grant_option"),
    ("engine_mysql.servers", "obj", {}, "own.path"),
    ("engine_mysql.loadable_functions", "obj", {}, "own.path"),
    ("engine_mysql.components", "obj", {}, "own.path"),
    ("engine_mysql.resource_groups", "obj", {}, "own.path"),
    ("engine_mysql.spatial_reference_systems", "obj", {}, "own.path"),
    ("engine_mysql.tablespaces", "obj", {}, "own.path"),
    ("engine_mysql.compression_dictionaries", "obj", {}, "own.path"),
]

# the columns the task says no MySQL source fills (its unfilled list): never reported as unfilled
UNFILLED = {
    "cortex.namespaces": {"comment"}, "cortex.objects": {"signature", "notes"}, "cortex.indexes": {"condition"}, "cortex.index_parts": {"included"},
    "cortex.constraints": {"deferrable", "initially_deferred"}, "engine_mysql.views": {"duality"}, "engine_mysql.tablespaces": {"file_block_size", "engine_attribute"},
}


def select(table, own, refs, key, design):
    joins, removed, built = [], ["id", "design"], []
    if own:
        joins.append(f"LEFT JOIN {own} own ON own.id = t.id")
    for column, paths in refs.items():
        joins.append(f"LEFT JOIN {paths} r_{column} ON r_{column}.id = t.\"{column}\"")
        removed.append(column)
        built.append(f"'{column}', r_{column}.path")
    data = "(to_jsonb(t) - " + " - ".join(f"'{c}'" for c in removed) + ")"
    if built:
        data += f" || jsonb_build_object({', '.join(built)})"
    return f"SELECT '{table}' AS tbl, ({key}) AS path, {data} AS data FROM {table} t {' '.join(joins)} WHERE t.design = '{design}'"


def read_design(store, design):
    """Every table's rows of a design as cortex_reader reads them: {table: [(path, data)]}."""
    union = "\nUNION ALL\n".join(select(*spec, design) for spec in TABLES)
    script = f"SET ROLE cortex_reader;\nWITH {PATHS.format(d=design)}\nSELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM ({union}) x;\n"
    rc, out, err = store.sql(script, check=False)
    if rc:
        raise Failed(f"reading design {design} as cortex_reader: {err.strip()[:400]}")
    rows = collections.defaultdict(list)
    line = [l for l in out.splitlines() if l.startswith("[")][-1]
    for r in json.loads(line):
        rows[r["tbl"]].append((r["path"], r["data"]))
    return rows


def compare(a, b, private):
    """Prints each difference by table and path (a count only, for a private schema); returns how many."""
    total = 0
    for table, *_ in TABLES:
        left, right = collections.defaultdict(list), collections.defaultdict(list)
        for path, data in a.get(table, []):
            left[path].append(json.dumps(data, sort_keys=True))
        for path, data in b.get(table, []):
            right[path].append(json.dumps(data, sort_keys=True))
        different = []
        for path in sorted(set(left) | set(right), key=str):
            x, y = sorted(left.get(path, [])), sorted(right.get(path, []))
            if x == y:
                continue
            if not x or not y:
                different.append((path, f"only in {'A' if x else 'B'}"))
                continue
            dx, dy = json.loads(x[0]), json.loads(y[0])
            columns = [c for c in sorted(set(dx) | set(dy)) if dx.get(c) != dy.get(c)]
            different.append((path, "; ".join(f"{c}: A {json.dumps(dx.get(c))[:120]} B {json.dumps(dy.get(c))[:120]}" for c in columns) or f"{len(x)} rows in A, {len(y)} in B"))
        total += len(different)
        if different:
            print(f"  FAIL  {table}: {len(different)} differ")
            if not private:
                for path, what in different[:12]:
                    print(f"        {path}: {what}")
    return total


def never_filled(store, design):
    """Per table, every column NULL or its default in every row of the design that the task does not list as unfilled."""
    lines = []
    for table, *_ in TABLES:
        schema, name = table.split(".")
        columns = store.sql(f"SELECT a.attname || '=' || coalesce(pg_get_expr(d.adbin, d.adrelid), 'NULL') FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid "
                            f"JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
                            f"WHERE n.nspname = '{schema}' AND c.relname = '{name}' AND a.attnum > 0 AND NOT a.attisdropped AND a.attname NOT IN ('id', 'design') ORDER BY a.attnum;")[1].splitlines()
        parts = []
        for entry in columns:
            column, _, default = entry.partition("=")
            parts.append(f"count(*) FILTER (WHERE \"{column}\" IS DISTINCT FROM ({default}))")
        counts = store.sql(f"SELECT count(*), {', '.join(parts)} FROM {table} WHERE design = '{design}';")[1].strip().split("|")
        rows = int(counts[0])
        if rows == 0:
            lines.append(f"  {table}: no rows")
            continue
        silent = [e.partition("=")[0] for e, n in zip(columns, counts[1:]) if int(n) == 0 and e.partition("=")[0] not in UNFILLED.get(table, set())]
        if silent:
            lines.append(f"  {table}: NULL or its default in all {rows} rows: {', '.join(silent)}")
    return lines


# --- the run -------------------------------------------------------------------------------------------------------------------


def install_store():
    store = Store("sf-mysql-rt", published=True).__enter__()
    try:
        plugins = [package(f)[0]["namespace"] for f in engine_folders()]
        accounts = list(CORTEX) + [f"{ns}_service" for ns in plugins]
        passwords = {a: secrets.token_urlsafe(24) for a in accounts}
        store.sql("".join(f"ALTER ROLE {a} PASSWORD '{passwords[a]}';\n" for a in CORTEX), db="postgres")
        install_all(store, passwords)
    except BaseException:
        store.__exit__(None, None, None)
        raise
    folder = tempfile.mkdtemp(prefix="sf-mysql-rt-")
    path = os.path.join(folder, "accounts.env")
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write("".join(f"{a.upper()}_PASSWORD={p}\n" for a, p in passwords.items()))
    return store, folder, path


def report_lines(out):
    return "\n".join("    " + l.strip() for l in out.splitlines()[1:])


def main():
    if not shutil.which("cargo") or not shutil.which("docker"):
        print("FAIL  cargo and docker are both needed")
        return 1
    release = bool(GENERATED or PRIVATE)
    binary_path = build_binary(release)
    what = "a private schema" if PRIVATE else (f"a generated schema of {GENERATED} objects" if GENERATED else "the every-object samples")
    print(f"== {SERVER}: {what}", flush=True)
    store, folder, accounts = install_store()
    try:
        binary = Binary(binary_path, store, accounts)
        with Published(SERVER, name="sf-rt-a") as a:
            if PRIVATE:
                a.load(PRIVATE)
            elif GENERATED:
                path = os.path.join(folder, "generated.sql")
                made = generated_schema(GENERATED, path)
                print(f"  loading {made} generated objects into A ...", flush=True)
                a.load(path)
            else:
                for f in sample_files(SERVER):
                    a.load(f)
            out, took_import = binary.import_from(a, "rt_a")
            print(f"  import from A ({took_import:.2f} s wall):\n{report_lines(out)}")
            sql, took_write = binary.write("rt_a")
            print(f"  write of the design ({took_write:.2f} s wall, {len(sql.splitlines())} lines of SQL)")
        failed = False
        if GENERATED:
            objects = int(next(l.split()[1] for l in out.splitlines() if l.strip().startswith("objects")))
            if objects != GENERATED:
                print(f"  FAIL  the design holds {objects} objects, {GENERATED} were generated")
                failed = True
        if not GENERATED:
            with Published(SERVER, name="sf-rt-b") as b:
                try:
                    b.sql(sql)
                except Failed as e:
                    print(f"  FAIL  loading the written SQL into B: {e}")
                    return 1
                _, took_b = binary.import_from(b, "rt_b")
            differences = compare(read_design(store, design_id(store, "rt_a")), read_design(store, design_id(store, "rt_b")), bool(PRIVATE))
            for line in never_filled(store, design_id(store, "rt_a")) if not PRIVATE else []:
                print(line)
            if differences:
                print(f"FAIL  round trip on {SERVER}: {differences} differences")
                return 1
            print(f"pass  round trip on {SERVER}: the two designs are equal")
        if IMPORT_LIMIT or WRITE_LIMIT:
            for label, took, limit in (("import", took_import, IMPORT_LIMIT), ("write", took_write, WRITE_LIMIT)):
                if limit and took > limit:
                    print(f"  FAIL  the {label} took {took:.2f} s, over the limit of {limit:g} s")
                    failed = True
            if not failed:
                print(f"pass  speed on {SERVER}: import {took_import:.2f} s (limit {IMPORT_LIMIT:g}), write {took_write:.2f} s (limit {WRITE_LIMIT:g})")
        return 1 if failed else 0
    except Failed as e:
        print(f"FAIL  {e}")
        return 1
    finally:
        store.__exit__(None, None, None)
        shutil.rmtree(folder, ignore_errors=True)


def design_id(store, name):
    return store.value(f"SELECT id FROM cortex.designs WHERE name = '{name}'")


if __name__ == "__main__":
    sys.exit(main())
