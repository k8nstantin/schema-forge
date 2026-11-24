"""The site's front page: the mission, what it does, every database a plugin, how it works, and how to join."""
import base64
import common
from common import REPO, Svg, e, links, page

L = links()


def shot(name, alt):
    """A screenshot of the prototype: a file of the site, or the image itself in a private preview."""
    if common.MODE == "site":
        src = f"screenshots/{name}"
    else:
        src = "data:image/jpeg;base64," + base64.b64encode(open(f"{REPO}/docs/screenshots/{name}", "rb").read()).decode()
    return f'<img class="shot" src="{src}" alt="{e(alt)}" loading="lazy">'


def card(title, text):
    return f'<div class="card"><h3>{title}</h3><p>{text}</p></div>'


g = Svg(1040, 260, "Your database is read into one PostgreSQL, where the model, its history and what is worked out about it can be asked together.")
g.box("src", 30, 100, 210, 60, "your database", "a dump, DDL or the live server", cls="box")
g.box("agent", 30, 190, 210, 52, "your coding agent", "designs and asks, over MCP", cls="box")
g.band(330, 20, 690, 230, "one PostgreSQL 18, bundled")
for k, x, title, sub in [("m", 360, "the model", "every object, column, key, rule"), ("l", 580, "its history", "every change, undoable"),
                         ("i", 800, "what is worked out", "dependencies, findings, meaning")]:
    g.box(k, x, 80, 200, 60, title, sub, cls="lg" if k == "l" else ("eng" if k == "i" else "pri"))
g.arrow("src", "m", "read", cls="ea")
g.parts.append('<line x1="242" y1="216" x2="560" y2="216" class="ea" marker-end="url(#mka)"/>')
g.text(560, 236, "one SQL query, all three at once", "lb m", "middle")
g.containers = set()
flow_svg = g.render()

does = "".join(card(a, b) for a, b in [
    ("An agent and an architect on one live model", "Your coding agent changes the schema through MCP, one checked operation at a time, and every change lands on the canvas at once. Its changes for one prompt form a turn you accept or reject whole."),
    ("Rules, designed ahead and enforced", "\"Every table has a primary key\", \"money is decimal, never float\": linked before design starts, checked on every change. A hard rule refuses a break; a soft one shows it."),
    ("The agent designs rules too", "It reads a schema and proposes rules with its evidence; each is verified, then approved by the architect, and enforced from then on."),
    ("Compatible across databases", "Across every engine: every type that would be lost, widened or approximated in a move between them is named, with the reason."),
    ("CDC as a goal", "Say what a schema has to do (\"feed it by CDC\", \"land PostgreSQL in Iceberg\") and see the gap: keys Debezium can follow, identifier fields, merge-on-read."),
    ("Starts from what exists", "It reads dumps, hand-written DDL and live databases, works out what depends on what and what is wrong, and keeps exactly as written whatever it does not model."),
])
plugins = "".join(card(a, b) for a, b in [
    ("MySQL: works today", "Dumps, hand-written DDL and the live server read; every kind of object and clause written back, loading into MySQL 8.0 to 26.10."),
    ("PostgreSQL and Apache Iceberg: next", "Each an engine of its own, with its own tables, checked by the same conformance kit; then converting a schema between them."),
    ("Your database", "An engine is one crate: its grammar, types and catalogs, and its own tables. Adding one needs no change to the core."),
])
SQL = """-- a sketch of the planned insight layer: tables about billing that refer to customers
SELECT o.name, d.kind, d.from_object AS used_by
FROM   cortex.objects o
JOIN   insight.embeddings  v ON v.subject = o.id
LEFT JOIN insight.dependencies d ON d.to_object = o.id      -- what reads or writes it
WHERE  EXISTS (SELECT 1 FROM cortex.relationships r
               WHERE r.from_object = o.id AND r.to_object = 'o_customers')
ORDER  BY v.vector <=> embedding('tables about billing')   -- pgvector: by meaning
LIMIT  10;"""

body = f"""
<header class="hero">
  <p class="eyebrow">Open source · multi-engine · MCP</p>
  <h1>Multi-engine schema design and management, with your coding agent.</h1>
  <p>%PRODUCT% is where you and your coding agent design and manage database schemas together, for every database you run: the agent through MCP, you on the canvas, every change checked against your team's rules, nothing landing unchecked. Each database is an engine plugin; the design and its management are the same for all of them.</p>
  <div class="btns"><a class="btn btn-primary" href="#does">What it does</a>
  <a class="btn btn-secondary" href="%REPO%">GitHub</a>
  <a class="btn btn-secondary" href="{e(L.get("contribute", "#"))}">Build it with us</a></div>
  <span class="note">Being built in the open, every database a plugin.</span>
</header>

<section id="does"><p class="kicker">What it does</p><h2>Design, check and manage the schema, with your agent.</h2>
<div class="cards two">{does}</div>
<figure class="screen">{shot("table-and-turn.jpg", "The prototype's canvas: a table the agent designed, its turn waiting for a verdict")}<figcaption>The prototype, which proved the loop: the agent's design on the canvas, its turn waiting to be accepted or rejected. The product is being rebuilt on the design this site describes; the prototype stays as the <code>prototype</code> tag.</figcaption></figure></section>

<section id="plugins"><p class="kicker">Every database a plugin</p><h2>Choose a database first; everything follows it.</h2>
<p class="lede">The canvas, the MCP, the rules and the store know no database. Each database is an engine: one crate with its versions, types, options, readers and writers, and its own tables. <a href="{e(L.get("engines", "#"))}">How engines plug in, with Apache Iceberg as the example →</a></p>
<div class="cards">{plugins}</div></section>

<section id="one-place"><p class="kicker">How it works</p><h2>One PostgreSQL holds the design, its history and what is worked out about it.</h2>
<figure>{flow_svg}<figcaption>Every change is recorded and can be undone; the database itself refuses any change that breaks a rule.</figcaption></figure>
<pre class="sql">{e(SQL)}</pre>
<div class="cards">
{card("Your data stays yours", "Meaning is found with embeddings from a model you choose: one that runs on your machine, so nothing leaves it, or an embedding API you pick, per workspace. Reading a live database sends only statements that read; no password is ever stored.")}
{card("Why PostgreSQL, not SQLite", "The database itself enforces every rule, the search index sits beside the design, and the same code serves a team server. The cost: a larger download, a small private server per open workspace, and upgrades the app handles for you.")}
{card("Next to the tools you know", "Atlas, Bytebase and Flyway plan and apply migrations; dbdiagram and drawDB draw diagrams; Prisma defines a schema in application code. %PRODUCT% is for designing and managing the schema itself, with your own agent, under rules the database enforces. <a href='%REPO%/blob/main/docs/market.md'>More</a>")}
</div></section>

<section id="contribute"><div class="cta"><p class="kicker">Built with coding agents</p><h2>Contribute the way it is built.</h2>
<p class="lede">Each piece of work is written down first as a task; one agent builds it; tests and a person's review decide. Point your agent at the project and it will show you what is open now. Anyone can take up the same task, and the best build is merged.</p>
<div class="btns"><a class="btn btn-primary" href="{e(L.get("contribute", "#"))}">Contribute with your agent</a>
<a class="btn btn-outline" href="{e(L.get("home", "#"))}">Read the design</a></div></div></section>
"""
CSS = """.shot{display:block;width:100%;height:auto;border-radius:10px;border:1px solid var(--line)}
figure.screen svg{min-width:0}
.sql{font:13px/1.6 var(--mono);background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-x:auto;margin:14px 0 0}"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("does", "What it does"), ("plugins", "Every database a plugin"), ("one-place", "How it works"), ("contribute", "Contribute")])
HTML = page("site", "%PRODUCT%", CSS, body, sub)
