"""The schema lock: the SHA-256 of every file that makes up the database's design, in specs/lock.xml.

A design session changes those files and then writes the lock (`--write`); everything else only checks it
(`--check`, run by tools/check.sh), so a file changed outside a design session fails the build, naming the file.
The locked files: every owner's folder (schema/, engines/*/schema, features/*/schema), every owner's card
(owner.toml), the owner template and postgres/manifest.toml.
"""
import glob
import hashlib
import os
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "specs", "lock.xml")
PATTERNS = ["schema/**/*", "engines/*/schema/**/*", "engines/*/owner.toml", "features/*/schema/**/*",
            "features/*/owner.toml", "docs/owner-template/**/*", "postgres/manifest.toml"]


def locked():
    """Every locked file, by its path from the repository's root, with its SHA-256."""
    paths = set()
    for pattern in PATTERNS:
        paths.update(p for p in glob.glob(os.path.join(ROOT, pattern), recursive=True) if os.path.isfile(p))
    return {os.path.relpath(p, ROOT): hashlib.sha256(open(p, "rb").read()).hexdigest() for p in sorted(paths)}


def write():
    now = locked()
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             "<!--",
             "  The schema lock: the SHA-256 of every file that makes up the database's design. Written only in a design",
             "  session, by tools/schema_lock.py with its write option; tools/check.sh refuses any locked file that differs.",
             "-->",
             f'<lock product="SchemaForge" files="{len(now)}">']
    lines += [f'  <file path="{p}" sha256="{h}"/>' for p, h in now.items()]
    lines += ["</lock>", ""]
    open(LOCK, "w", encoding="utf-8").write("\n".join(lines))
    print(f"specs/lock.xml: {len(now)} files locked")


def check():
    want = {f.get("path"): f.get("sha256") for f in ET.parse(LOCK).getroot().findall("file")}
    now = locked()
    wrong = [f"{p}: changed outside a design session" for p in sorted(want) if p in now and now[p] != want[p]]
    wrong += [f"{p}: locked, and gone" for p in sorted(want) if p not in now]
    wrong += [f"{p}: not locked; a design session adds it and writes the lock" for p in sorted(now) if p not in want]
    for w in wrong:
        print(w)
    print(f"schema lock: {len(now)} files, {len(wrong)} differ")
    return 1 if wrong else 0


if __name__ == "__main__":
    if "--write" in sys.argv:
        write()
    else:
        sys.exit(check())
