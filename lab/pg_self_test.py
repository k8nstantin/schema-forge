"""Our own schema as PostgreSQL's hardest sample: schema/dump/schema_forge.sql (the locked design, as PostgreSQL 18 holds
it) loaded into PostgreSQL 15, 16, 17 and 18, captured, stored as one design in the locked tables, written back from
them alone and loaded into a fresh server of the same version, then compared part by part (lab/repo_pg_store.py).
Its tables, two-column deferrable foreign keys, checks, a NULLS NOT DISTINCT index, PL/pgSQL functions, a trigger,
grants to four roles and a comment on every column are what the engine must keep.

uuidv7() is PostgreSQL 18's; before 18 a stand-in of the same name in public makes the ids (and before 17
uuid_extract_version too), and the dump's calls name it: nothing else of the schema changes.

  python3 lab/pg_self_test.py [15 16 17 18]
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import common as C  # noqa: E402
import extract as X  # noqa: E402

ROOT = os.path.dirname(HERE)
NAMESPACES = ("cortex", "ui", "engine_mysql", "engine_postgresql")


def prelude(version):
    sql = "DO $$ BEGIN CREATE ROLE sf_owner NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;\n" + "".join(
        f"DO $$ BEGIN CREATE ROLE {r} LOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;\n" for r in ("sf_service", "sf_agent", "sf_reader"))
    if int(version) < 18:
        sql += ("CREATE OR REPLACE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql VOLATILE AS $f$ SELECT encode(set_bit(set_bit(overlay("
                "uuid_send(gen_random_uuid()) placing substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3) "
                "FROM 1 FOR 6), 52, 1), 53, 1), 'hex')::uuid $f$;\n")
    if int(version) < 17:
        sql += ("CREATE OR REPLACE FUNCTION public.uuid_extract_version(u uuid) RETURNS smallint LANGUAGE sql IMMUTABLE AS "
                "$f$ SELECT (get_byte(uuid_send(u), 6) >> 4)::smallint $f$;\n")
    return sql


def dump_for(version):
    text = open(os.path.join(ROOT, "schema/dump/schema_forge.sql")).read()
    if int(version) < 18:
        text = text.replace("uuidv7()", "public.uuidv7()")
    if int(version) < 17:
        text = text.replace("uuid_extract_version(", "public.uuid_extract_version(")
        text = "\n".join(l for l in text.split("\n") if not l.startswith("SET transaction_timeout"))  # pg_dump 18's, unknown before 17
    return text


def psql(container, sql):
    r = subprocess.run(["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", X.SOURCE_DB, "-q", "-v", "ON_ERROR_STOP=1"], input=sql,
                       capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"{container}: {r.stderr.strip()[-600:]}")


def main():
    versions = sys.argv[1:] or ["15", "16", "17", "18"]
    for v in versions:
        # a server of its own for the run, made and dropped here: nothing of the samples' database is read with ours
        c = f"sf-pg-self-{v}"
        C.S.remove(c)
        C.S.sh("docker", "run", "-d", "--name", c, "-e", f"POSTGRES_PASSWORD={C.S.PW}", f"postgres:{v}-alpine")
        try:
            C.ready_pg(c)
            psql(c, prelude(v) + dump_for(v))
            X.SCHEMAS = NAMESPACES
            parts = X.extract_pg(v, c)
            path = os.path.join(HERE, "out", f"self-postgresql-{v}.json")
            json.dump({"engine": "postgresql", "version": v, "prelude": prelude(v), "source": c, "parts": parts}, open(path, "w"),
                      indent=1, sort_keys=True, default=str)
            print(f"postgresql {v}: our own schema loaded and captured, {len(parts)} parts")
            r = subprocess.run([sys.executable, "-B", os.path.join(HERE, "repo_pg_store.py"), "--roundtrip", path], capture_output=True, text=True)
            print((r.stdout + r.stderr).strip())
        finally:
            C.S.remove(c)


if __name__ == "__main__":
    main()
