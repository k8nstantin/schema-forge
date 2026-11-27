#!/usr/bin/env python3
"""Proves tools/local/install.py the way the DBA runs it, on a PostgreSQL 18 server in a container signed into with a
password, holding an earlier install (the old schema_forge and its sf_ roles), as the DBA's server does:

  1. without --fresh it stops and changes nothing: no role made, the old database still there
  2. run by a user who is not a superuser, it stops and changes nothing
  3. with --fresh it drops the old install, installs the cortex and every engine, and locks in: 0 findings
  4. with --fresh again, the same: 0 findings
  and the accounts file is mode 600, with a password for every service account

  python3 tools/local/test_install.py
"""
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.store import IMAGE, docker  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return str(s.getsockname()[1])


def main():
    name, port, password = f"sf-install-{os.getpid()}", free_port(), secrets.token_urlsafe(24)
    r = docker("run", "-d", "--name", name, "-p", f"127.0.0.1:{port}:5432", "-e", f"POSTGRES_PASSWORD={password}", IMAGE)
    if r.returncode:
        raise SystemExit(f"docker run: {r.stderr.strip()}")
    bad = []

    def check(ok, what, out=""):
        print(f"  {'pass' if ok else 'FAIL'}  {what}")
        if not ok:
            print(out[-2000:])
            bad.append(what)

    def psql(sql):
        return docker("exec", "-i", name, "psql", "-U", "postgres", "-At", "-v", "ON_ERROR_STOP=1", stdin=sql)

    try:
        for _ in range(240):
            logs = docker("logs", name)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and docker("exec", name, "pg_isready", "-U", "postgres").returncode == 0:
                break
            time.sleep(0.25)
        time.sleep(1)
        # an earlier install, as the DBA's server holds one: the old database owned by the old roles
        psql("CREATE ROLE sf_owner NOLOGIN; CREATE ROLE sf_service LOGIN; CREATE ROLE sf_reader LOGIN; CREATE DATABASE schema_forge OWNER sf_owner;")
        psql("\\c schema_forge\nCREATE SCHEMA cortex AUTHORIZATION sf_owner; CREATE TABLE cortex.old (id bigint); GRANT SELECT ON cortex.old TO sf_reader;")
        psql("CREATE ROLE not_super LOGIN PASSWORD 'not-super-1';")
        with tempfile.TemporaryDirectory() as tmp:
            accounts = os.path.join(tmp, "accounts.env")

            def install(*extra, user="postgres", pw=password):
                return subprocess.run([sys.executable, os.path.join(HERE, "install.py"), "--port", port, "--user", user, "--accounts-file", accounts, *extra],
                                      capture_output=True, text=True, env=dict(os.environ, SF_ROOT_PASSWORD=pw, SF_CONFIRM="DROP"))
            out = install()
            made = psql("SELECT count(*) FROM pg_roles WHERE rolname LIKE 'cortex%' OR rolname LIKE 'engine%';").stdout.strip()
            old = psql("SELECT count(*) FROM pg_database WHERE datname = 'schema_forge';").stdout.strip()
            check(out.returncode != 0 and "run with --fresh" in out.stdout + out.stderr and made == "0" and old == "1",
                  "over an earlier install, without --fresh: stops, changes nothing", out.stdout + out.stderr)
            out = install(user="not_super", pw="not-super-1")
            check(out.returncode != 0 and "not a superuser" in out.stdout + out.stderr, "run by a user who is not a superuser: stops, changes nothing",
                  out.stdout + out.stderr)
            for run in ("with --fresh, over the earlier install", "with --fresh again"):
                out = install("--fresh")
                last = (out.stdout.strip().splitlines() or ["(nothing)"])[-1]
                check(out.returncode == 0 and last.startswith("pass") and "pass  locked in" in out.stdout, f"{run}: {last}", out.stdout + out.stderr)
            for line in out.stdout.splitlines():
                if "signs in" in line or "locked in" in line or "plugged in" in line:
                    print(f"    {line.strip()}")
            mode = oct(os.stat(accounts).st_mode & 0o777)
            names = re.findall(r"^([A-Z_]+)_PASSWORD=", open(accounts).read(), re.M)
            check(mode == "0o600" and set(names) >= {"CORTEX_SERVICE", "CORTEX_AGENT", "CORTEX_READER", "ENGINE_MYSQL_SERVICE"},
                  f"the accounts file is mode {mode}, with {len(names)} service accounts' passwords")
            old_roles = psql("SELECT count(*) FROM pg_roles WHERE rolname LIKE 'sf\\_%';").stdout.strip()
            check(old_roles == "0", f"the earlier install's sf_ roles are gone ({old_roles} left)")
    finally:
        docker("rm", "-f", "-v", name)
    print(f"{'pass' if not bad else 'FAIL'}  install: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
