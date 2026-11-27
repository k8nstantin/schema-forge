#!/usr/bin/env python3
"""Removes every container the tools made (named sf-*), with its volumes: what a tool stopped part way leaves behind.
Lists them first; touches nothing else.

  python3 tools/local/cleanup.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sf.store import docker  # noqa: E402


def main():
    names = [n for n in docker("ps", "-a", "--format", "{{.Names}}").stdout.split() if n.startswith("sf-")]
    print(f"  containers the tools left: {', '.join(names) or 'none'}")
    for n in names:
        r = docker("rm", "-f", "-v", n)
        print(f"  {'removed' if r.returncode == 0 else 'FAIL'}  {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
