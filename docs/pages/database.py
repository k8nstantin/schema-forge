"""The Database page: every table of the cortex, the workspace and each engine, drawn and listed from the schema
folders. Every arrow of every diagram is a foreign key a file declares; every column is read from its file."""
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from common import REPO, Svg, database, e, page

db, edges = database()
T = {t["name"]: (o, t) for o, d in db.items() for t in d["tables"]}
refs = defaultdict(list)      # table -> [(column, target)]
refd = defaultdict(list)      # target -> [(table, column)]
for a, c, b in edges:
    refs[a].append((c, b)); refd[b].append((a, c))
drawn = set()                 # (table, column) of every foreign key drawn in a diagram

def arrows(svg, pairs):
    """One arrow per pair of tables, labelled with every column of the referring table that refers to the other."""
    by = defaultdict(list)
    for a, c, b in edges:
        if a in svg.boxes and b in svg.boxes and (a, b) in pairs and a != b:
            by[(a, b)].append(c)
    for (a, b), cols in by.items():
        lx, ly = pairs[(a, b)]
        svg.arrow(a, b, ", ".join(cols), lx=lx, ly=ly)
        for c in cols: drawn.add((a, c))

def tbox(svg, name, x, y, w=150, h=34, cls="box"):
    svg.box(name, x, y, w, h, name, cls=cls)

# --- 1. the files at a glance ------------------------------------------------------------------------------------
n = {o: len(d["tables"]) for o, d in db.items()}
g = Svg(1040, 360, "The workspace folder holds workspace.db and one SQLite file per schema; each schema file holds the cortex's tables and its own engine's tables only.")
g.band(10, 10, 1020, 310, "~/.schema-forge/workspaces/<name>/")
g.box("ws", 40, 60, 250, 120, "workspace.db", f"{n['workspace']} tables: schemas, connections", cls="file")
g.text(165, 118, "owner workspace", "lb", "middle")
g.box("lock", 40, 220, 250, 44, "workspace.lock", "held while one store is open", cls="box")
g.band(330, 40, 690, 270, "schemas/")
g.box("f1", 360, 80, 300, 200, "schemas/shop.db", "a MySQL schema", cls="file")
g.box("c1", 380, 140, 130, 120, "cortex", f"{n['cortex']} tables", cls="pri")
g.box("e1", 520, 140, 120, 120, "mysql__", f"{n['mysql']} tables", cls="eng")
g.box("f2", 690, 80, 300, 200, "schemas/notes.db", "a Quill schema", cls="file")
g.box("c2", 710, 140, 130, 120, "cortex", f"{n['cortex']} tables", cls="pri")
g.box("e2", 850, 140, 120, 120, "quill__", f"{n['quill']} table", cls="eng")
g.parts.append('<line x1="290" y1="150" x2="358" y2="150" class="es" marker-end="url(#mks)"/>')
g.text(20, 346, "- - -  schemas.id in workspace.db = the file's own schema.id (UUIDv7): a reference between files, checked by the store", "lb m")
g.containers = {"ws", "f1", "f2"}   # boxes drawn to hold others and their text
files_svg = g.render()

# --- 2. the model ----------------------------------------------------------------------------------------------
g = Svg(1040, 520, "The model's tables and every foreign key between them.")
for name, x, y in [("kinds", 40, 40), ("namespaces", 300, 40), ("kept", 560, 40), ("areas", 820, 40),
                   ("objects", 300, 190), ("schema", 860, 190), ("requirements", 860, 250),
                   ("object_tags", 20, 330), ("object_reads", 190, 330), ("columns", 380, 330), ("links", 640, 330),
                   ("column_identities", 380, 450), ("link_columns", 640, 450)]:
    if name == "schema":
        g.box("schema", x - 10, y, 176, 46, "schema", "one row: this file's schema", cls="pri")
    elif name == "requirements":
        g.box("requirements", x, y + 20, 160, 34, "requirements")
    else:
        tbox(g, name, x, y, 160 if name == "column_identities" else 150, cls="pri" if name == "objects" else "box")
arrows(g, {("objects", "kinds"): (0, 0), ("objects", "namespaces"): (8, 0), ("objects", "areas"): (0, 0),
           ("kept", "namespaces"): (0, 0), ("kept", "objects"): (0, 0), ("object_tags", "objects"): (0, 0),
           ("object_reads", "objects"): (0, 0), ("columns", "objects"): (0, 0), ("links", "objects"): (16, 0),
           ("column_identities", "columns"): (0, 0), ("link_columns", "links"): (0, 0), ("link_columns", "columns"): (0, 10)})
g.loop("namespaces", "parent", "left"); drawn.add(("namespaces", "parent"))
model_svg = g.render()

# --- 3. what an object holds -------------------------------------------------------------------------------------
g = Svg(1100, 620, "What an object holds: the shared section layout as tables, each referring to its object, and the tables of their parts.")
one = ["queries", "sequences", "domains", "routines", "triggers", "events", "partitionings", "partition_of"]
many = ["keys", "checks", "indexes", "order_fields", "enum_values", "type_fields"]
xs1 = {nm: 26 + i * 132 for i, nm in enumerate(one)}
for nm in one: tbox(g, nm, xs1[nm], 150, 122)
tbox(g, "objects", 475, 300, 150, 40, "pri")
xs2 = {nm: 40 + i * 175 for i, nm in enumerate(many)}
for nm in many: tbox(g, nm, xs2[nm], 440, 140)
tbox(g, "parameters", xs1["routines"], 40, 122)
tbox(g, "trigger_events", xs1["triggers"] - 4, 40, 130)
tbox(g, "partition_fields", xs1["partitionings"] - 8, 40, 130)
tbox(g, "partitions", xs1["partition_of"] + 6, 40, 116)
tbox(g, "key_columns", xs2["keys"], 560, 140)
tbox(g, "index_parts", xs2["indexes"] - 76, 560, 140)
tbox(g, "index_includes", xs2["indexes"] + 76, 560, 140)
pairs = {(nm, "objects"): (0, 0) for nm in one + many}
pairs.update({("parameters", "routines"): (0, 0), ("trigger_events", "triggers"): (0, 0), ("partition_fields", "partitionings"): (-34, 0),
              ("partitions", "partitionings"): (34, 14), ("key_columns", "keys"): (0, 0), ("index_parts", "indexes"): (0, 0),
              ("index_includes", "indexes"): (0, 0)})
arrows(g, pairs)
parts_svg = g.render()

# --- 4. the log ------------------------------------------------------------------------------------------------
g = Svg(1040, 250, "The log: turns, their operations, every row and value each operation changed, and the versions locked on it.")
for name, x, y in [("turns", 40, 70), ("operations", 300, 70), ("row_changes", 560, 70), ("value_changes", 820, 70), ("versions", 300, 180)]:
    g.box(name, x, y, 180, 40, name, cls="lg")
arrows(g, {("operations", "turns"): (0, 0), ("row_changes", "operations"): (0, 0), ("value_changes", "row_changes"): (0, 0),
           ("versions", "operations"): (40, 0)})
g.loop("turns", "undoes"); drawn.add(("turns", "undoes"))
g.text(760, 150, "row_changes.table_name and row_id name the row changed, in any table of the file", "lb", "middle")
g.text(40, 30, "every id here is a UUIDv7 issued in increasing order: its order is the order of commit", "lb")
log_svg = g.render()

# --- 5. the workspace ------------------------------------------------------------------------------------------
g = Svg(1040, 200, "workspace.db: its schemas, by stable id, and the saved connections with their values and tests.")
for name, x, y in [("workspace", 30, 30), ("schema_migrations", 30, 120), ("schemas", 220, 70), ("connections", 420, 70),
                   ("connection_values", 720, 20), ("connection_tests", 660, 125), ("connection_test_steps", 860, 125)]:
    tbox(g, name, x, y, 160 if name != "connection_test_steps" else 170)
arrows(g, {("connection_values", "connections"): (0, 0), ("connection_tests", "connections"): (0, 0),
           ("connection_test_steps", "connection_tests"): (0, 0)})
g.text(300, 130, "a schema file, by its id", "lb", "middle")
ws_svg = g.render()

# --- 6. each engine's tables against the cortex -------------------------------------------------------------------
def engine_svg(owner):
    tabs = [t["name"] for t in db[owner]["tables"]]
    out = {a: [(c, b) for c, b in refs[a]] for a in tabs}
    targets = []
    for a in tabs:
        for c, b in out[a]:
            if b not in tabs and b not in targets: targets.append(b)
    order = [nm for o in ("cortex",) for nm in [t["name"] for t in db[o]["tables"]]]
    targets.sort(key=lambda b: order.index(b))
    def rank(a):
        b = next((b for c, b in out[a] if b in targets), None)
        if b is not None: return targets.index(b)
        if out[a]:      # refers to another table of the engine: placed just after it
            return rank(out[a][0][1]) + 0.5
        return len(targets)   # refers to nothing by a foreign key: last, its integrity query checks it
    tabs.sort(key=lambda a: (rank(a), a))
    rows = max(len(tabs), len(targets))
    h = 40 + rows * 42
    g = Svg(1040, h, f"Every table of {owner} and the cortex table each refers to.")
    g.text(110, 22, "cortex", "cap", "middle"); g.text(640, 22, owner, "cap", "middle")
    step_t = (rows * 42) / max(1, len(targets))
    for i, b in enumerate(targets): tbox(g, b, 40, 34 + i * step_t + (step_t - 34) / 2, 160, cls="pri")
    for i, a in enumerate(tabs):
        tbox(g, a, 520, 34 + i * 42, 250, cls="eng")
        if not out[a]: g.text(500, 34 + i * 42 + 22, "no foreign key: an integrity query checks its id", "lb", "end")
    pairs = {}
    for a in tabs:
        for c, b in out[a]: pairs[(a, b)] = (0, 0)
    by = defaultdict(list)
    for a in tabs:
        for c, b in out[a]: by[(a, b)].append(c)
    for (a, b), cols in by.items():
        if b in tabs:   # within the engine: a curve on the right
            ax, ay, aw, ah = g.boxes[a]; bx, by_, bw, bh = g.boxes[b]
            g.parts.append(f'<path d="M{ax + aw},{ay + ah / 2} C{ax + aw + 60},{ay + ah / 2} {bx + bw + 60},{by_ + bh / 2} {bx + bw + 2},{by_ + bh / 2}" class="ea" fill="none" marker-end="url(#mka)"/>')
            g.text(ax + aw + 70, (ay + by_ + ah) / 2 + 4, ", ".join(cols), "lb m")
        else:   # from the engine table's left edge, so no line crosses another engine table
            ax, ay, aw, ah = g.boxes[a]; bx, by_, bw, bh = g.boxes[b]
            x1, y1, x2, y2 = ax, ay + ah / 2, bx + bw + 2, by_ + bh / 2
            g.parts.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" class="ea" marker-end="url(#mka)"/>')
            g.lines.append((a, b, x1, y1, x2, y2))
            g.text(ax - 6, ay + 13, ", ".join(cols), "lb m", "end")
        for c in cols: drawn.add((a, c))
    return g.render()

engine_svgs = {o: engine_svg(o) for o in db if o not in ("cortex", "workspace")}

# every foreign key of the cortex but the parts' references to columns (listed with each table) is drawn
undrawn = [(a, c, b) for a, c, b in edges if (a, c) not in drawn]

# --- the tables ------------------------------------------------------------------------------------------------
GROUPS = [("cortex", "The model", ["schema", "kinds", "namespaces", "areas", "objects", "columns", "column_identities", "links", "link_columns", "object_tags", "object_reads", "kept", "requirements"]),
          ("cortex", "What an object holds", ["keys", "key_columns", "checks", "indexes", "index_parts", "index_includes", "partitionings", "partition_fields", "partitions", "partition_of", "order_fields", "queries", "sequences", "enum_values", "domains", "type_fields", "routines", "parameters", "triggers", "trigger_events", "events"]),
          ("cortex", "The log", ["turns", "operations", "row_changes", "value_changes", "versions"]),
          ("cortex", "The file", ["schema_migrations"])]
grouped = {nm for _, _, l in GROUPS for nm in l}
missing = [t["name"] for t in db["cortex"]["tables"] if t["name"] not in grouped]
assert not missing, f"cortex tables in no group: {missing}"
for o in db:
    if o != "cortex":
        GROUPS.append((o, {"workspace": "workspace.db"}.get(o, f"{o}'s own tables"), [t["name"] for t in db[o]["tables"]]))

def id_pattern(t):
    for c in t["constraints"]:
        m = re.match(r"CHECK \(id = (.*)\)$", c)
        if m:
            parts = [p.strip() for p in m.group(1).split("||")]
            return "".join(f"<{p}>" if not p.startswith("'") else p.strip("'") for p in parts)
    idc = next((c for c in t["columns"] if c["name"] == "id"), None)
    if idc and idc["check"] and "36" in idc["check"]: return "UUIDv7"
    if idc and idc["ref"]: return f"the id of its {idc['ref'][:-1] if idc['ref'].endswith('s') else idc['ref']} ({idc['ref']}.id)"
    if idc and idc["check"] and "GLOB" in idc["check"]:
        m = re.search(r"GLOB '(\w)_\*'", idc["check"]); return f"the model's id ({m.group(1)}_…)" if m else "the model's id"
    return "its name"

def integrity_for(name):
    out = []
    for o, d in db.items():
        for q in d["integrity"]:
            if re.search(rf"\b{re.escape(name)}\b", q["sql"]): out.append((o, q))
    return out

def table_html(o, t):
    nm = t["name"]
    rows = ""
    for c in t["columns"]:
        key = "PK" if c["pk"] else ("unique" if c["unique"] else "")
        ref = f'<a href="#t-{e(c["ref"])}"><code>{e(c["ref"])}</code></a>' + (f' <span class="small">on delete {e(c["on_delete"].lower())}</span>' if c["on_delete"] else "") if c["ref"] else ""
        chk = f'<div class="small">check: <code>{e(c["check"])}</code></div>' if c["check"] and not c["ref"] else ""
        dflt = f'<div class="small">default {e(c["default"])}</div>' if c["default"] else ""
        rows += (f'<tr><td><code>{e(c["name"])}</code></td><td class="ty">{c["type"]}</td><td class="nn">{"not null" if c["not_null"] or c["pk"] else "null"}</td>'
                 f'<td>{key}</td><td>{ref}</td><td>{e(c["comment"])}{dflt}{chk}</td></tr>')
    by = sorted(set(refd[nm]))
    byh = ", ".join(f'<a href="#t-{e(a)}"><code>{e(a)}</code></a>.{e(c)}' for a, c in by) or "none"
    cons = "".join(f"<li><code>{e(c)}</code></li>" for c in t["constraints"] + t["indexes"])
    ints = "".join(f'<li><code>{e(q["name"])}</code> <span class="small">({e(oo)})</span> {e(q["says"])}</li>' for oo, q in integrity_for(nm))
    owner_cls = "ok" if o == "cortex" else ("eng" if o not in ("workspace",) else "")
    notes = " ".join(t["notes"])
    return (f'<article class="tbl" id="t-{e(nm)}"><h3><code class="tn">{e(nm)}</code><span class="pill {owner_cls}">{e(o)}</span><span class="path">{e(t["file"])}</span></h3>'
            f'<p class="lede">{e(t["about"][:1].upper() + t["about"][1:])}{(" " + e(notes)) if notes else ""}</p>'
            f'<p class="meta"><span class="lab">Row id</span><code>{e(id_pattern(t))}</code> · {len(t["columns"])} columns · <span class="lab">Referred to by</span>{byh}</p>'
            f'<div class="scroll"><table class="t cols"><thead><tr><th>Column</th><th>Type</th><th>Null</th><th>Key</th><th>Refers to</th><th>What it holds</th></tr></thead><tbody>{rows}</tbody></table></div>'
            + (f'<div class="cons"><span class="lab">Also</span><ul>{cons}</ul></div>' if cons else "")
            + (f'<div class="cons"><span class="lab">Integrity queries on it</span><ul>{ints}</ul></div>' if ints else "")
            + f'<details><summary>CREATE TABLE, as the file holds it</summary><pre>{e(t["text"].strip())}</pre></details></article>')

toc, body_tables = "", ""
for o, title, names in GROUPS:
    toc += f'<div class="tg"><span class="lab">{e(o)} · {e(title)}</span>' + " ".join(f'<a href="#t-{e(x)}"><code>{e(x)}</code></a>' for x in names) + "</div>"
    body_tables += f'<h2 class="grp" id="g-{e(o)}-{re.sub("[^a-z]+", "-", title.lower())}">{e(title)} <span class="path">{e(o)} · {len(names)} tables</span></h2>'
    body_tables += "".join(table_html(o, T[x][1]) for x in names)

# --- integrity --------------------------------------------------------------------------------------------------
integ = ""
for o, d in db.items():
    if not d["integrity"]: continue
    integ += f'<h3>{e(o)} <span class="path">{e(d["folder"])}/integrity.sql · {len(d["integrity"])} queries</span></h3><div class="scroll"><table class="t"><thead><tr><th>Query</th><th>What it requires</th><th>SQL</th></tr></thead><tbody>'
    for q in d["integrity"]:
        integ += f'<tr><td><code>{e(q["name"])}</code></td><td>{e(q["says"])}</td><td><details><summary class="small">the query</summary><pre>{e(q["sql"])}</pre></details></td></tr>'
    integ += "</tbody></table></div>"

# --- decisions that shaped it ---------------------------------------------------------------------------------------
root = ET.parse(f"{REPO}/specs/root.xml").getroot()
dec = ""
for d in root.find("decisions").findall("decision"):
    w = d.get("where") or ""
    if d.get("status") == "confirmed" and ("schema" in w or "engine" in w):
        dec += f'<tr><td><code>{e(d.get("id"))}</code></td><td>{e(" ".join("".join(d.itertext()).split()))}</td><td class="small">{e(d.get("date"))}</td></tr>'
opend = "".join(f'<li><code>{e(d.get("id"))}</code> {e(" ".join("".join(d.itertext()).split()))} <span class="pill open">before {e(d.get("closes-before"))}</span></li>'
                for d in root.find("decisions").findall("decision") if d.get("status") == "open")

ntab = sum(len(d["tables"]) for d in db.values())
nq = sum(len(d["integrity"]) for d in db.values())
CSS = """
.tg{margin:4px 0;display:flex;flex-wrap:wrap;gap:4px 8px;align-items:baseline}.tg a{text-decoration:none}
.tbl{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:14px 0;min-width:0}
.tbl h3{margin:0 0 4px}.tn{font-size:16px;font-weight:600;background:none;border:0;padding:0}
.meta{font-size:13px;color:var(--muted)}
table.cols td{font-size:13.5px}table.cols td:first-child{white-space:nowrap}.ty{font:12.5px var(--mono)}.nn{font-size:12.5px;color:var(--muted)}
.cons ul{margin:4px 0 0;padding-left:18px;font-size:13.5px}.cons{margin-top:8px}
h2.grp{margin-top:44px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:16px 0 0}
.stats div{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px 14px}
.stats b{display:block;font:700 30px/1 var(--head);font-variant-numeric:tabular-nums}.stats span{font-size:12.5px;color:var(--muted)}
.legend{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:13px;color:var(--muted);margin-top:8px}
.sw{display:inline-block;width:14px;height:14px;border-radius:3px;vertical-align:-2px;margin-right:5px;border:1.4px solid}
"""
legend = ('<div class="legend"><span><i class="sw" style="background:var(--accent-soft);border-color:var(--accent)"></i>cortex, emphasised</span>'
          '<span><i class="sw" style="background:var(--surface);border-color:var(--ink2)"></i>cortex table</span>'
          '<span><i class="sw" style="background:var(--engine-soft);border-color:var(--engine)"></i>an engine\'s table</span>'
          '<span><i class="sw" style="background:var(--log-soft);border-color:var(--log)"></i>the log</span>'
          '<span>→ a foreign key, labelled with its columns</span></div>')
eng_figs = "".join(f'<h3>{e(o)}\'s tables <span class="path">{e(db[o]["folder"])}</span></h3><figure>{s}<figcaption>Every table of {e(o)}, on the right, and the cortex table each refers to, on the left; a table that refers to another of {e(o)}\'s is joined to it on the right. Each lives in the same file as the cortex rows it refers to, so SQLite enforces every reference.</figcaption></figure>' for o, s in engine_svgs.items())
undrawn_note = ", ".join(f"<code>{e(a)}.{e(c)}</code>" for a, c, b in undrawn)
body = f"""
<div class="tb" role="group" aria-label="Title block">
  <div><span>Engine</span><b>SQLite</b></div><div><span>Files</span><b>workspace.db · schemas/&lt;name&gt;.db</b></div>
  <div><span>Tables</span><b>{ntab}</b></div><div><span>Integrity queries</span><b>{nq}</b></div><div><span>Date</span><b>2026-11-24</b></div>
</div>
<h1>Schema Forge Database <span class="draft">Draft 1</span></h1>
<p class="lede">Every table Schema Forge keeps its work in, designed first and locked: no build creates or changes one. The cortex is what every
engine shares; each engine ships its own tables in its plugin, in the same file as the cortex rows they refer to, so SQLite enforces every
reference. Tables are <code>STRICT</code>, every column is documented, and what a foreign key cannot say is a query of an <code>integrity.sql</code>,
run before every commit. Everything below is read from the schema folders.</p>
<div class="stats">{''.join(f'<div><b>{len(d["tables"])}</b><span>{e(o)} tables · {e(d["folder"])}</span></div>' for o, d in db.items())}</div>

<section id="files"><h2>The files</h2>
<p class="lede">A workspace is a folder. <code>workspace.db</code> holds what the workspace shares; each schema is its own file, for less contention, holding the cortex's tables and its engine's tables, and no other engine's.</p>
<figure>{files_svg}<figcaption>One store holds a workspace at a time (the lock). A schema file names itself by its own stable id; <code>workspace.db</code> lists each by that id, a reference between files that the store checks, since SQLite enforces foreign keys only within a file.</figcaption></figure></section>

<section id="model"><h2>The model</h2><p class="lede">Namespaces hold objects (tables, views, routines, whatever kinds the engine declares); objects have columns; links join columns of one object to another's. An object's kind must be one its engine declared: the foreign key to <code>kinds</code> refuses any other.</p>
<figure>{model_svg}<figcaption>Every foreign key between these tables. A part's primary key is the model's own id (<code>o_orders</code>, <code>c_orders_total</code>), kept when it is renamed.</figcaption>{legend}</figure></section>

<section id="parts"><h2>What an object holds</h2><p class="lede">The shared section layout, as tables: what every engine can say of an object. A kind fills only the parts it uses; an integrity query refuses keys, indexes or a partitioning on a kind that holds no keys, and more than one of a query, routine, trigger, event, sequence or domain on one object.</p>
<figure>{parts_svg}<figcaption>Top row: one row per object at most, its id the object's. Bottom row: any number per object, in order. The outer rows are their parts. Not drawn, listed with each table: {undrawn_note}.</figcaption></figure></section>

<section id="log"><h2>The log</h2><p class="lede">Every change is an operation of a turn, appended and never edited; the current model is written in the same transaction. Each operation records every row it inserted, updated or deleted and every value it set, so its inverse is worked out from the record: undo and reject apply it as a new turn, and replaying the log rebuilds the model.</p>
<figure>{log_svg}<figcaption>A turn is the agent's answer to one prompt, a person's edit, or an import; it is accepted or rejected whole. A rejected turn stays, marked, and the turn that takes it back names it in <code>undoes</code>.</figcaption></figure></section>

<section id="workspace"><h2>The workspace</h2><p class="lede"><code>workspace.db</code>: the schemas by their stable ids, and the saved connections. A connection keeps the value of each field its engine declares, never a secret.</p>
<figure>{ws_svg}</figure></section>

<section id="engines"><h2>Each engine's tables</h2><p class="lede">What one engine alone says (MySQL's charset and row format, Quill's fast records) lives in that engine's tables, named <code>&lt;engine&gt;__&lt;name&gt;</code>, each referring to the cortex row it belongs to.</p>{eng_figs}</section>

<section id="tables"><h2>Every table</h2><p class="lede">Grouped as above. Each with what it holds, how its row is named, its columns, what refers to it, its constraints, the integrity queries that read it, and its file whole.</p>{toc}</section>
{body_tables}

<section id="integrity"><h2>Integrity queries</h2><p class="lede">What a foreign key cannot say. Each query returns the rows that break its rule; the store runs every one before it commits, and one row refuses the commit, naming the query and the row.</p>{integ}</section>

<section id="decisions"><h2>Decisions</h2><p class="lede">What was decided with the operator, and where it now lives. The open ones close in a design session before the task that needs them.</p>
<div class="scroll"><table class="t"><thead><tr><th>Decision</th><th>What</th><th>Date</th></tr></thead><tbody>{dec}</tbody></table></div>
<h3>Still open</h3><ul class="small">{opend}</ul></section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("files", "Files"), ("model", "Model"), ("parts", "Object parts"), ("log", "Log"), ("workspace", "Workspace"), ("engines", "Engines"), ("tables", "Every table"), ("integrity", "Integrity"), ("decisions", "Decisions")])
HTML = page("database", "Schema Forge Database", CSS, body, sub)
