#!/usr/bin/env python3
"""The licence of every crate the app depends on, from cargo metadata (Cargo.lock), and whether the licences allowed
cover it: an SPDX expression is covered when it can be satisfied with the allowed licences alone (A OR B needs one of
them, A AND B needs both). Prints the crates not covered, each with its expression; the workspace's own crates aside.

  python3 tools/app/licences.py [--allow LICENCE ...]

--allow defaults to the allow list of deny.toml.
"""
import json
import os
import re
import subprocess
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def covered(expr, allowed):
    """Whether an SPDX expression is satisfied with the allowed licences alone (WITH exceptions read as one licence)."""
    tokens = re.findall(r"\(|\)|[A-Za-z0-9.+-]+(?: WITH [A-Za-z0-9.+-]+)?", expr.replace("/", " OR "))
    pos = 0

    def atom():
        nonlocal pos
        t = tokens[pos]
        pos += 1
        if t == "(":
            v = any_of()
            pos += 1  # ")"
            return v
        return t in allowed

    def all_of():
        nonlocal pos
        v = atom()
        while pos < len(tokens) and tokens[pos] == "AND":
            pos += 1
            v = atom() and v
        return v

    def any_of():
        nonlocal pos
        v = all_of()
        while pos < len(tokens) and tokens[pos] == "OR":
            pos += 1
            v = all_of() or v
        return v

    return any_of()


def main():
    args = sys.argv[1:]
    if "--allow" in args:
        allowed = set(args[args.index("--allow") + 1:])
    else:
        allowed = set(tomllib.load(open(os.path.join(ROOT, "deny.toml"), "rb"))["licenses"]["allow"])
    r = subprocess.run(["cargo", "metadata", "--format-version", "1", "--locked"], cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        print(r.stderr)
        return 1
    meta = json.loads(r.stdout)
    ours = set(meta["workspace_members"])
    used = {p["id"] for p in meta["resolve"]["nodes"]}
    crates = [p for p in meta["packages"] if p["id"] in used and p["id"] not in ours]
    out = sorted((p["name"], p["version"], p.get("license") or "(none)") for p in crates if not covered(p.get("license") or "", allowed))
    print(f"== {len(crates)} crates the app depends on, against: {', '.join(sorted(allowed))}")
    for name, version, lic in out:
        print(f"  not covered  {name} {version}: {lic}")
    print(f"{'pass' if not out else 'FAIL'}  licences: {len(crates) - len(out)} of {len(crates)} crates covered")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
