#!/usr/bin/env python3
"""Proves the agent's guard hooks of this checkout do what they say: the tools-only gate (no ad-hoc command, no old
work copied back) and the claims check (no "done" without the proof). Each case feeds a hook the input Claude Code
gives it and compares the decision.

  python3 tools/local/test_hooks.py
"""
import json
import os
import subprocess
import sys
import tempfile

HOOKS = os.path.expanduser("~/.claude/hooks")
GATE = os.path.join(HOOKS, "schema-forge-tools-only.py")
CLAIMS = os.path.join(HOOKS, "schema-forge-no-false-claims.py")

GATE_CASES = [
    ("tools/check.sh", "allow"),
    ("python3 tools/local/proof.py --pg 18", "allow"),
    ("git status --short && gh pr list", "allow"),
    ("ls schema | grep sql", "allow"),
    ("git checkout -q -b cortex-optimal", "allow"),
    ("docker ps", "deny"),
    ("python3 -c 'print(1)'", "deny"),
    ("rm -rf schema", "deny"),
    ("psql -c 'select 1'", "deny"),
    ("cat x <<EOF", "deny"),
    ("sed -i '' s/a/b/ README.md", "deny"),
    ("git " + "checkout 36a953b -- schema", "deny"),
    ("git show 36a953b:schema/dump/schema_forge.sql > schema/x.sql", "deny"),
    ("git show 36a953b:schema/dump/schema_forge.sql > ~/schema-forge-lab-private/old.sql", "allow"),
]


def decide(hook, payload):
    r = subprocess.run([sys.executable, hook], input=json.dumps(payload), capture_output=True, text=True)
    out = r.stdout.strip()
    if not out:
        return "allow", ""
    d = json.loads(out)
    if d.get("decision") == "block":
        return "block", d.get("reason", "")
    return (d.get("hookSpecificOutput") or {}).get("permissionDecision", "allow"), out


def main():
    bad = 0
    for cmd, want in GATE_CASES:
        got, _ = decide(GATE, {"tool_input": {"command": cmd}})
        ok = got == want
        bad += not ok
        print(f"  {'pass' if ok else 'FAIL'}  gate {want:5}  {cmd}" + ("" if ok else f"  (got {got})"))
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on the table list."}]}}) + "\n")
    got, _ = decide(CLAIMS, {"transcript_path": f.name})
    ok = got == "allow"
    bad += not ok
    print(f"  {'pass' if ok else 'FAIL'}  claims: a message that claims nothing stops freely")
    os.unlink(f.name)
    print(f"{'pass' if not bad else 'FAIL'}  hooks: {bad} findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
