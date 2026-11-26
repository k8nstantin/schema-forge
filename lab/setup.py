"""The lab's servers, one layout, built by one command:

  sf-mysql-5.7  sf-mysql-8.0  sf-mysql-8.4  sf-mysql-9.7    MySQL targets      127.0.0.1:33057 33080 33084 33097
  sf-pg-15      sf-pg-16      sf-pg-17      sf-pg-18        PostgreSQL targets 127.0.0.1:54315 54316 54317 54318
  sf-store                                                  our own PostgreSQL 127.0.0.1:54300

Every MySQL runs with its event scheduler off, so no event it holds ever runs. PostgreSQL 18 counts everything
(track_functions all, pg_stat_statements, io timing); 15 to 17 keep the defaults, so both paths are tested. Every
target gets the lab's samples (lab/samples) and their workload. Each server keeps its data in a named volume.

Private MySQL baselines (schema-only dumps kept outside the repository) are loaded into every MySQL when
LAB_MYSQL_BASELINE names their files, separated by colons; nothing of them is in the repository.

  python3 lab/setup.py              make the servers that are missing, then load every sample
  python3 lab/setup.py --recreate   remove the lab's servers and their volumes first, then make them all
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
from extract import SOURCE_DB  # noqa: E402  the database a PostgreSQL target's samples live in, never postgres
PW = next(l.split('"')[1] for l in open(os.path.join(ROOT, "engines/mysql/tests/live.rs")) if l.startswith("const ROOT"))

MYSQL = [("5.7", 33057), ("8.0", 33080), ("8.4", 33084), ("9.7", 33097)]
POSTGRES = [("15", 54315), ("16", 54316), ("17", 54317), ("18", 54318)]
STORE = ("sf-store", "18", 54300)


def sh(*args, stdin=None, check=True):
    r = subprocess.run(list(args), input=stdin, capture_output=True, text=True)
    if check and r.returncode:
        raise SystemExit(f"{' '.join(args[:4])}…: {r.stderr.strip()[-300:]}")
    return r


def exists(name):
    return sh("docker", "ps", "-aq", "--filter", f"name=^{name}$").stdout.strip() != ""


def remove(name):
    if exists(name):
        sh("docker", "rm", "-f", "-v", name)
    sh("docker", "volume", "rm", f"{name}-data", check=False)


def mysql_up(version, port):
    name = f"sf-mysql-{version}"
    if not exists(name):
        platform = ["--platform", "linux/amd64"] if version == "5.7" else []
        sh("docker", "run", "-d", "--name", name, "--restart", "unless-stopped", *platform, "-p", f"127.0.0.1:{port}:3306",
           "-v", f"{name}-data:/var/lib/mysql", "-e", f"MYSQL_ROOT_PASSWORD={PW}", f"mysql:{version}", "--event-scheduler=OFF",
           # 8.0 turns binary logging on, and then refuses a function that does not say whether it reads or writes;
           # the servers these schemas come from accept it, so the lab does
           "--log-bin-trust-function-creators=1")
    for _ in range(150):
        if sh("docker", "exec", name, "mysql", "-uroot", f"-p{PW}", "-e", "SELECT 1", check=False).returncode == 0:
            return name
        time.sleep(2)
    raise SystemExit(f"{name} did not answer")


def pg_up(name, version, port):
    if not exists(name):
        sh("docker", "run", "-d", "--name", name, "--restart", "unless-stopped", "-p", f"127.0.0.1:{port}:5432",
           "-v", f"{name}-data:/var/lib/postgresql", "-e", f"POSTGRES_PASSWORD={PW}", f"postgres:{version}-alpine")
    for _ in range(90):
        if sh("docker", "exec", name, "pg_isready", "-U", "postgres", "-q", check=False).returncode == 0:
            time.sleep(1)
            return name
        time.sleep(1)
    raise SystemExit(f"{name} did not answer")


def samples(engine, version):
    d = os.path.join(HERE, "samples", engine)
    mysql = engine == "mysql"
    files = ["shop.sql", "features.sql"] + (["everything.sql"] if engine == "postgresql" else []) + (["features_replica.sql"] if mysql else []) \
        + (["servers.sql"] if mysql else []) + (["servers80.sql"] if mysql and version != "5.7" else []) \
        + (["features57.sql"] if mysql and version == "5.7" else []) \
        + (["accounts.sql"] if mysql else []) + (["accounts80.sql"] if mysql and version != "5.7" else []) \
        + (["features80.sql"] if mysql and version != "5.7" else []) + (["features97.sql"] if mysql and version == "9.7" else []) + ["quoted_names.sql"]
    sql = "".join(open(os.path.join(d, f)).read() + "\n" for f in files)
    if mysql and version in ("5.7", "8.0"):
        sql = sql.replace("DISABLE ON REPLICA", "DISABLE ON SLAVE")
    if engine == "mysql":
        sql += open(os.path.join(ROOT, "engines/mysql/tests/samples/live/workload.sql")).read()
    return sql


def main():
    if "--recreate" in sys.argv:
        for v, _ in MYSQL:
            remove(f"sf-mysql-{v}")
        for v, _ in POSTGRES:
            remove(f"sf-pg-{v}")
        remove(STORE[0])
    baseline = os.environ.get("LAB_MYSQL_BASELINE")
    for v, port in MYSQL:
        name = mysql_up(v, port)
        sh("docker", "exec", name, "mysql", "-uroot", f"-p{PW}", "-e",
           "DROP DATABASE IF EXISTS shop; DROP DATABASE IF EXISTS features; DROP DATABASE IF EXISTS features_js; DROP DATABASE IF EXISTS `Quoted Names`")
        # the server's own objects the samples made, once no table is in them (--force: a server that lacks one moves on)
        sh("docker", "exec", "-i", name, "mysql", "-uroot", f"-p{PW}", "--force", check=False,
           stdin="DROP USER IF EXISTS 'lab_app'@'%', 'lab_ro'@'10.%', 'lab_reader'@'%';\n"
                 "DROP FUNCTION IF EXISTS keyring_key_fetch;\nDROP TABLESPACE ts_shared;\nDROP TABLESPACE ts_small;\nDROP TABLESPACE ts_grow;\n"
                 "DROP SPATIAL REFERENCE SYSTEM IF EXISTS 1000001;\n")
        sh("docker", "exec", "-i", name, "mysql", "-uroot", f"-p{PW}", "--comments", stdin=samples("mysql", v))
        note = ""
        for path in (baseline.split(":") if baseline else []):
            # a table a later version counts too wide is a warning, not a refusal, as the server it came from had it
            # --comments: without it the 5.7 and 8.0 clients strip the comments inside routine and event bodies
            r = sh("docker", "exec", "-i", name, "mysql", "-uroot", f"-p{PW}", "--force", "--comments",
                   stdin="SET SESSION innodb_strict_mode = 0;\n" + open(os.path.expanduser(path)).read(), check=False)
            note += f", a private baseline loaded ({sum(1 for l in r.stderr.splitlines() if l.startswith('ERROR'))} statements refused)"
        print(f"{name}: 127.0.0.1:{port}, events off, lab samples loaded{note}")
    for v, port in POSTGRES:
        name = pg_up(f"sf-pg-{v}", v, port)
        if v == "18":
            on = sh("docker", "exec", name, "psql", "-U", "postgres", "-Atc", "SHOW shared_preload_libraries").stdout.strip()
            if "pg_stat_statements" not in on:
                sh("docker", "exec", name, "psql", "-U", "postgres", "-q", "-c", "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements'",
                   "-c", "ALTER SYSTEM SET track_functions = 'all'", "-c", "ALTER SYSTEM SET track_io_timing = on")
                sh("docker", "restart", name)
                pg_up(name, v, port)
            sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", "DROP EXTENSION IF EXISTS pg_stat_statements")
        # the samples live in their own database; earlier runs left them in postgres, the server's own: gone from there
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", 'DROP SCHEMA IF EXISTS shop, features, audit, "Quoted Names" CASCADE')
        # a subscription is the cluster's to drop before its database; with no slot it drops alone
        sh("docker", "exec", name, "psql", "-U", "postgres", "-d", SOURCE_DB, "-qc", "DROP SUBSCRIPTION IF EXISTS every_sub", check=False)
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", f"DROP DATABASE IF EXISTS {SOURCE_DB} WITH (FORCE)")
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", "DROP ROLE IF EXISTS features_reader")
        # what the every-object sample makes in the cluster, beside its database: its roles and its tablespace
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", "DROP TABLESPACE IF EXISTS every_space")
        for role in ("every_owner", "every_reader"):
            sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", f"DROP ROLE IF EXISTS {role}")
        sh("docker", "exec", name, "sh", "-c", "mkdir -p /var/lib/postgresql/every_space && chown postgres /var/lib/postgresql/every_space")
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", "CREATE TABLESPACE every_space LOCATION '/var/lib/postgresql/every_space'")
        sh("docker", "exec", name, "psql", "-U", "postgres", "-qc", f"CREATE DATABASE {SOURCE_DB}")
        sh("docker", "exec", "-i", name, "psql", "-U", "postgres", "-d", SOURCE_DB, "-q", "-v", "ON_ERROR_STOP=1", stdin=samples("postgresql", v))
        print(f"{name}: 127.0.0.1:{port}, lab samples loaded{', every statistic counted' if v == '18' else ', default statistics'}")
    pg_up(*STORE)
    print(f"{STORE[0]}: 127.0.0.1:{STORE[2]}, our own PostgreSQL {STORE[1]}, empty until a lab script makes its databases")


if __name__ == "__main__":
    main()
