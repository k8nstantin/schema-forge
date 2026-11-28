#!/usr/bin/env python3
"""Lists the Docker containers on this machine, running or stopped, with their image, state and published ports; changes
nothing. Use it to find the long-lived test servers (sf-mysql-*) before pointing a tool at one.

  python3 tools/local/containers.py [--all]

--all also lists the stopped ones.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.store import docker  # noqa: E402


def main():
    args = ["ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"]
    if "--all" in sys.argv[1:]:
        args.insert(1, "-a")
    r = docker(*args)
    if r.returncode:
        print(f"FAIL  docker: {r.stderr.strip()}")
        return 1
    lines = sorted(l for l in r.stdout.splitlines() if l.strip())
    for line in lines:
        print("  " + line)
    print(f"{len(lines)} containers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
