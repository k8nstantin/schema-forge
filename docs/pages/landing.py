"""The site's front page: what the product is, why its database is its strength, and the way into the design."""
from common import Svg, database, e, links, page

db, _ = database()
L = links()
ntab = sum(len(d["tables"]) for d in db.values())
nrules = sum(len(d["rules"]) for d in db.values())

g = Svg(1040, 300, "You on the canvas and the agent over MCP work on the same schema at the same time, through one server that keeps everything in one PostgreSQL with pgvector.")
g.box("you", 30, 50, 220, 60, "you", "draw on the canvas", cls="box")
g.box("agent", 30, 170, 220, 60, "your agent", "chats and designs over MCP", cls="box")
g.box("serve", 360, 105, 230, 70, "schema-forge serve", "every change a checked operation", cls="pri")
g.band(680, 20, 340, 260, "PostgreSQL 18 + pgvector")
for key, y, title, sub in [("m", 60, "the model", "cortex · engine_<id>"), ("l", 130, "the log", "every turn, undoable"),
                           ("v", 200, "insight", "dependencies · vectors")]:
    g.box(key, 710, y, 280, 52, title, sub, cls="eng" if key == "v" else ("lg" if key == "l" else "pri"))
g.arrow("you", "serve", "", cls="ea"); g.arrow("agent", "serve", "", cls="ea")
g.parts.append('<line x1="592" y1="140" x2="676" y2="140" class="ea" marker-end="url(#mka)"/>')
g.text(634, 128, "one place", "lb m", "middle")
g.containers = set()
how_svg = g.render()

def card(title, text): return f'<div class="card"><h3>{title}</h3><p>{text}</p></div>'
def link(key, title, text): return f'<a class="card" href="{e(L.get(key, "#"))}"><h3>{title}</h3><p>{text}</p><span class="go">Read →</span></a>'

one_place = "".join(card(a, b) for a, b in [
    ("Real PostgreSQL, bundled", "PostgreSQL 18 with pgvector ships inside the app: nothing to install, nothing to configure. Each workspace runs its own private cluster."),
    ("One person or a whole team", "Point it at a central PostgreSQL server and a team shares one design: the same code, the same schema, only the connection changes."),
    ("Metadata and vectors together", "Every object, column, relationship and rule sits beside its embedding: one SQL query asks by meaning, by structure and by lineage at once."),
    ("Fresh on every change", "The log knows exactly what each turn touched, so only that is embedded again: what the agent finds is what is on the canvas."),
    ("Guarded by the database", "Foreign keys, typed and checked columns, and rules PostgreSQL enforces at every commit, whoever writes: you, your agent or your team."),
    ("Grows by versions", "Every engine and every feature brings its own namespace and versions; every change adds, and every release upgrades the ones before."),
])
plugins = "".join(card(a, b) for a, b in [
    ("MySQL", "Dumps, hand-written DDL and the live server read; every kind of object and clause written back for MySQL 8.0 to 26.10. Done."),
    ("PostgreSQL and Apache Iceberg", "Next, each an engine of its own with its own tables. Iceberg brings the lakehouse: field ids, hidden partitioning, format versions 1 to 3."),
    ("Your database", "An engine is one crate: its grammar, types and catalogs, and its tables from the owner template. No change to the core."),
    ("Convert both ways", "Every engine maps into one shared model, so MySQL converts to Iceberg and Iceberg back to MySQL or PostgreSQL, with every type kept, widened or lost named."),
])
design = "".join([
    link("home", "Start here", "What %PRODUCT% is, how it is built, and where it stands."),
    link("database", "The database", f"Every one of its {ntab} tables and {nrules} rules, drawn and listed from the schema folders."),
    link("template", "The owner template", "How an engine or a feature adds its tables: five shapes, rules and versions."),
    link("build-spec", "The build spec", "How coding agents build it: one XML task per branch and pull request, every decision dated."),
])
body = f"""
<header class="hero">
  <p class="eyebrow">Open source · Rust · PostgreSQL 18 + pgvector · MCP</p>
  <h1>Design database schemas with your coding agent, under standards that hold.</h1>
  <p>%PRODUCT% is collaborative schema design: your agent designs through MCP while you view and edit the same schema on the
  canvas, at the same time. Every change, yours and the agent's, is checked against your team's rules, and nothing lands unchecked.</p>
  <div class="btns"><a class="btn btn-primary" href="{e(L.get("home", "#"))}">Read the design</a>
  <a class="btn btn-secondary" href="%REPO%">GitHub</a>
  <a class="btn btn-secondary" href="%REPO%/discussions">Discussions</a></div>
  <span class="note">Designed and specified, and being built now, in the open.</span>
</header>

<section id="one-place"><p class="kicker">The database at the core</p>
<h2>One PostgreSQL. Your design, its rules, its history and its vectors, in one place.</h2>
<p class="lede">For one person on a laptop or a whole team on a server. The database is designed first and locked, so coding agents fall into it instead of drifting from it.</p>
<div class="cards">{one_place}</div></section>

<section id="intelligence"><p class="kicker">Bring the database you have</p>
<h2>Point it at your database. Get to know it.</h2>
<p class="lede">Read in a live database, a dump or a folder of DDL, and %PRODUCT% works out what you never wrote down: how it is put together, what depends on what, and what it means. Ask it in plain words, through the canvas or your agent.</p>
<div class="cards two"><div class="card"><h3>Its architecture</h3><p>Every namespace, table, view, routine, trigger and event, with their keys, indexes and partitions, laid out as one model you can see and walk.</p></div><div class="card"><h3>Its relationships</h3><p>Foreign keys, and what no key declares: which routine reads or writes which table, which view stands on which, what a change would reach.</p></div><div class="card"><h3>Its meaning</h3><p>What each object is for, in sentences kept up to date, and found by meaning: ask for the tables about billing and get them, with the evidence.</p></div><div class="card"><h3>Its problems</h3><p>Tables without keys, money in floats, rules your team wrote that the database breaks today: each a finding with its evidence and its fix.</p></div></div></section>

<section id="how"><p class="kicker">Collaborative design</p><h2>Your agent designs through MCP. You see it, and edit it, at the same time.</h2>
<p class="lede">Ask your agent for a design and watch every table, column and relationship land on the canvas as it makes them. Move in beside it: point at anything, edit it by hand, steer the next prompt. You and the agent work on one live schema, through the same checks, into the same database; each of the agent's answers is a turn you accept or reject whole, and undo takes back any of it.</p>
<figure>{how_svg}<figcaption>The canvas and the MCP are two doors into one server; everything it knows lives in one PostgreSQL.</figcaption></figure></section>

<section id="plugins"><p class="kicker">Every database a plugin</p><h2>Choose a database first; everything follows it.</h2>
<p class="lede">The canvas, the MCP, the rules and the store know no database. Each database is an engine: one crate with its versions, types, options, readers and writers, and its own tables, checked by the same conformance kit. <a href="{e(L.get("engines", "#"))}">How engines plug in, with Apache Iceberg as the example →</a></p>
<div class="cards">{plugins}</div></section>

<section id="design"><p class="kicker">The design, written down</p><h2>Read how it is built, before a line of it is.</h2>
<div class="cards">{design}</div></section>

<section id="contribute"><div class="cta"><p class="kicker">Contribute</p><h2>Learn databases from the inside.</h2>
<p class="lede">Write an engine and learn a database's grammar, types and catalogs; add a feature's tables and learn relational design and rules enforced at commit; bring a dump that breaks a reader and find the corners of SQL nobody documents. Everyone is welcome.</p>
<div class="btns"><a class="btn btn-primary" href="%REPO%/blob/main/CONTRIBUTING.md">How to contribute</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="%REPO%/discussions">Ask a question</a></div></div></section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("one-place", "One place"), ("intelligence", "Your database"), ("how", "Collaborative design"), ("plugins", "Plugins"), ("design", "The design"), ("contribute", "Contribute")])
HTML = page("site", "%PRODUCT%", "", body, sub)
