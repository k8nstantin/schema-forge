"""Start here: what the product is, how the pack and a build fit together, the crates as cargo knows them, and where
each task of the sequence stands."""
import json, os, subprocess, xml.etree.ElementTree as ET
from common import REPO, Svg, database, e, links, page

root = ET.parse(f"{REPO}/specs/root.xml").getroot()
seq = root.find("sequence").findall("task")
db, edges = database()
L = links()

# --- the crates, as cargo knows them ----------------------------------------------------------------------------------
meta = json.loads(subprocess.run(["cargo", "metadata", "--format-version", "1", "--no-deps"], cwd=REPO, capture_output=True, text=True, check=True).stdout)
crates = []
for p in meta["packages"]:
    role = (p.get("metadata") or {}).get("schema-forge", {}).get("role", "?")
    crates.append((role, p["name"], os.path.relpath(os.path.dirname(p["manifest_path"]), REPO)))
planned = [(t.get("builds"), t.get("id"), t.get("key")) for t in seq]
ROLES = [("model", "the skeleton every engine shares"), ("interface", "the engine interface, the layout, the kit"),
         ("engine", "one crate per database"), ("registry", "the engines shipped"), ("app", "the store, the server, the command line"),
         ("tool", "checks of the code itself")]
shown = set()
g = Svg(1040, 60 + 64 * len(ROLES), "The crates of the workspace by role, as cargo metadata gives them, and the ones the sequence builds.")
y = 20
for role, says in ROLES:
    have = sorted(n for r, n, d in crates if r == role)
    g.text(20, y + 26, role, "cap"); g.text(20, y + 42, says, "lb")
    x = 300
    for n in have:
        w = 22 + 7.6 * len(n); g.box(n, x, y + 8, w, 36, n, cls="pri"); x += w + 12
    for b, tid, key in planned:
        for path in (b or "").split():
            if path in shown: continue
            want = {"engine": path.startswith("engines/") and path.count("/") == 1, "registry": path == "crates/engines",
                    "app": path in ("crates/store", "crates/serve"), "tool": path == "tools/specs"}.get(role, False)
            if want:
                shown.add(path); nm = f"{path}  ({key or tid})"; w = 22 + 7.6 * len(nm)
                g.box(nm, x, y + 8, w, 36, nm, cls="band"); x += w + 12
    y += 64
g.text(20, y + 20, "filled: on main today · dashed: built by the task named · an app asks the registry, never one engine (tools/architecture)", "lb")
crates_svg = g.render()

# --- how a build happens -----------------------------------------------------------------------------------------
g = Svg(1040, 210, "From a design session to a merged build: the spec and the issue, a new session pointed at the task file, its branch, its gates, its pull request, the operator's merge.")
steps = [("design", "design session", "spec, reviewed"), ("issue", "GitHub issue", "SF-<n>"),
         ("kick", "a new session", "one line: its file"), ("branch", "its branch", "SF-<n>-…-<model>"),
         ("gates", "its gates", "check.sh, its own"), ("pr", "pull request", "gates, hand-off"),
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
for i, (k, name) in enumerate([("home", "Start here"), ("database", "Database"), ("build-spec", "Build Spec")]):
    g.box(k, 720, 20 + i * 56, 200, 44, name, cls="box")
g.arrow("schema", "build"); g.arrow("specs", "build")
for k in ("home", "database", "build-spec"): g.arrow("build", k)
pack_svg = g.render()

ntab = sum(len(d["tables"]) for d in db.values())
rows = "".join(
    f'<tr><td><code>{e(t.get("id"))}</code></td><td>{e(t.get("name"))}</td>'
    f'<td>{f"<a href=\"%REPO%/issues/{t.get(chr(107)+chr(101)+chr(121))[3:]}\" target=\"_blank\" rel=\"noopener\">{e(t.get(chr(107)+chr(101)+chr(121)))}</a>" if t.get("key") else "<span class=small>no issue yet</span>"}</td>'
    f'<td>{"<span class=\"pill ok\">spec written · not built</span>" if t.get("file") else "<span class=\"pill open\">spec not written</span>"}</td>'
    f'<td class="small">{e(t.get("builds"))}</td></tr>' for t in seq)
body = f"""
<div class="tb" role="group" aria-label="Title block">
  <div><span>Product</span><b>%PRODUCT%</b></div><div><span>Repository</span><b><a href="%REPO%" target="_blank" rel="noopener">GitHub</a></b></div>
  <div><span>Spec</span><b>Draft 1 · PR #92</b></div><div><span>Database</span><b>{ntab} tables</b></div><div><span>Date</span><b>{e(root.get("date"))}</b></div>
</div>
<h1>%PRODUCT% <span class="draft">Draft 1</span></h1>
<p class="lede">{e(" ".join("".join(root.find("identity").find("product").itertext()).split()))}</p>
<div class="go">
  <a class="tile" href="{L.get('database', '#')}" target="_blank" rel="noopener"><b>Database</b><span>Every table of the cortex, the workspace and each engine: diagrams of every foreign key, then each table with its columns, keys and file.</span></a>
  <a class="tile" href="{L.get('build-spec', '#')}" target="_blank" rel="noopener"><b>Build Spec</b><span>The root, the rules, every task file a coding agent builds from, the decisions, and the review with every defect found.</span></a>
  <a class="tile" href="%REPO%/pull/92" target="_blank" rel="noopener"><b>Pull request #92</b><span>The one branch the spec lives on while it is a draft: review it there.</span></a>
</div>
<section id="stands"><h2>Where it stands</h2><p class="lede">The foundation is on main: the model, the engine interface with its kit, and the MySQL engine (pull request #89). Next is the sequence below, built one task at a time once the spec is merged.</p>
<div class="scroll"><table class="t"><thead><tr><th>Task</th><th>What</th><th>Issue</th><th>State</th><th>Builds</th></tr></thead><tbody>{rows}</tbody></table></div></section>
<section id="flow"><h2>How a build happens</h2><figure>{flow_svg}<figcaption>The method of specs/root.xml, end to end. A build reads only the merged code and the spec; whatever they do not say is a stop, never a guess.</figcaption></figure></section>
<section id="crates"><h2>The crates</h2><figure>{crates_svg}<figcaption>Read from cargo metadata, each crate's declared role; tools/architecture fails the build when a crate depends the wrong way or names a database outside its engine.</figcaption></figure></section>
<section id="pack"><h2>This pack</h2><figure>{pack_svg}<figcaption>Nothing on these pages is typed by hand but prose: every table, column, rule, task and defect is read from the files. A change is made in the repository and the pages built again.</figcaption></figure></section>
"""
CSS = """
.go{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;margin:18px 0 0}
.tile{display:flex;flex-direction:column;gap:4px;background:var(--surface);border:1.5px solid var(--line);border-radius:10px;padding:14px 16px;text-decoration:none;color:var(--ink)}
.tile:hover{border-color:var(--accent)}.tile b{font:700 21px var(--head)}.tile span{font-size:14px;color:var(--ink2)}
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("stands", "Where it stands"), ("flow", "How a build happens"), ("crates", "The crates"), ("pack", "This pack")])
HTML = page("home", "%PRODUCT%", CSS, body, sub)
