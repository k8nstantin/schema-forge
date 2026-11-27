#!/usr/bin/env python3
"""Everything that must pass before a change is called done, in one command: the same here and in CI (specs/rules.xml
one-check). Each part runs when what it checks exists, so a part an objective adds joins on its own. The container
proofs of each objective are their own tool (tools/cortex/all.py), run by CI beside this one.

  python3 tools/check.py
"""
import glob
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRIVATE = r"core_manager|core_services|gdx_services|mq_services|sec_testdb|cr_debug|piaalcm|piaclws|GDXClients|ClientKey"
NAMED_MD = {"README.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"}
GENERATED = ["site", "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"]


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout


def step(name):
    print(f"\n== {name}", flush=True)


def fail(msg):
    print(msg)
    print("\nFAIL  tools/check.py")
    sys.exit(1)


class Page(HTMLParser):
    """A page's ids, its links to #anchors, and its links to the site's own pages that open a new tab."""

    def __init__(self):
        super().__init__()
        self.ids, self.anchors, self.new_tab = [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.append(a["id"])
        href = a.get("href") or ""
        if tag == "a" and href.startswith("#") and len(href) > 1:
            self.anchors.append(href[1:])
        if tag == "a" and a.get("target") == "_blank" and (href.endswith(".html") or href.startswith("#")) and not href.startswith("http"):
            self.new_tab.append(href)


def site_problems():
    out = []
    for path in sorted(glob.glob(os.path.join(ROOT, "site", "*.html"))):
        p = Page()
        p.feed(open(path, encoding="utf-8").read())
        name = os.path.relpath(path, ROOT)
        seen = set()
        for i in p.ids:
            if i in seen:
                out.append(f"{name}: the id {i} is used twice")
            seen.add(i)
        out += [f"{name}: #{a} names no id on the page" for a in sorted(set(p.anchors)) if a not in seen]
        out += [f"{name}: {h} opens a page of the site in a new tab" for h in sorted(set(p.new_tab))]
    return out


def main():
    if os.path.exists(os.path.join(ROOT, "Cargo.toml")):
        step("Rust: format, lint, tests")
        for cmd in (["cargo", "fmt", "--all", "--check"], ["cargo", "clippy", "--workspace", "--all-targets", "--all-features", "--quiet", "--", "-D", "warnings"],
                    ["cargo", "test", "--workspace", "--all-features", "--quiet"]):
            if subprocess.run(cmd, cwd=ROOT).returncode:
                fail(f"{' '.join(cmd)} failed")

    step("No private name in any tracked file")
    hits = git("grep", "-nIiE", PRIVATE, "--", ".", ":!site", ":!tools/check.py")
    if hits:
        fail(hits + "a private name is in a tracked file")
    print("none")

    step("XML for everything: Markdown only where a tool looks for it by name (specs/root.xml, decision xml-for-agents)")
    files = git("ls-files", "--cached", "--others", "--exclude-standard").split("\n")
    stray = [f for f in files if f.endswith(".md") and f not in NAMED_MD]
    mentions = [m for m in git("grep", "-nIoE", r"[A-Za-z0-9_./-]+\.md([^A-Za-z0-9_]|$)", "--", ".", ":!site", ":!specs/reviews").splitlines()
                if not re.search(r":([A-Za-z0-9_./-]*/)?(README|CONTRIBUTING|CODE_OF_CONDUCT|CHANGELOG|AGENTS|CLAUDE|copilot-instructions)\.md([^A-Za-z0-9_]|$)", m)]
    if stray or mentions:
        fail("\n".join([f"a Markdown file a tool does not look for: {s}" for s in stray] + [f"names a Markdown file: {m}" for m in mentions])
             + "\nwrite it as XML (docs/*.xml, rendered for people by docs/pages/docs.py) and name that")
    for f in files:
        if f.endswith(".xml") and os.path.exists(os.path.join(ROOT, f)):
            try:
                ET.parse(os.path.join(ROOT, f))
            except ET.ParseError as e:
                fail(f"{f}: not XML ({e})")
    print("no stray Markdown; every XML file parses")

    step("Generated files: the pages, the site and the agent files are what their sources render")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "build_site.py")], cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        fail(r.stdout[-800:] + r.stderr[-800:])
    changed = git("status", "--porcelain", "--", *GENERATED)
    if changed:
        fail(changed + "these differ from what specs/, the owners' folders and docs/pages render: run python3 tools/build_site.py and commit them")
    print("every generated file is current")

    step("The site's pages: every id unique, every #anchor found on its page, no page of the site opened in a new tab")
    problems = site_problems()
    if problems:
        fail("\n".join(problems[:20]))
    print(f"{len(glob.glob(os.path.join(ROOT, 'site', '*.html')))} pages: none")

    step("All checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
