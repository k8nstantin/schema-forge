"""Start here: what the product is, how the pack and a build fit together, the repository and the tools that prove each
part, and where each objective of the sequence stands."""
import json, os, subprocess, xml.etree.ElementTree as ET
from common import REPO, Svg, database, e, links, page

root = ET.parse(f"{REPO}/specs/root.xml").getroot()
seq = root.find("sequence").findall("task")
db, edges = database()
L = links()

# --- the repository: what is built, and the tools that prove each part; every box opens its folder ----------------------
from common import REPO_URL  # noqa: E402
TREE = f"{REPO_URL}/tree/main"
g = Svg(1040, 400, "The repository: the cortex and each engine plugin as schema files, the tools that prove each part, and the spec they all fall into.")
g.band(10, 10, 500, 250, "what is built: the database")
g.band(530, 10, 500, 250, "what proves it: a tool for every check")
parts = [("cortex", 40, 50, "schema/cortex", "21 tables, the plugs", "pri"), ("mysql", 40, 150, "engines/mysql", "24 tables, reader, writer", "eng"),
         ("tc", 560, 40, "tools/cortex", "load, ids, dump, history", "lg"), ("tm", 560, 110, "tools/mysql", "round trip, flavors", "lg"),
         ("tsf", 560, 180, "tools/sf", "store, servers, plug-in", "lg"),
         ("specs", 40, 300, "specs", "root, rules, brief", "box"), ("docs", 300, 300, "docs", "designs and this site", "box"),
         ("ci", 560, 300, ".github/workflows", "CI runs every tool", "box"), ("check", 800, 300, "tools/check.py", "the repo check", "box")]
for k, x, y, t, s, c in parts:
    g.box(k, x, y, 220, 56, t, s, cls=c, href=f"{TREE}/{t}")
g.arrow("tc", "cortex", "proves")
g.arrow("tm", "mysql", "proves")
g.arrow("mysql", "cortex", "plugs into", lx=-58)
g.containers = set()
crates_svg = g.render()

# --- how a build happens -----------------------------------------------------------------------------------------
g = Svg(1040, 210, "From a design session to a merged build: the spec and the issue, a new session pointed at the task file, its branch, its gates, its pull request, the operator's merge.")
steps = [("design", "design session", "spec, reviewed"), ("issue", "GitHub issue", "SF-<n>"),
         ("kick", "a new session", "one line: its file"), ("branch", "its branch", "SF-<n>-…-<model>"),
         ("gates", "its gates", "check.py, its tools"), ("pr", "pull request", "gates, hand-off"),
         ("merge", "the operator", "reviews, merges")]
for i, (k, t, s) in enumerate(steps):
    g.box(k, 12 + i * 147, 70, 130, 54, t, s, cls="pri" if k in ("kick", "merge") else "box")
for a, b in zip(steps, steps[1:]):
    g.arrow(a[0], b[0])
g.text(12, 40, "a silence in the files or a failing gate is a stop: the pull request says which element, and a design session fixes the spec", "lb")
g.text(12, 170, "one session, one agent; no attribution; nothing outside the files the task owns; the next task starts from main once this one is merged", "lb")
flow_svg = g.render()

# --- the pack ----------------------------------------------------------------------------------------------------
g = Svg(1040, 190, "The pack is built from the repository: the schema folders and specs/ are the source; the pages are generated from them.")
g.box("schema", 20, 30, 220, 50, "schema folders", "schema/, engines/*/schema", cls="pri")
g.box("specs", 20, 110, 220, 50, "specs/", "root, rules, tasks, reviews", cls="pri")
g.box("build", 380, 70, 200, 50, "docs/pages/build.py", "reads, never writes them")
for i, (k, name) in enumerate([("home", "Start here"), ("engines", "Engines"), ("build-spec", "Build Spec")]):
    g.box(k, 720, 20 + i * 56, 200, 44, name, cls="box")
g.arrow("schema", "build"); g.arrow("specs", "build")
for k in ("home", "engines", "build-spec"): g.arrow("build", k)
pack_svg = g.render()

ntab = sum(len(d["tables"]) for d in db.values())
rows = "".join(
    f'<tr><td><code>{e(t.get("id"))}</code></td><td>{e(t.get("name"))}</td>'
    f'<td>{f"<a href=\"%REPO%/issues/{t.get(chr(107)+chr(101)+chr(121))[3:]}\" target=\"_blank\" rel=\"noopener\">{e(t.get(chr(107)+chr(101)+chr(121)))}</a>" if t.get("key") else "<span class=small>no issue yet</span>"}</td>'
    f'<td><span class="pill open">due {e(t.get("eta") or "")}</span></td>'
    f'<td class="small">{e(t.get("builds"))}</td></tr>' for t in seq)
body = f"""
<div class="tb" role="group" aria-label="Title block">
  <div><span>Product</span><b>%PRODUCT%</b></div><div><span>Repository</span><b><a href="%REPO%" target="_blank" rel="noopener">GitHub</a></b></div>
  <div><span>Spec</span><b>root v{e(root.get("version"))} · the rebuild</b></div><div><span>Objectives</span><b>{len(seq)}, in order</b></div><div><span>Date</span><b>{e(root.get("date"))}</b></div>
</div>
<h1>%PRODUCT% <span class="draft">The rebuild</span></h1>
<p class="lede">{e(" ".join("".join(root.find("identity").find("product").itertext()).split()))}</p>
<div class="go">
  <a class="tile" href="{L.get('database', '#')}" target="_blank" rel="noopener"><b>Database</b><span>Every table of the cortex, the workspace and each engine: diagrams of every foreign key, then each table with its columns, keys and file.</span></a>
  <a class="tile" href="{L.get('build-spec', '#')}" target="_blank" rel="noopener"><b>Build Spec</b><span>The root, the rules, every task file a coding agent builds from, the decisions, and the review with every defect found.</span></a>
  <a class="tile" href="%REPO%/issues/138" target="_blank" rel="noopener"><b>The objectives</b><span>Six, in order, each an issue with its ETA, its own branch and PR: #138, #139, #140, #141, #145, #146.</span></a>
</div>
<section id="stands"><h2>Where it stands</h2><p class="lede">The foundation is on main: the model, the engine interface with its kit, and the MySQL engine (pull request #89). Next is the sequence below, built one task at a time once the spec is merged.</p>
<div class="scroll"><table class="t"><thead><tr><th>Task</th><th>What</th><th>Issue</th><th>State</th><th>Builds</th></tr></thead><tbody>{rows}</tbody></table></div></section>
<section id="flow"><h2>How a build happens</h2><figure>{flow_svg}<figcaption>The method of specs/root.xml, end to end. A build reads only the merged code and the spec; whatever they do not say is a stop, never a guess.</figcaption></figure></section>
<section id="crates"><h2>The repository</h2><figure>{crates_svg}<figcaption>Every box opens its folder. Every check is a tool in the repository, never an ad-hoc command, and CI runs them all on every pull request.</figcaption></figure></section>
<section id="pack"><h2>This pack</h2><figure>{pack_svg}<figcaption>Nothing on these pages is typed by hand but prose: every table, column, rule, task and defect is read from the files. A change is made in the repository and the pages built again.</figcaption></figure></section>
"""
CSS = """
.go{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;margin:18px 0 0}
.tile{display:flex;flex-direction:column;gap:4px;background:var(--surface);border:1.5px solid var(--line);border-radius:10px;padding:14px 16px;text-decoration:none;color:var(--ink)}
.tile:hover{border-color:var(--accent)}.tile b{font:700 21px var(--head)}.tile span{font-size:14px;color:var(--ink2)}
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("stands", "Where it stands"), ("flow", "How a build happens"), ("crates", "The repository"), ("pack", "This pack")])
HTML = page("home", "%PRODUCT%", CSS, body, sub)
