#!/usr/bin/env python3
"""Every proof of engine_mysql, in order: it plugs in (tools/mysql/load.py), and the round trip (tools/mysql/roundtrip.py,
with the store) on every version and flavor that has a server: MySQL 5.7, 8.0, 8.4, 9.7 and Percona Server 5.7, 8.0,
8.4; the old MySQL schemas where they are (private: counts only); then the flavors that have no server to run
(tools/mysql/flavors.py). CI runs this on every pull request.

  python3 tools/mysql/all.py [--only mysql:8.0,percona/percona-server:8.4] [--no-store]
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PRIVATE = os.path.expanduser("~/schema-forge-lab-private")
SERVERS = ["mysql:5.7", "mysql:8.0", "mysql:8.4", "mysql:9.7",
           "percona/percona-server:5.7", "percona/percona-server:8.0", "percona/percona-server:8.4"]
ARGS = sys.argv[1:]


def main():
    only = ARGS[ARGS.index("--only") + 1].split(",") if "--only" in ARGS else None
    runs = [("load", [os.path.join(HERE, "load.py")])] if not only else []
    for s in (only or SERVERS):
        runs.append((f"round trip {s}", [os.path.join(HERE, "roundtrip.py"), "--server", s] + ([] if "--no-store" in ARGS else ["--store"])))
    # the old MySQL schemas: private, never committed, run where they are (counts only, never a name)
    for name, server, opts in (("mysql-baseline.sql", "mysql:5.7", []), ("mysql-baseline.sql", "mysql:8.0", ["--option", "--innodb-strict-mode=OFF"]),
                               ("mysql-baseline-2.sql", "mysql:8.0", ["--option", "--innodb-strict-mode=OFF"])):
        path = os.path.join(PRIVATE, name)
        if not only and os.path.exists(path):
            runs.append((f"private {name} on {server}", [os.path.join(HERE, "roundtrip.py"), "--server", server, "--store", "--private", "--sample", path, *opts]))
    if not only and os.path.exists(os.path.join(HERE, "flavors.py")):
        runs.append(("flavors", [os.path.join(HERE, "flavors.py")]))
    results = []
    for name, cmd in runs:
        start = time.time()
        print(f"== {name}", flush=True)
        r = subprocess.run([sys.executable, *cmd])
        results.append((name, r.returncode, time.time() - start))
    print("\n== engine_mysql")
    for name, rc, s in results:
        print(f"  {'pass' if rc == 0 else 'FAIL'}  {name:42} {s:6.1f} s")
    failed = [n for n, rc, _ in results if rc]
    print(f"{'pass' if not failed else 'FAIL'}  engine_mysql: {len(results) - len(failed)} of {len(results)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
