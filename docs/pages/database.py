"""The Database page: the one database, schema_forge, as its owners' folders give it: every namespace with its two roles,
every table with its columns, types, references, keys and comments, read from the files (the cortex, then every
plugin); nothing about a table is typed here."""
import os
import re
import tomllib

from common import OWNERS, REPO, Svg, database, e, page

db, edges = database()

# --- the cortex at a glance: its tables in their three groups, each a link to its card -------------------------------
CORTEX = tomllib.load(open(f"{REPO}/schema/cortex/owner.toml", "rb"))["tables"]
GROUPS = [("the plugs: what is installed and declared", CORTEX[:7]), ("designs and their history", CORTEX[7:13]), ("the model every engine shares", CORTEX[13:])]
g = Svg(1040, 330, "The cortex: the plugs every engine fits into, designs and their history, and the model every engine shares; each box links to its table.")
for gi, (label, names) in enumerate(GROUPS):
    y0 = 12 + gi * 104
    g.band(10, y0, 1020, 96, label)
    for i, n in enumerate(names):
        title, sub = (n, "") if len(n) <= 14 else (n.split("_", 1)[0] + "_", n.split("_", 1)[1])
        g.box(f"cx_{n}", 24 + i * 125, y0 + 36, 117, 46, title, sub, cls="pri" if gi == 2 else ("lg" if gi == 1 else "eng"), href=f"#cortex.{n}")
g.containers = set()
cortex_svg = g.render()

# --- a design's rows ---------------------------------------------------------------------------------------------------
g = Svg(1040, 330, "A design is a row; every other row of it points at it: the model in its namespaces, and the log of every change in turns and operations.")
nodes = [("designs", 420, 20, "designs", "engine · version · flavor"), ("namespaces", 120, 120, "namespaces", "a server, its databases"),
         ("objects", 120, 230, "objects", "tables, views, routines"), ("branches", 720, 120, "branches", "lines of work"),
         ("turns", 720, 230, "turns", "one round of work"), ("columns", 420, 230, "columns · indexes · keys", "of an object")]
for k, x, y, t, s in nodes:
    g.box(f"d_{k}", x, y, 220 if k != "columns" else 240, 56, t, s, cls="lg" if k in ("branches", "turns") else "pri",
          href=f"#cortex.{k if k != 'columns' else 'columns'}")
for a, b in [("namespaces", "designs"), ("branches", "designs"), ("objects", "namespaces"), ("turns", "branches"), ("columns", "objects")]:
    g.arrow(f"d_{a}", f"d_{b}")
g.text(530, 316, "every arrow a foreign key (design, column) to (design, id): no row can point into another design", "lb", "middle")
g.containers = set()
rows_svg = g.render()

# --- engine_mysql extends the cortex -----------------------------------------------------------------------------------
SEEDS = open(f"{REPO}/engines/mysql/seeds/engine.sql", encoding="utf-8").read()
EXTENDS = {}
for m in re.finditer(r"\('mysql', '(\w+)', (NULL|'(\w+)'), '", SEEDS):
    EXTENDS.setdefault(m.group(3) or "", []).append(m.group(1))
order = [k for k in ("namespaces", "objects", "columns", "indexes", "index_parts", "") if k in EXTENDS]
rows_needed = {k: (len(EXTENDS[k]) + 3) // 4 for k in order}
height = 20 + sum(rows_needed[k] * 46 + 24 for k in order)
g = Svg(1040, height, "engine_mysql's tables, each beside the cortex table it extends one row to one row with the same id; its parts of their own below.")
y = 14
for k in order:
    span = rows_needed[k] * 46
    if k:
        g.box(f"x_{k}", 20, y + span / 2 - 22, 200, 44, f"cortex.{k}", "extended by", cls="pri", href=f"#cortex.{k}")
    else:
        g.text(30, y + span / 2 + 4, "parts of their own", "lb m")
    for i, t in enumerate(EXTENDS[k]):
        title, sub = (t, "") if len(t) <= 21 else (t.split("_", 1)[0] + "_", t.split("_", 1)[1])
        g.box(f"m_{t}", 300 + (i % 4) * 182, y + (i // 4) * 46, 170, 40, title, sub, cls="eng", href=f"#engine_mysql.{t}")
    if k:
        first = EXTENDS[k][0]
        ax, ay, aw, ah = g.boxes[f"m_{first}"]
        bx, by, bw, bh = g.boxes[f"x_{k}"]
        g.parts.append(f'<line x1="{ax}" y1="{ay + ah / 2}" x2="{bx + bw + 2}" y2="{by + bh / 2}" class="ea" marker-end="url(#mka)"/>')
        g.lines.append((f"m_{first}", f"x_{k}", ax, ay + ah / 2, bx + bw + 2, by + bh / 2))
    y += span + 24
g.containers = set()
extends_svg = g.render()

ROLES = {
    "cortex": [("cortex_owner", "no login", "owns the cortex and runs its migrations; plugs plugins in"),
               ("cortex_service", "the app", "writes designs, branches and the model; opens, ends and numbers turns; locks versions; reads every plugin's tables, writes none"),
               ("cortex_agent", "the coding agent", "as the app, but reads designs, branches and locked versions only"),
               ("cortex_reader", "reads only", "every table, nothing written")],
}


def plugin_roles(ns):
    return [(f"{ns}_owner", "no login", f"owns {ns} and runs its migrations; may reference the cortex tables its own extend, nothing else"),
            (f"{ns}_service", "the plugin", f"the only writer of {ns}; reads its declarations and its engine's designs and writes the model of them, "
                                            "fenced to its engine's designs; adds its operations to the app's turn")]


def card(owner_folder):
    path = os.path.join(REPO, os.path.dirname(owner_folder.rstrip("/")) if owner_folder.endswith("/schema") else owner_folder, "owner.toml")
    return tomllib.load(open(path, "rb")) if os.path.exists(path) else {}


def columns_table(t):
    rows = []
    for c in t["columns"]:
        ref = f'<a href="#{e(c["ref"])}"><code>{e(c["ref"])}</code></a>' if c["ref"] else ""
        flags = " ".join(x for x in ("key" if c["pk"] else "", "not null" if c["not_null"] else "", "unique" if c["unique"] else "") if x)
        rows.append(f'<tr><td><code>{e(c["name"])}</code></td><td><code>{e(c["type"])}</code></td><td class="small">{e(flags)}</td>'
                    f'<td class="small">{ref}</td><td>{e(c["comment"])}</td></tr>')
    return ('<table class="cols"><thead><tr><th>Column</th><th>Type</th><th></th><th>Refers to</th><th>What it holds</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table>")


sections, toc, total = [], [], 0
for ns, folder in OWNERS:
    tables = sorted(db[ns]["tables"], key=lambda t: t["short"])
    if not tables:
        continue
    total += len(tables)
    roles = ROLES.get(ns) or plugin_roles(ns)
    role_rows = "".join(f'<tr><td><code>{e(r)}</code></td><td class="small">{e(k)}</td><td>{e(s)}</td></tr>' for r, k, s in roles)
    cards = "".join(
        f'<article class="tbl" id="{e(t["name"])}"><h3><code class="tn">{e(t["name"])}</code><span class="path">{e(t["file"])}</span></h3>'
        f'<p class="lede">{e(t["about"][:1].upper() + t["about"][1:])}</p>{columns_table(t)}'
        + (f'<p class="small">{"<br>".join(e(c) for c in t["constraints"])}</p>' if t["constraints"] else "")
        + f'<details><summary>The file, whole</summary><pre>{e(t["text"].strip())}</pre></details></article>'
        for t in tables)
    toc.append(f'<a href="#{e(ns)}">{e(ns)} ({len(tables)})</a>')
    sections.append(f'<section id="{e(ns)}"><p class="kicker">{e(folder)}</p><h2><code>{e(ns)}</code></h2>'
                    f'<table class="roles"><thead><tr><th>Role</th><th></th><th>What it may do</th></tr></thead><tbody>{role_rows}</tbody></table>'
                    f'{cards}</section>')

CSS = """.tbl{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:14px 0;min-width:0;overflow-x:auto}
.tbl h3{margin:0 0 4px;display:flex;flex-wrap:wrap;gap:8px;align-items:baseline}.tn{font-size:16px;font-weight:600;background:none;border:0;padding:0}
.path{font-size:12px;color:var(--muted)}.cols,.roles{width:100%;border-collapse:collapse;font-size:13px;margin:8px 0}
.cols td,.cols th,.roles td,.roles th{border-bottom:1px solid var(--line);padding:4px 6px;text-align:left;vertical-align:top}
.toc{display:flex;flex-wrap:wrap;gap:10px;margin:10px 0}
.d a rect{cursor:pointer}.d a:hover rect{stroke-width:2.8}.d a:hover text{text-decoration:underline}
figure{margin:18px 0;overflow-x:auto}figure svg{min-width:720px}"""

HOW = [
    ("The schema is the application's core",
     "Everything SchemaForge knows of a design is rows of one database, schema_forge: no design is a database, a namespace or "
     "a table of its own. The canvas, the agent, the importer and the writer all read and write the same rows, so what one "
     "shows is what the others act on."),
    ("The database keeps it consistent, not the code",
     "Every reference is a foreign key, every value typed and checked, every column documented in the database itself. Every "
     "table of a design carries its design, and every reference within it is (design, column) to (design, id): no row can point "
     "into another design. A change the rules forbid is refused at commit, whoever wrote it: the app, the agent or a plugin."),
    ("Every id a UUIDv7",
     "Made with its row, kept when the part is renamed, never made from a name; ids sort in the order they were made. No id "
     "counter anywhere."),
    ("History for free, for every engine",
     "One trigger logs every row change of the cortex and of every plugin under the operation of a turn, before and after. "
     "Undo, restore and branch switch are the same for every engine; a change outside a turn is refused; nobody rewrites the log."),
    ("Engines plug in, and cannot break each other",
     "Each plugin brings its own namespace, owner and service account, and is plugged in by five checked steps: a table that is "
     "not a plug is refused. Its service account is the only writer of its tables, sees only its own engine's designs (row-level "
     "security), and holds only the privileges its work needs: no cross-engine writes, ever."),
    ("Two engines, a dozen databases",
     "engine_mysql and engine_postgresql are each built once across every version of their database; every managed service and "
     "compatible database falls into its family as a flavor: what it refuses is a declared fact, what it adds a typed table or a "
     "declared option. What looks very complex is solved by the design of the schema."),
    ("Proven, not claimed",
     "Every property above is a tool in the repository, run on every pull request: the cortex loads, its ids, its dump, its history, "
     "its refusals, its privileges; each engine round-trips every object of every version through the store, identical."),
]
how = "".join(f'<article class="tbl"><h3>{e(t)}</h3><p>{e(s)}</p></article>' for t, s in HOW)

body = f"""
<header class="hero"><p class="eyebrow">The database</p><h1>One database, <code>schema_forge</code>.</h1>
<p class="lede">The cortex holds what every engine shares and the plugs every engine fits into; each engine is a plugin with its own
namespace, its own owner and its own service account, the only writer of its tables. Every id is a UUIDv7. Every table below is
read from its file; every column's comment is its comment in the database. {total} tables.</p>
<div class="toc"><a href="#map">The cortex at a glance</a><a href="#design-rows">A design is a row</a><a href="#how">How it works</a><a href="#extends">How an engine extends it</a>{"".join(toc)}</div></header>
<section id="map"><p class="kicker">The cortex at a glance</p><h2>21 tables in three groups. Click any.</h2>
<figure>{cortex_svg}</figure></section>
<section id="design-rows"><p class="kicker">A design is a row</p><h2>Everything else of a design points at it.</h2>
<figure>{rows_svg}</figure></section>
<section id="how"><p class="kicker">How it works, and why</p><h2>The schema is the core of the application, and the database keeps it consistent.</h2>{how}</section>
<section id="extends"><p class="kicker">How an engine extends the cortex</p><h2>engine_mysql: each table beside the cortex table it extends.</h2>
<p class="lede">An engine's row has the same id as the cortex row it extends, so the canvas and the agent read every engine the same way, and the engine keeps everything only it knows, typed.</p>
<figure>{extends_svg}</figure></section>
{"".join(sections)}
"""

HTML = page("database", "SchemaForge · the database", CSS, body)
