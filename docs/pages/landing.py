"""The site's front page: the first release first, what runs today, what comes after, and how to join."""
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


g = Svg(1040, 260, "Your agent reads the database into one PostgreSQL, where the model, its history and what is worked out about it can be asked together.")
g.box("src", 30, 100, 210, 60, "your MySQL", "a dump, DDL or the live server", cls="box")
g.box("agent", 30, 190, 210, 52, "your coding agent", "asks, over MCP", cls="box")
g.band(330, 20, 690, 230, "one PostgreSQL 18, bundled")
for k, x, title, sub in [("m", 360, "the model", "every object, column, key, rule"), ("l", 580, "its history", "every change, undoable"),
                         ("i", 800, "what is worked out", "dependencies, findings, meaning")]:
    g.box(k, x, 80, 200, 60, title, sub, cls="lg" if k == "l" else ("eng" if k == "i" else "pri"))
g.arrow("src", "m", "read", cls="ea")
g.parts.append('<line x1="242" y1="216" x2="560" y2="216" class="ea" marker-end="url(#mka)"/>')
g.text(560, 236, "one SQL query, all three at once", "lb m", "middle")
g.containers = set()
flow_svg = g.render()

today = "".join(card(a, b) for a, b in [
    ("Reads MySQL", "mysqldump files, hand-written DDL and a live MySQL server: every kind of object and clause, from MySQL 8.0 to 26.10."),
    ("Writes it back", "SQL that loads into a real MySQL server, proved by loading it, dumping it again and reading back the same schema."),
    ("Designed in the open", "The database it keeps its work in, every table and rule, and every task still to build, written down before the code."),
])
first = "".join(card(a, b) for a, b in [
    ("How it is built", "Every database, table, view, routine, trigger and event, with their keys, indexes and partitions, as one model you can walk."),
    ("What depends on what", "Foreign keys, and the links no key declares: which routine reads or writes which table, which view stands on which, what a change would reach."),
    ("What it means", "What each object is for, kept up to date as the schema changes, and found by meaning: ask for the tables about billing and get them, with the evidence."),
    ("What is wrong with it", "Tables without keys, money stored in floats, rules your team wrote that the database breaks: each a finding with its evidence."),
])
nxt = "".join(card(a, b) for a, b in [
    ("The canvas, with your agent", "Your agent designs through MCP while you watch the schema change and edit it yourself. How your edits and an agent's open turn combine is still being designed."),
    ("PostgreSQL and Iceberg", "More engines, each a plugin of its own; and converting a schema between them, naming every type kept, widened or lost."),
    ("For a team", "The same code on a shared PostgreSQL server: one design, one history, one search index for everyone."),
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
  <p class="eyebrow">Open source · Rust · PostgreSQL 18 + pgvector · MCP</p>
  <h1>Point it at your MySQL database. See how it is built, and what is wrong with it.</h1>
  <p>%PRODUCT% reads a MySQL database (a dump, DDL or the live server) and works out what nobody wrote down: how it is put together, what depends on what, what it means, and where it breaks your rules. You ask in plain words, through your own coding agent.</p>
  <div class="btns"><a class="btn btn-primary" href="#today">What runs today</a>
  <a class="btn btn-secondary" href="%REPO%">GitHub</a>
  <a class="btn btn-secondary" href="{e(L.get("contribute", "#"))}">Build it with us</a></div>
  <span class="note">The first release is being built now, in the open. The MySQL engine works today.</span>
</header>

<section id="today"><p class="kicker">What runs today</p><h2>The MySQL engine, whole.</h2>
<div class="cards">{today}</div>
<figure class="screen">{shot("table-and-turn.jpg", "The prototype's canvas: a table the agent designed, its turn waiting for a verdict")}<figcaption>The prototype, which proved the idea: the agent's design on the canvas, its turn waiting to be accepted or rejected. The product is being rebuilt on the design this site describes; the prototype stays as the <code>prototype</code> tag.</figcaption></figure></section>

<section id="first"><p class="kicker">The first release</p><h2>Understand the database you already have.</h2>
<p class="lede">Read in your MySQL database and ask your agent about it. Reading a live server sends only statements that read, and no password is ever stored.</p>
<div class="cards two">{first}</div></section>

<section id="one-place"><p class="kicker">How it works</p><h2>One PostgreSQL holds the model, its history and what is worked out about it.</h2>
<figure>{flow_svg}<figcaption>Every change is recorded and can be undone; the database itself refuses any change that breaks a rule.</figcaption></figure>
<pre class="sql">{e(SQL)}</pre>
<div class="cards">
{card("Your data stays yours", "Meaning is found with embeddings from a model you choose: one that runs on your machine, so nothing leaves it, or an embedding API you pick, per workspace.")}
{card("Why PostgreSQL, not SQLite", "The database itself enforces every rule, the search index sits beside the model, and the same code serves a team server. The cost: a larger download, a small private server per open workspace, and upgrades the app handles for you.")}
{card("Next to the tools you know", "Atlas, Bytebase and Flyway plan and apply migrations; dbdiagram and drawDB draw diagrams; Prisma defines a schema in application code. %PRODUCT% is for understanding and designing the schema itself, with your own agent, under rules the database enforces. <a href='%REPO%/blob/main/docs/market.md'>More</a>")}
</div></section>

<section id="next"><p class="kicker">What comes after</p><h2>Then design with your agent, and move between databases.</h2>
<div class="cards">{nxt}</div>
<p class="lede" style="margin-top:14px">Every database is a plugin: <a href="{e(L.get("engines", "#"))}">how engines plug in</a>, with Apache Iceberg as the example.</p></section>

<section id="contribute"><div class="cta"><p class="kicker">Built with coding agents</p><h2>Contribute the way it is built.</h2>
<p class="lede">Each piece of work is written down first as a task; one agent builds it; tests and a person's review decide. Point your agent at the project and it will show you what is open now. Anyone can take up the same task, and the best build is merged.</p>
<div class="btns"><a class="btn btn-primary" href="{e(L.get("contribute", "#"))}">Contribute with your agent</a>
<a class="btn btn-outline" href="{e(L.get("home", "#"))}">Read the design</a></div></div></section>
"""
CSS = """.shot{display:block;width:100%;height:auto;border-radius:10px;border:1px solid var(--line)}
figure.screen svg{min-width:0}
.sql{font:13px/1.6 var(--mono);background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-x:auto;margin:14px 0 0}"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("today", "Today"), ("first", "First release"), ("one-place", "How it works"), ("next", "After"), ("contribute", "Contribute")])
HTML = page("site", "%PRODUCT%", CSS, body, sub)
