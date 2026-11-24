"""The Engines page: how a database plugs into the product, with Apache Iceberg worked through as the example."""
from common import Svg, database, e, links, page

db, _ = database()
L = links()
n_mysql = len(db["engine_mysql"]["tables"])

# --- two layers ------------------------------------------------------------------------------------------------------
g = Svg(1040, 330, "The shared process knows no database; each engine plugs in through one interface and brings everything about its database.")
g.band(10, 10, 1020, 120, "shared: the process, the same for every database")
for i, (k, t, s) in enumerate([("canvas", "canvas", "draw, view, edit"), ("mcp", "MCP", "the agent's tools"), ("turns", "turns and undo", "every change logged"),
                               ("rules", "rules", "hard and soft, checked"), ("store", "the store", "PostgreSQL, cortex")]):
    g.box(k, 30 + i * 200, 50, 180, 56, t, s, cls="pri")
g.box("iface", 360, 160, 320, 50, "the engine interface", "registry · conformance kit · architecture check", cls="box")
g.band(10, 230, 1020, 90, "engines: one crate each, sharing nothing with each other")
for i, (k, t, s) in enumerate([("my", "MySQL", "built"), ("pg", "PostgreSQL", "next"), ("ice", "Apache Iceberg", "next"),
                               ("yours", "your database", "one crate")]):
    g.box(k, 40 + i * 250, 256, 210, 52, t, s, cls="eng")
g.parts.append('<line x1="520" y1="108" x2="520" y2="158" class="ea" marker-end="url(#mka)"/>')
g.parts.append('<line x1="520" y1="212" x2="520" y2="254" class="es" marker-end="url(#mks)"/>')
g.containers = set()
layers_svg = g.render()

# --- an Iceberg table, in the cortex and in engine_iceberg -----------------------------------------------------------
g = Svg(1040, 470, "An Iceberg table: what every engine shares lands in the cortex; what only Iceberg has lands in engine_iceberg, each row tied to its cortex row.")
g.band(10, 10, 420, 450, "cortex: shared")
g.band(560, 10, 470, 450, "engine_iceberg: only Iceberg (a sketch)")
cortex = [("objects", 50, "objects", "the table, the view"), ("columns", 130, "columns", "id, name, type, null"),
          ("keys", 210, "table_keys", "identifier: the upsert key"), ("pf", 290, "partition_fields", "day(ts), bucket[16](id)"),
          ("sort", 370, "sort_fields", "the sort order")]
for k, y, t, s in cortex:
    g.box(k, 40, y, 360, 56, t, s, cls="pri")
ice = [("topt", 50, "table_options", "format version, location, merge-on-read"), ("vrep", 130, "view_representations", "one SQL per dialect"),
       ("props", 210, "table_properties", "any key = value, as written"), ("copt", 290, "column_options", "field id, initial and write defaults"),
       ("nest", 370, "nested_fields", "struct, list, map: a tree with field ids")]
for k, y, t, s in ice:
    g.box(k, 600, y, 400, 56, t, s, cls="eng")
for a, b in [("topt", "objects"), ("vrep", "objects"), ("copt", "columns"), ("nest", "columns"), ("props", "objects")]:
    ax, ay, aw, ah = g.boxes[a]; bx, by, bw, bh = g.boxes[b]
    g.parts.append(f'<line x1="{ax}" y1="{ay + ah / 2}" x2="{bx + bw + 2}" y2="{by + bh / 2}" class="ea" marker-end="url(#mka)"/>')
    g.lines.append((a, b, ax, ay + ah / 2, bx + bw + 2, by + bh / 2))
g.containers = set()
iceberg_svg = g.render()

def card(t, s): return f'<div class="card"><h3>{t}</h3><p>{s}</p></div>'

# --- converting: every engine to the hub, never engine to engine --------------------------------------------------------
g = Svg(1040, 400, "Every engine maps once into the shared model and Arrow's types; any engine converts to any other through it, with a report of what each move keeps, widens, approximates or loses.")
g.box("hub", 370, 125, 300, 110, "the shared model", "cortex rows · Arrow types · the rules", cls="pri")
for k, x, y, t2, s2 in [("my", 40, 30, "MySQL", "built"), ("pg", 40, 250, "PostgreSQL", "next"),
                        ("ice", 790, 30, "Apache Iceberg", "next"), ("more", 790, 250, "BigQuery, Snowflake…", "later")]:
    g.box(k, x, y, 210, 60, t2, s2, cls="eng")
for k in ("my", "pg", "ice", "more"):
    g.arrow(k, "hub", "", cls="ea")
g.text(520, 350, "n engines: n mappings, never n × n converters", "lb m", "middle")
g.text(520, 374, "each move: a report of every type kept, widened, approximated or lost, and every option with no equivalent", "lb", "middle")
g.containers = set()
convert_svg = g.render()
conv_cards = "".join(card(a, b) for a, b in [
    ("MySQL to Iceberg", "Land an operational database in the lakehouse: keys become identifier fields for upserts, a time column a day partition, unsigned and ENUM types mapped by the rules, and every type Debezium would carry badly named before a byte moves."),
    ("Iceberg to MySQL or PostgreSQL", "Serve a lakehouse table back to an application: nested fields flattened or kept as JSON by the rules, timestamps' precision and zones checked, a key chosen where Iceberg had only identifier fields."),
    ("Any to any", "PostgreSQL to MySQL, MySQL to PostgreSQL, and every engine that comes after: each maps once to the shared model, so each new engine converts to all the others the day it arrives."),
    ("Under your rules", "A conversion is a design, not a dump: the target schema is generated by the rules you choose (naming, types, CDC columns, partitioning), then refined with the agent on the canvas, every change checked."),
])

engine_is = "".join(card(a, b) for a, b in [
    ("Its versions, as data", "Every type, option and capability is marked with the version that brought it and the one that took it away. A schema is designed for one version and offered exactly its features. A new version is new rows, never new code paths."),
    ("Its types", "Every type and every spelling a dump uses, mapped to Apache Arrow's types, so a move between databases names what is kept, widened, approximated or lost."),
    ("Its kinds and options", "What kinds of object it has (tables, views, routines, pools) and the options of each, declared as data: the canvas builds its forms from them, and the kit refuses an option not declared."),
    ("Reading and writing", "Its own grammar for its dumps and DDL, its live catalog through a connection, and SQL written back that loads into the real database."),
    ("Its tables", f"What only it has, in its own namespace <code>engine_&lt;id&gt;</code> of each schema's database, versioned on its own, from <a href=\"{e(L.get('template', '#'))}\">the owner template</a>. MySQL brings {n_mysql}."),
    ("Add-ons", "An extension of the database (PostGIS, a company's conventions) is a crate of its own that adds types, statements and rules to the engine, registered with one line, never a fork."),
])
guards = "".join(card(a, b) for a, b in [
    ("The conformance kit", "Runs every engine through the same tests: its declarations, its round trip (every sample read, written and read back the same) and its tables."),
    ("The architecture check", "Fails the build when shared code names a database, an engine depends on another, or two crates claim the same database."),
    ("Quill, the engine nobody uses", "A made-up engine built unlike any real one; every test of shared code runs on it beside the real engines, so nothing shared can quietly assume one database."),
])
iceberg_cards = "".join(card(a, b) for a, b in [
    ("Format versions 1, 2 and 3", "Version 3 brings default values (initial and write), nanosecond timestamps, variant, geometry and geography, row lineage and deletion vectors; each feature marked with its version. Format 4 will be new rows in the same crate."),
    ("Field ids, not names", "Iceberg tracks every column, and every field nested in it, by an id that never changes: that is how it renames safely. %PRODUCT% keeps the ids, so a design evolves the way Iceberg evolves."),
    ("Hidden partitioning", "Partitions are transforms of columns (<code>day(ts)</code>, <code>bucket[16](id)</code>, <code>truncate[4](code)</code>), kept in the cortex's partition fields, so the canvas and the rules read them like any engine's."),
    ("Identifier fields and the sort order", "The upsert key CDC needs, and the order files are written in: both in the cortex, as the shared layout has a place for each."),
    ("Read from where Iceberg lives", "Spark SQL and Trino DDL, a table's <code>metadata.json</code>, and a live catalog (REST, Glue, Hive) through a connection; written back as DDL or table metadata."),
    ("The CDC target", "The other end of a pipeline: a MySQL or PostgreSQL source designed into Iceberg tables by rules, with every type that would be lost, widened or approximated named."),
])
body = f"""
<header class="hero">
  <p class="eyebrow">Every database a plugin</p>
  <h1>Choose a database first. Everything follows it.</h1>
  <p>%PRODUCT% is built in two layers that never mix. The process (the canvas, the MCP, turns, the rules, the store) is the same for every
  database and knows none of them. Everything about a database belongs to its engine: one crate that plugs in through one interface.</p>
  <div class="btns"><a class="btn btn-primary" href="#iceberg">See Iceberg plug in</a>
  <a class="btn btn-secondary" href="%REPO%/blob/main/specs/guides/engine.xml">The engine guide, for your agent</a></div>
</header>

<section id="layers"><p class="kicker">Two layers</p><h2>The process is shared. The database is its engine's.</h2>
<p class="lede">Adding a database needs no change to the core, and a problem in one engine is found in that engine and never breaks another: engines share nothing with each other but the interface.</p>
<figure>{layers_svg}<figcaption>MySQL is built, whole. PostgreSQL and Apache Iceberg are next, each an engine of its own. BigQuery, Snowflake and ClickHouse after them.</figcaption></figure></section>

<section id="engine"><p class="kicker">What an engine brings</p><h2>One crate, all of its database.</h2>
<div class="cards">{engine_is}</div></section>

<section id="guards"><p class="kicker">What keeps them honest</p><h2>Checked by the build, not by convention.</h2>
<div class="cards">{guards}</div></section>

<section id="iceberg"><p class="kicker">Worked example · planned</p><h2>Apache Iceberg plugs in.</h2>
<p class="lede">Iceberg is not a database server but a table format for the lakehouse: its tables live as files and metadata in object storage, found through a catalog. It has no primary keys, no checks, no indexes; it has field ids, hidden partitioning, sort orders and identifier fields. The shared layout has a place for what Iceberg shares with every engine, and the engine brings the rest.</p>
<figure>{iceberg_svg}<figcaption>Left, the cortex rows every engine writes; right, the tables only Iceberg needs, one per shape of the owner template (options of a part, an ordered list, a tree, open-ended properties). The Iceberg tables are a sketch: they are designed and locked in their own session before the Iceberg engine is built.</figcaption></figure>
<div class="cards">{iceberg_cards}</div></section>

<section id="convert"><p class="kicker">Because it holds many engines</p><h2>Convert between databases, both ways.</h2>
<p class="lede">Every engine reads its database into the same shared model and maps its types to Apache Arrow's. So a schema read from MySQL can be written as Iceberg, and an Iceberg table as MySQL or PostgreSQL: one path through the hub, with nothing silently lost. A planned feature, built on the engines and the pipelines.</p>
<figure>{convert_svg}<figcaption>The hub is what makes it scale: an engine maps itself once, and converts to every other engine through it.</figcaption></figure>
<div class="cards two">{conv_cards}</div></section>

<section id="yours"><div class="cta"><p class="kicker">Your database next</p><h2>Write an engine, learn a database.</h2>
<p class="lede">An engine teaches its database from the inside: its grammar, its types, its catalog, its corners. Your coding agent leads with the engine guide: it studies the interface and your database, writes its profile with you, brings it to a design session, and then the engine is built task by task. Paste this into your agent:</p>
<pre class="prompt">Read %SITE%agents.xml, then %REPO%/blob/main/specs/guides/engine.xml, and help me bring &lt;my database&gt; to %PRODUCT%; start with the study, and change nothing yet.</pre>
<div class="btns"><a class="btn btn-primary" href="%REPO%/blob/main/specs/guides/engine.xml">The engine guide</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="%REPO%/blob/main/docs/writing-an-engine.md">Writing an engine: the how</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="{e(L.get('template', '#'))}">The owner template</a></div></div></section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("layers", "Two layers"), ("engine", "What an engine brings"), ("guards", "Checks"), ("iceberg", "Iceberg"), ("convert", "Convert"), ("yours", "Your database")])
HTML = page("engines", "%PRODUCT% Engines", ".prompt{white-space:pre-wrap;font:14px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-wrap:anywhere}", body, sub)
