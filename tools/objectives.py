#!/usr/bin/env python3
"""Keeps the objectives' state honest: each task of specs/root.xml's sequence says its state (done, open or next) and
the pull requests that delivered it; this compares them with GitHub. A task done must have its issue closed and every
pull request it names merged; a task open or next must have its issue open. Every page that shows the objectives reads
them from the spec, so this check is what keeps those pages true. It needs gh, signed in (CI has it); without gh it
says so and checks nothing.

  python3 tools/objectives.py
"""
import json
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "k8nstantin/schema-forge"


def gh(*args):
    r = subprocess.run(["gh", *args, "-R", REPO], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"gh {' '.join(args)}: {r.stderr.strip()[:200]}")
    return json.loads(r.stdout)


def main():
    if not shutil.which("gh"):
        print("note  gh is not here: the objectives' state is not checked")
        return 0
    bad = []
    tasks = ET.parse(os.path.join(ROOT, "specs", "root.xml")).getroot().find("sequence").findall("task")
    for t in tasks:
        issue = t.get("key", "SF-")[3:]
        state = t.get("state")
        real = gh("issue", "view", issue, "--json", "state")["state"]
        want = "CLOSED" if state == "done" else "OPEN"
        ok = real == want
        prs = [(p, gh("pr", "view", p, "--json", "state")["state"]) for p in (t.get("prs") or "").split()]
        unmerged = [p for p, s in prs if s != "MERGED"]
        if state == "done" and not prs:
            unmerged = ["(none named)"]
        print(f"  {'pass' if ok and not unmerged else 'FAIL'}  {t.get('id')} {t.get('name')}: the spec says {state}; issue #{issue} is {real.lower()}"
              + (f"; pull requests {', '.join('#' + p for p, _ in prs)} merged" if prs and not unmerged else "")
              + (f"; not merged: {', '.join(unmerged)}" if unmerged else ""))
        if not ok or unmerged:
            bad.append(t.get("id"))
    print(f"{'pass' if not bad else 'FAIL'}  objectives: {len(bad)} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
