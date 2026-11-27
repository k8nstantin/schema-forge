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

# --- where it stands: every objective, its state and pull requests from the spec (kept true by tools/objectives.py) -----
PILL = {"done": ("ok", "done"), "open": ("open", "open"), "next": ("next", "next")}


def state_cell(t):
    cls, word = PILL.get(t.get("state"), ("open", t.get("state") or "?"))
    prs = " ".join(f'<a href="%REPO%/pull/{p}">#{p}</a>' for p in (t.get("prs") or "").split())
    return f'<span class="pill {cls}">{word}</span>' + (f' <span class="small">{prs}</span>' if prs else f' <span class="small">due {e(t.get("eta") or "")}</span>')


rows = "".join(
    f'<tr><td><code>{e(t.get("id"))}</code></td><td>{e(t.get("name"))}<div class="small">{e(t.get("title"))}</div></td>'
    f'<td><a href="%REPO%/issues/{e(t.get("key", "SF-")[3:])}">#{e(t.get("key", "SF-")[3:])}</a></td><td>{state_cell(t)}</td></tr>' for t in seq)
done = sum(1 for t in seq if t.get("state") == "done")
first_open = next((t for t in seq if t.get("state") != "done"), None)
body = f"""
<header class="hero">
  <p class="eyebrow">Start here</p>
  <h1>%PRODUCT%</h1>
  <p>An open-source schema design and management tool where you and your coding agent work on the same live design.</p>
  <p>It is built on two full-feature engines, MySQL and PostgreSQL, and every managed service or compatible database (RDS, Cloud SQL, Aurora,
  Percona, AlloyDB, TiDB, Spanner, CockroachDB) is a subset that falls into one of them.</p>
  <p>Everything it knows of a design is rows of one PostgreSQL 18 database, kept consistent by the database itself.</p>
  <div class="btns"><a class="btn btn-primary" href="#try">Try it</a><a class="btn btn-secondary" href="{L.get('engines', '#')}">The engines</a>
  <a class="btn btn-secondary" href="{L.get('database', '#')}">The database</a></div>
</header>

<section id="stands"><p class="kicker">Where it stands</p><h2>{done} of {len(seq)} objectives done{f"; next: {e(first_open.get('name'))}" if first_open else ""}.</h2>
<p class="lede">The product is being rebuilt from its spec, one objective at a time, each its own issue and pull request. What is built today is
the store: the cortex every engine shares, and <code>engine_mysql</code>, proven by round-tripping every object of MySQL 5.7 to 9.7 and Percona
Server through it on every pull request. The app over it (the canvas, the agent's MCP) comes after the engines.</p>
<div class="scroll"><table class="t"><thead><tr><th>Objective</th><th>What</th><th>Issue</th><th>State</th></tr></thead><tbody>{rows}</tbody></table></div>
<p class="small">Read from the spec's sequence in <a href="%REPO%/blob/main/specs/root.xml">specs/root.xml</a>; <a href="%REPO%/blob/main/tools/objectives.py">tools/objectives.py</a> checks it against the issues on every pull request.</p></section>

<section id="try"><p class="kicker">Try it</p><h2>Install the store and run its proofs.</h2>
<p class="lede">You need PostgreSQL 18 (with its <code>psql</code> and <code>pg_dump</code>) and a superuser on it, Python 3.12 or later, and Docker for the proofs.</p>
<pre class="prompt">git clone %REPO% &amp;&amp; cd schema-forge
python3 tools/local/install.py --user &lt;your superuser&gt; --fresh   # the database, every schema and service account; locked in
python3 tools/mysql/all.py                                          # engine_mysql proven on every MySQL and Percona server</pre>
<p class="small">The installer asks for your password, and for <code>drop</code> before replacing an earlier install. It writes each service account's password
only to its accounts file, then checks that what it installed is exactly the database CI tested.</p></section>

<section id="repository"><p class="kicker">The repository</p><h2>What is built, and what proves it.</h2><figure>{crates_svg}<figcaption>Every box opens its folder. Every check is a tool in the repository, never an ad-hoc command, and CI runs them all on every pull request.</figcaption></figure></section>

<section id="pack"><p class="kicker">This site</p><h2>Built from the repository.</h2><figure>{pack_svg}<figcaption>Every table, column, flavor, objective and decision on these pages is read from the files; a change is made in the repository and the pages built again.</figcaption></figure>
<p class="small">Want to build it with us? How a build happens, from a design session to a merged pull request: <a href="{L.get('build-spec', '#')}">the Build Spec</a> and <a href="{L.get('contribute', '#')}">Contribute</a>.</p></section>
"""
CSS = """
.prompt{white-space:pre-wrap;font:13.5px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-x:auto}
.pill.next{background:var(--accent-soft);color:var(--accent)}
.d a rect{cursor:pointer}.d a:hover rect{stroke-width:2.8}
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("stands", "Where it stands"), ("try", "Try it"), ("repository", "The repository"), ("pack", "This site")])
HTML = page("home", "%PRODUCT%", CSS, body, sub)
