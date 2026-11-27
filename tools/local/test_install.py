#!/usr/bin/env python3
"""Proves tools/local/install.py on a PostgreSQL 18 server in a container, signed in with a password as a real server
is: it installs clean, then installs again with --fresh clean (twice in a row), each time with its own checks passing.

  python3 tools/local/test_install.py
"""
import os
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
    try:
        for _ in range(240):
            logs = docker("logs", name)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and docker("exec", name, "pg_isready", "-U", "postgres").returncode == 0:
                break
            time.sleep(0.25)
        time.sleep(1)
        with tempfile.TemporaryDirectory() as tmp:
            accounts = os.path.join(tmp, "accounts.env")
            for run, extra in (("first install", []), ("again with --fresh", ["--fresh"]), ("a third time with --fresh", ["--fresh"])):
                out = subprocess.run([sys.executable, os.path.join(HERE, "install.py"), "--port", port, "--user", "postgres", "--accounts-file", accounts, *extra],
                                     capture_output=True, text=True, env=dict(os.environ, SF_ROOT_PASSWORD=password, SF_CONFIRM="DROP"))
                last = (out.stdout.strip().splitlines() or ["(nothing)"])[-1]
                ok = out.returncode == 0 and last.startswith("pass")
                print(f"  {'pass' if ok else 'FAIL'}  {run}: {last}")
                if not ok:
                    print(out.stdout[-1500:], out.stderr[-1500:])
                    bad.append(run)
            mode = oct(os.stat(accounts).st_mode & 0o777)
            print(f"  {'pass' if mode == '0o600' else 'FAIL'}  the accounts file is mode {mode}")
            if mode != "0o600":
                bad.append("accounts file mode")
    finally:
        docker("rm", "-f", "-v", name)
    print(f"{'pass' if not bad else 'FAIL'}  install: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
