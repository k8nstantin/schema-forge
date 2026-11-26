"""The Database page: every table of the cortex, the workspace and each engine, drawn and listed from the schema
folders. Every arrow of every diagram is a foreign key a file declares; every column is read from its file."""
import re
import xml.etree.ElementTree as ET
from collections import defaultdict
from common import REPO, Svg, database, e, page, short

db, edges = database()
# every table of a design refers to cortex.designs by its column design: said once, in the captions, not drawn on each
edges = [(a, c, b) for a, c, b in edges if not (c == "design" and not a.startswith("cortex.workspace_"))]
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
    """A table's box: keyed by its full name (cortex.objects), titled by its short one."""
    svg.box(name, x, y, w, h, short(name), cls=cls, href=f"#t-{name}")

def C(name): return "cortex." + name

# --- 1. the database at a glance ------------------------------------------------------------------------------
n = {o: len(d["tables"]) for o, d in db.items()}
g = Svg(1040, 400, "The workspace folder holds its own PostgreSQL cluster; the cluster holds one database, schema_forge, with one namespace per owner, and every design is rows of its tables.")
g.band(10, 10, 1020, 350, "~/.schema-forge/workspaces/<name>/")
g.box("sock", 40, 60, 250, 50, "Unix socket", "in the folder: no network port", cls="box")
g.box("app", 40, 150, 250, 50, "the app (the store)", "the one process that opens it", cls="box")
g.band(330, 40, 690, 310, "pgdata/: PostgreSQL 18, bundled")
g.box("db", 360, 80, 640, 250, "schema_forge", "the one database, installed once", cls="file")
g.box("c", 380, 140, 190, 60, "cortex", f"{n['cortex']} tables", cls="pri")
g.box("u", 590, 140, 190, 60, "ui", f"{n['ui']} tables", cls="box")
engines = [o for o in db if o.startswith("engine_")]
for i, o in enumerate(engines):
    g.box(f"e{i}", 380 + i * 210, 230, 190, 60, o, f"{n[o]} tables", cls="eng")
g.parts.append('<line x1="165" y1="150" x2="165" y2="112" class="es" marker-end="url(#mks)"/>')
g.parts.append('<line x1="290" y1="85" x2="358" y2="100" class="es" marker-end="url(#mks)"/>')
g.text(20, 386, "- - -  a design is a row of cortex.designs (its UUIDv7) and the rows that point at it: never a database, a schema or a table of its own", "lb m")
g.containers = {"db"}   # boxes drawn to hold others and their text
files_svg = g.render()

# --- 2. the model ----------------------------------------------------------------------------------------------
g = Svg(1060, 540, "The model's tables and every foreign key between them.")
for name, x, y, w in [("object_kinds", 20, 40, 150), ("namespaces", 300, 40, 150), ("verbatim_statements", 560, 40, 170),
                      ("designs", 860, 40, 160), ("required_extensions", 860, 110, 160),
                      ("objects", 300, 190, 150), ("object_tags", 20, 340, 150), ("dependencies", 190, 340, 150),
                      ("columns", 380, 340, 150), ("constraints", 640, 340, 150),
                      ("column_identities", 380, 460, 160), ("constraint_columns", 640, 460, 180)]:
    tbox(g, C(name), x, y, w, cls="pri" if name == "objects" else "box")
arrows(g, {(C("objects"), C("object_kinds")): (0, 0), (C("objects"), C("namespaces")): (8, 0),
           (C("verbatim_statements"), C("namespaces")): (0, 0), (C("verbatim_statements"), C("objects")): (0, 0),
           (C("object_tags"), C("objects")): (0, 0), (C("dependencies"), C("objects")): (0, 0), (C("columns"), C("objects")): (0, 0),
           (C("constraints"), C("objects")): (16, 0), (C("column_identities"), C("columns")): (0, 0),
           (C("constraint_columns"), C("constraints")): (0, 0), (C("constraint_columns"), C("columns")): (0, 10)})
g.loop(C("namespaces"), "parent", "left"); drawn.add((C("namespaces"), "parent"))
g.loop(C("objects"), "parent", "left"); drawn.add((C("objects"), "parent"))
model_svg = g.render()

# --- 3. what an object holds -------------------------------------------------------------------------------------
g = Svg(1280, 620, "What an object holds: one row at most per object for what it is, and the lists of its parts.")
one = ["views", "routines", "triggers", "sequences", "domains", "partitionings"]
many = ["indexes", "enum_values"]
xs1 = {nm: 40 + i * 205 for i, nm in enumerate(one)}
for nm in one: tbox(g, C(nm), xs1[nm], 150, 160)
tbox(g, C("objects"), 565, 300, 150, 40, "pri")
xs2 = {nm: 200 + i * 330 for i, nm in enumerate(many)}
for nm in many: tbox(g, C(nm), xs2[nm], 440, 172)
tbox(g, C("routine_parameters"), xs1["routines"], 40, 160)
tbox(g, C("partitions"), xs1["partitionings"], 40, 160)
tbox(g, C("index_parts"), xs2["indexes"], 560, 172)
pairs = {(C(nm), C("objects")): (0, 0) for nm in one + many}
pairs.update({(C("routine_parameters"), C("routines")): (0, 0), (C("partitions"), C("partitionings")): (0, 0),
              (C("index_parts"), C("indexes")): (0, 0)})
arrows(g, pairs)
parts_svg = g.render()

# --- 4. the log ------------------------------------------------------------------------------------------------
g = Svg(1040, 250, "The log: branches of turns, their operations, every row each operation changed, savepoints and the versions locked on it.")
for name, x, y in [("branches", 40, 180), ("turns", 40, 70), ("operations", 300, 70), ("row_changes", 560, 70), ("savepoints", 300, 180),
                   ("locked_versions", 560, 180)]:
    g.box(C(name), x, y, 180, 40, name, cls="lg", href=f"#t-{C(name)}")
arrows(g, {(C("turns"), C("branches")): (0, 0), (C("operations"), C("turns")): (0, 0), (C("row_changes"), C("operations")): (0, 0),
           (C("savepoints"), C("turns")): (0, 0), (C("locked_versions"), C("turns")): (40, 0)})
g.loop(C("turns"), "parent"); drawn.add((C("turns"), "parent"))
g.loop(C("turns"), "undoes", "left"); drawn.add((C("turns"), "undoes"))
g.text(820, 150, "row_changes.table_name and row_id name the row changed, in any table of the design", "lb", "middle")
g.text(40, 30, "turns, operations and versions are UUIDv7s the database issues; row_changes keep a row's values before and after as JSONB", "lb")
log_svg = g.render()

# --- 5. the workspace ------------------------------------------------------------------------------------------
g = Svg(1040, 300, "The workspace, in the cortex: the saved connections with their values and tests, and the connection each design is read from.")
for name, x, y, w in [("workspace_identity", 20, 20, 200), ("workspace_parameters", 20, 100, 200), ("designs", 20, 220, 150),
                      ("workspace_design_connections", 260, 220, 240), ("workspace_connections", 560, 110, 210),
                      ("workspace_connection_values", 810, 20, 220), ("workspace_connection_tests", 810, 220, 220)]:
    tbox(g, C(name), x, y, w)
arrows(g, {(C("workspace_connection_values"), C("workspace_connections")): (0, 0), (C("workspace_connection_tests"), C("workspace_connections")): (0, 0),
           (C("workspace_design_connections"), C("workspace_connections")): (0, 0), (C("workspace_design_connections"), C("designs")): (0, 0)})
ws_svg = g.render()

CORTEX_ORDER = [(None, None, ["designs", "namespaces", "objects", "columns", "column_identities", "constraints", "constraint_columns",
                                "indexes", "index_parts", "partitionings", "partitions", "views", "sequences", "enum_values", "domains",
                                "routines", "routine_parameters", "triggers"])]

# --- 6. each engine's tables against the cortex -------------------------------------------------------------------
def engine_svg(owner):
    tabs = [t["name"] for t in db[owner]["tables"]]
    out = {a: [(c, b) for c, b in refs[a]] for a in tabs}
    targets = []
    for a in tabs:
        for c, b in out[a]:
            if b not in tabs and b not in targets: targets.append(b)
    order = [C(nm) for _, _, names in CORTEX_ORDER for nm in names]   # the cortex in reading order: namespaces before objects before their parts
    targets.sort(key=lambda b: order.index(b) if b in order else len(order))
    def rank(a):
        ts = [targets.index(b) for c, b in out[a] if b in targets]
        if ts: return min(ts)
        if out[a]:      # refers to another table of the engine: placed just after it
            return rank(out[a][0][1]) + 0.5
        return len(targets)   # refers to nothing by a foreign key: last, a rule checks it
    tabs.sort(key=lambda a: (rank(a), a))
    rows = max(len(tabs), len(targets))
    h = 40 + rows * 42
    g = Svg(1040, h, f"Every table of {owner} and the cortex table each refers to.")
    g.text(120, 22, "cortex", "cap", "middle"); g.text(645, 22, owner, "cap", "middle")
    step_t = (rows * 42) / max(1, len(targets))
    for i, b in enumerate(targets): tbox(g, b, 30, 34 + i * step_t + (step_t - 34) / 2, 180, cls="pri")
    for i, a in enumerate(tabs):
        tbox(g, a, 520, 34 + i * 42, 250, cls="eng")
        if not out[a]: g.text(500, 34 + i * 42 + 22, "no foreign key: a rule checks its id", "lb", "end")
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
            k = sum(1 for (a2, b2) in list(by)[:list(by).index((a, b))] if a2 == a and b2 not in tabs)   # a second arrow's label below the first
            g.text(ax - 6, ay + 13 + k * 14, ", ".join(cols), "lb m", "end")
        for c in cols: drawn.add((a, c))
    return g.render()

engine_svgs = {o: engine_svg(o) for o in db if o.startswith("engine_")}

# every foreign key of the cortex but the parts' references to columns (listed with each table) is drawn
undrawn = [(a, c, b) for a, c, b in edges if (a, c) not in drawn]

# --- the tables ------------------------------------------------------------------------------------------------
GROUPS = [("cortex", "The model", ["designs", "namespaces", "objects", "columns", "column_identities",
                                    "constraints", "constraint_columns", "object_tags", "dependencies", "verbatim_statements",
                                    "required_extensions"]),
          ("cortex", "What an object holds", ["indexes", "index_parts", "partitionings", "partitions", "views", "sequences",
                                              "enum_values", "domains", "routines", "routine_parameters", "triggers"]),
          ("cortex", "The log", ["branches", "turns", "operations", "row_changes", "savepoints", "locked_versions"]),
          ("cortex", "What each engine declares", ["engine_versions", "engine_features", "object_kinds", "option_declarations", "catalog_sources"]),
          ("cortex", "The live source", ["read_scopes", "read_scope_kinds", "read_scope_objects", "source_reads"]),
          ("cortex", "The workspace", ["workspace_identity", "workspace_parameters", "workspace_connections", "workspace_connection_values",
                                       "workspace_connection_tests", "workspace_connection_test_steps", "workspace_design_connections"]),
          ("cortex", "The database", ["schema_migrations"])]
GROUPS = [(o, title, [f"{o}.{nm}" for nm in names]) for o, title, names in GROUPS]
grouped = {nm for _, _, l in GROUPS for nm in l}
missing = [t["name"] for t in db["cortex"]["tables"] if t["name"] not in grouped]
assert not missing, f"cortex tables in no group: {missing}"
for o in db:
    if o != "cortex":
        GROUPS.append((o, {"ui": "ui: what the tool shows and people keep of it, versioned with the design", "usage": "usage: what the live server measured, apart from the design"}.get(o, f"{o}: the engine's own tables"), [t["name"] for t in db[o]["tables"]]))

def id_pattern(t):
    idc = next((c for c in t["columns"] if c["name"] == "id"), None)
    for c in t["constraints"]:
        m = re.match(r"CHECK \(id = (.*)\)$", c)
        if m:
            parts = [p.strip() for p in m.group(1).split("||")]
            return "".join(f"<{p}>" if not p.startswith("'") else p.strip("'") for p in parts)
        m = re.match(r"CHECK \(substr\(id, 1, length\((\"?\w+\"?)\) \+ \d+\) = \S+ \|\| '([^']*)'", c)
        if m:
            return f"<{m.group(1).strip(chr(34))}>{m.group(2)}<n>"
        m = re.match(r"CHECK \(left\(id, 37\) = (\w+)::text \|\| '\.'", c)
        if m:
            return f"<{m.group(1)}>.<n>"
    if idc and idc["type"] == "UUID" and not idc["ref"]: return "UUIDv7, made with the row"
    if idc and idc["ref"]: return f"the id of its {short(idc['ref'])} row ({short(idc['ref'])}.id)"
    if idc and idc["check"]:
        m = re.search(r"id ~ '\^(\w)_", idc["check"])
        if m: return f"the model's id ({m.group(1)}_…)"
        m = re.search(r"id ~ '\^(\w+?)\[1-9\]", idc["check"])
        if m: return f"{m.group(1)}<n>"
    return "its name"

def rules_for(name):
    out = []
    for o, d in db.items():
        for q in d["rules"]:
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
        rows += (f'<tr><td><code>{e(c["name"])}</code></td><td class="ty">{c["type"].lower()}</td><td class="nn">{"not null" if c["not_null"] or c["pk"] else "null"}</td>'
                 f'<td>{key}</td><td>{ref}</td><td>{e(c["comment"])}{dflt}{chk}</td></tr>')
    by = sorted(set(refd[nm]))
    byh = ", ".join(f'<a href="#t-{e(a)}"><code>{e(a)}</code></a>.{e(c)}' for a, c in by) or "none"
    cons = "".join(f"<li><code>{e(c)}</code></li>" for c in t["constraints"] + t["indexes"])
    rl = "".join(f'<li><a href="#r-{e(q["name"])}-{e(oo)}"><code>{e(q["name"])}</code></a> <span class="small">({e(oo)})</span> {e(q["says"])}</li>' for oo, q in rules_for(nm))
    owner_cls = "ok" if o == "cortex" else ("eng" if o.startswith("engine_") else "")
    notes = " ".join(t["notes"])
    return (f'<article class="tbl" id="t-{e(nm)}"><h3><code class="tn">{e(nm)}</code><span class="pill {owner_cls}">{e(o)}</span><span class="path">{e(t["file"])}</span></h3>'
            f'<p class="lede">{e(t["about"][:1].upper() + t["about"][1:])}{(" " + e(notes)) if notes else ""}</p>'
            f'<p class="meta"><span class="lab">Row id</span><code>{e(id_pattern(t))}</code> · {len(t["columns"])} columns · <span class="lab">Referred to by</span>{byh}</p>'
            f'<div class="scroll"><table class="t cols"><thead><tr><th>Column</th><th>Type</th><th>Null</th><th>Key</th><th>Refers to</th><th>What it holds</th></tr></thead><tbody>{rows}</tbody></table></div>'
            + (f'<div class="cons"><span class="lab">Also</span><ul>{cons}</ul></div>' if cons else "")
            + (f'<div class="cons"><span class="lab">Rules that read it</span><ul>{rl}</ul></div>' if rl else "")
            + f'<details><summary>The file, whole: its CREATE TABLE and the comments the database holds</summary><pre>{e(t["text"].strip())}</pre></details></article>')

toc, body_tables = "", ""
for o, title, names in GROUPS:
    toc += f'<div class="tg"><span class="lab">{e(o)} · {e(title)}</span>' + " ".join(f'<a href="#t-{e(x)}"><code>{e(short(x))}</code></a>' for x in names) + "</div>"
    body_tables += f'<h2 class="grp" id="g-{e(o)}-{re.sub("[^a-z]+", "-", title.lower())}">{e(title)} <span class="path">{e(o)} · {len(names)} tables</span></h2>'
    body_tables += "".join(table_html(o, T[x][1]) for x in names)

# --- rules ------------------------------------------------------------------------------------------------------
rules_html = ""
for o, d in db.items():
    if not d["rules"]: continue
    rules_html += f'<h3>{e(o)} <span class="path">{e(d["folder"])}/rules/ · {len(d["rules"])} rules</span></h3><div class="scroll"><table class="t"><thead><tr><th>Rule</th><th>What it requires</th><th>Its view</th></tr></thead><tbody>'
    for q in d["rules"]:
        rules_html += f'<tr id="r-{e(q["name"])}-{e(o)}"><td><code>{e(q["name"])}</code></td><td>{e(q["says"])}</td><td><details><summary class="small"><code>{e(q["view"])}</code></summary><pre>{e(q["sql"])}</pre></details></td></tr>'
    rules_html += "</tbody></table></div>"

g = Svg(1040, 250, "How a rule is enforced: a write queues a deferred check on each table its view reads; at commit the view is read once, and one row breaking it refuses the commit.")
g.box("w", 20, 90, 170, 54, "a write", "insert, update or delete", cls="box")
g.box("q", 250, 30, 220, 54, "rule:<owner>.<rule>", "constraint trigger, deferred", cls="pri")
g.box("a", 250, 150, 220, 54, "rule:<owner>.<rule>:again", "statement trigger", cls="box")
g.box("v", 540, 30, 200, 54, "broken_<rule>", "the view: rows breaking it", cls="pri")
g.box("ok", 820, 10, 200, 46, "no row: held", "not read again this commit", cls="box")
g.box("no", 820, 80, 200, 46, "a row: refused", "check_violation, naming it", cls="eng")
g.arrow("w", "q", "queued", cls="ea"); g.arrow("w", "a", "", cls="ea"); g.arrow("q", "v", "at commit", cls="ea")
g.arrow("v", "ok", "", cls="ea"); g.arrow("v", "no", "", cls="ea")
g.text(480, 226, "a later write marks the rule to be read again: once per commit, not once per row", "lb", "middle")
rules_svg = g.render()

# --- thinking ahead: talking to a design ---------------------------------------------------------------------------
ahead_svg = None
g = Svg(1040, 300, "A proposal, not yet a design: a namespace of what is worked out about the model, kept apart from the model itself, each row naming the model it was worked out from.")
g.band(10, 10, 480, 270, "cortex: the model, written by turns")
tbox(g, C("objects"), 40, 60, 150, 40, "pri"); tbox(g, C("columns"), 40, 150, 150); tbox(g, C("locked_versions"), 250, 60, 180); tbox(g, C("dependencies"), 250, 150, 180)
g.band(540, 10, 490, 270, "insight (proposed): worked out, never typed")
for key, x, y, w, sub in [("dep", 570, 50, 200, "dependencies"), ("ann", 800, 50, 200, "annotations"), ("emb", 570, 160, 200, "embeddings"), ("fnd", 800, 160, 200, "findings")]:
    g.box(key, x, y, w, 50, sub, {"dep": "calls, reads, writes, on", "ann": "sentences, model, input hash", "emb": "pgvector, per piece", "fnd": "a rule broken, a gap"}[key], cls="eng")
g.parts.append('<line x1="568" y1="75" x2="432" y2="80" class="es" marker-end="url(#mks)"/>')
g.text(500, 60, "from", "lb m", "middle")
g.text(785, 262, "each row: the version or input hash it was worked out from", "lb", "middle")
g.containers = set()
ahead_svg = g.render()

# --- decisions that shaped it ---------------------------------------------------------------------------------------
root = ET.parse(f"{REPO}/specs/root.xml").getroot()
dec = ""
for d in root.find("decisions").findall("decision"):
    w = d.get("where") or ""
    if d.get("status") == "confirmed" and ("schema" in w or "engine" in w or "t06" in w):
        dec += f'<tr><td><code>{e(d.get("id"))}</code></td><td>{e(" ".join("".join(d.itertext()).split()))}</td><td class="small">{e(d.get("date"))}</td></tr>'
opend = "".join(f'<li><code>{e(d.get("id"))}</code> {e(" ".join("".join(d.itertext()).split()))} <span class="pill open">before {e(d.get("closes-before"))}</span></li>'
                for d in root.find("decisions").findall("decision") if d.get("status") == "open")

ntab = sum(len(d["tables"]) for d in db.values())
nq = sum(len(d["rules"]) for d in db.values())
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
          '<span>→ a foreign key, labelled with its columns</span><span>boxes show a table\'s name without its namespace</span></div>')
eng_figs = "".join(f'<h3>{e(o)}\'s tables <span class="path">{e(db[o]["folder"])}</span></h3><figure>{s}<figcaption>Every table of {e(o)}, on the right, and the cortex table each refers to, on the left; a table that refers to another of {e(o)}\'s is joined to it on the right. Each lives in the same database as the cortex rows it refers to, so PostgreSQL enforces every reference.</figcaption></figure>' for o, s in engine_svgs.items())
undrawn_note = ", ".join(f"<code>{e(a)}.{e(c)}</code>" for a, c, b in undrawn)
# --- the service accounts: every grant, read from the locked dump (schema/dump), so the page is what PostgreSQL holds ---
ROLES = [("sf_owner", "no login", "Owns every namespace, table, view and function; the only role that changes the schema, every version of every owner running as it. No password: nobody signs in as it."),
         ("sf_service", "the app", "The account the app runs as: reads and writes every design's rows, the log and the workspace; creates, alters and drops nothing."),
         ("sf_agent", "a coding agent", "A coding agent's own account: reads everything; writes a design's rows inside a turn, and adds to the log without ever rewriting it; only reads the designs themselves, the engines' declarations, the workspace, what a person chose to read, what was applied, read and locked; creates, alters and drops nothing."),
         ("sf_reader", "reading only", "Reads every table and changes nothing: the MCP's sql tool and every query sent for reading.")]
WORDS = {"SELECT": "read", "INSERT": "add", "UPDATE": "change", "DELETE": "remove"}
grants = {}
for g in re.finditer(r"^GRANT ([A-Z,]+) ON TABLE ([\w.]+) TO (sf_\w+);$", open(f"{REPO}/schema/dump/schema_forge.sql").read(), re.M):
    grants.setdefault(g.group(2), {})[g.group(3)] = [WORDS[x] for x in ("SELECT", "INSERT", "UPDATE", "DELETE") if x in g.group(1).split(",")]
def said(ws):
    return ", ".join(ws) if ws else "nothing"
agent_less = sorted(t for t, r in grants.items() if r.get("sf_agent") != r.get("sf_service"))
rows = "".join(f'<tr><td><a href="#t-{e(t)}"><code>{e(t)}</code></a></td>' + "".join(f"<td>{e(said(grants[t].get(r, [])))}</td>" for r in ("sf_service", "sf_agent", "sf_reader")) + "</tr>"
               for t in sorted(grants))
cards = "".join(f'<div class="card"><p class="kicker">{e(k)}</p><h3><code>{e(r)}</code></h3><p>{e(t)}</p></div>' for r, k, t in ROLES)
accounts_html = (f'<section id="accounts"><h2>The service accounts</h2><p class="lede">Four roles, made by <code>schema/install.py</code> '
    '(<code>schema/accounts.py</code>) when it installs <code>schema_forge</code>, each login account given a strong password written only to its '
    'accounts file (mode 600); <code>cortex.grant_roles</code> gives every owner\'s namespace to them as its version 1 ends (decision database-roles). '
    'No account but <code>sf_owner</code> can create, alter or drop anything, and the install proves it for each.</p>'
    f'<div class="cards">{cards}</div>'
    f'<h3>Every grant, table by table</h3><p class="lede">Read from the locked dump, so this is what PostgreSQL holds: {len(grants)} tables. '
    f'The coding agent\'s account differs from the app\'s on {len(agent_less)} of them. Every account may also use each namespace and run its functions '
    '(the app and the agent); none may create in it.</p>'
    '<details><summary>All grants</summary><div class="scroll"><table class="t"><thead><tr><th>Table</th><th>sf_service · the app</th>'
    f'<th>sf_agent · a coding agent</th><th>sf_reader</th></tr></thead><tbody>{rows}</tbody></table></div></details></section>')

body = f"""
<div class="tb" role="group" aria-label="Title block">
  <div><span>Engine</span><b>PostgreSQL 18, bundled</b></div><div><span>Database</span><b>schema_forge</b></div>
  <div><span>Tables</span><b>{ntab}</b></div><div><span>Rules</span><b>{nq or "on ice"}</b></div><div><span>Date</span><b>2026-11-26</b></div>
</div>
<h1>%PRODUCT% Database <span class="draft">Draft 3</span></h1>
<p class="lede">Every table %PRODUCT% keeps its work in, designed first and locked: no build creates or changes one. The cortex is what every
engine shares; each engine ships its own tables in its plugin, in its own namespace, in the same database as the cortex rows they refer to, so
PostgreSQL enforces every reference. Every column is typed, checked and documented, in its file and in the database's own comments, and a rule a
foreign key cannot state is a view the database enforces at every commit. Everything below is read from the schema folders.</p>
<div class="stats">{''.join(f'<div><b>{len(d["tables"])}</b><span>{e(o)} tables · {e(d["folder"])}</span></div>' for o, d in db.items())}</div>

<section id="files"><h2>The database</h2>
<p class="lede">A workspace is a folder with its own PostgreSQL cluster, started when the workspace opens and reached only through a Unix socket in that folder. The cluster holds one database, <code>schema_forge</code>, installed once: the cortex, the ui and each engine in its own namespace. Every design people work on is a row of <code>cortex.designs</code> and the rows that point at it; making a design or reading a table into one adds rows, never a database, a namespace or a table. Every table of a design carries its design in a column <code>design</code>, with <code>UNIQUE (design, id)</code>; every reference within a design is <code>(design, column)</code> to <code>(design, id)</code>, with an index on it, so no row can point into another design and opening, changing or deleting one design reads that design's rows only. The diagrams leave each table's <code>design</code> out.</p>
<figure>{files_svg}<figcaption>The same layout runs on a central team server later: only the connection changes.</figcaption></figure></section>

<section id="model"><h2>The model</h2><p class="lede">Namespaces hold objects (tables, views, routines, whatever kinds the engine declares); objects have columns; constraints are a table's keys and checks and the links from its columns to another's, enforced by the database or only drawn by the design. An object's kind must be one its engine declared, and what it holds must suit its kind (the rule <code>parts-of-their-kind</code>).</p>
<figure>{model_svg}<figcaption>Every foreign key between these tables. A part's primary key is a UUIDv7, made with the row and kept when it is renamed: a rename is one row, and every reference follows it by id.</figcaption>{legend}</figure></section>

<section id="parts"><h2>What an object holds</h2><p class="lede">What every engine can say of an object, as tables: a table is held as facts only, and its statement is written from them byte for byte as the server writes it; a view, routine or trigger keeps its body as the server holds it. A kind fills only the parts it uses: a rule refuses a part its kind lacks.</p>
<figure>{parts_svg}<figcaption>Middle row: one row per object at most, its id the object's. Bottom row: any number per object, in the server's order (an INTEGER position from 1). The outer rows are their parts. Not drawn, listed with each table: {undrawn_note}.</figcaption></figure></section>

<section id="log"><h2>The log</h2><p class="lede">Every change is an operation of a turn, appended and never edited; the design is written in the same transaction. Each operation records every row it inserted, updated or deleted, with its values before and after, so its inverse is worked out from the record. Turns form a tree: a branch is a line of turns, switching branch moves the design through their common turn, opening a savepoint or a version is that move rolled back, and a restore is a new turn of inverses.</p>
<figure>{log_svg}<figcaption>A turn is the agent's answer to one prompt, a person's edit, an import or a restore; it follows its parent and is accepted or rejected whole. A rejected turn stays, marked, and the turn that takes it back names it in <code>undoes</code>.</figcaption></figure></section>

<section id="workspace"><h2>The workspace</h2><p class="lede">In the cortex, as <code>workspace_*</code> tables: the saved connections, the value of each field their engine declares (never a secret), their tests, and the connection each design is read from.</p>
<figure>{ws_svg}</figure></section>

{accounts_html}
<section id="engines"><h2>Each engine's tables</h2><p class="lede">What one engine alone says of a part (MySQL's row format, PostgreSQL's operator class) is that part's <code>options</code>, each option declared in <code>cortex.option_declarations</code> by the engine's seeds and checked as the row is written (decision declared-options): a new option is a row, never a column. An engine's own namespace, <code>engine_&lt;engine&gt;</code>, holds only what is many rows of its own (<code>engine_postgresql.policies</code>, <code>engine_mysql.subpartitions</code>).</p>{eng_figs}</section>

<section id="tables"><h2>Every table</h2><p class="lede">Grouped as above. Each with what it holds, how its row is named, its columns, what refers to it, its constraints, the rules that read it, and its file whole.</p>{toc}</section>
{body_tables}

<section id="rules"><h2>Rules</h2><p class="lede">What a foreign key cannot say. Each rule is a view of the rows breaking it, one file each; <code>cortex.enforce_rules</code> reads which tables the view depends on and puts the triggers on them, so PostgreSQL itself refuses any commit that breaks a rule, whatever wrote it. No list of tables is kept by hand.</p>
<p class="lede"><b>On ice since 2026-11-26.</b> Every rule view waits in <code>lab/on-ice/rules</code> until the rules are their own owner and schema (decision rules-tables), each checking only the designs a commit changed; the machinery below stays. Until then the foreign keys hold every design apart by themselves.</p>
<figure>{rules_svg}<figcaption>Tested on PostgreSQL 18: a key on a view, a number its counter never gave, a nullable primary key column and a MySQL table option on a view are each refused at commit; 3,000 rows commit in about 30 ms.</figcaption></figure>
{rules_html}</section>

<section id="ahead"><h2>Thinking ahead: talking to a design</h2><p class="lede">%PRODUCT% is a canvas and an MCP server: a person draws the design, or chats with an agent that works through the MCP, or both at once. Both do more the more is known about the design: what each object touches, what is said about it, how to find it by meaning, what is known to be wrong. That knowledge and its vectors will live in the same PostgreSQL as the model, for one person or a whole team. A proposal to decide (insight-layer), not yet a design.</p>
<div class="scroll"><table class="t"><thead><tr><th>Concern</th><th>The idea</th><th>%PRODUCT% today</th><th>What we will build</th></tr></thead><tbody><tr><td><b>What an object touches</b></td><td>Every fact a definition states about another object: it calls, reads, writes, is on, references, creates, drops or alters it, each with the statement as evidence and its line; a name built at run time kept with its pattern (<code>tbl_x{{client}}</code>).</td><td><code>cortex.dependencies</code>: only <em>reads</em>, only resolved targets, no evidence.</td><td><code>insight.dependencies</code>: every kind, the evidence and its line, an unresolved target with its pattern, worked out by the engine from definitions: the graph an impact walk follows.</td></tr><tr><td><b>What is said about an object</b></td><td>A few sentences per object (what it is, what it reads and writes, what calls it, what a change would reach), with the model that wrote them and a hash of what they were written from, so stale ones are found.</td><td><code>comment</code> and <code>notes</code> on objects: typed, with no record of who worked them out or from what.</td><td><code>insight.annotations</code>, at levels object, area and schema; and <code>insight.cards</code>, composed mechanically from the model, needing no language model.</td></tr><tr><td><b>Finding by meaning</b></td><td>An embedding of every piece of text, searched together with full text and exact names, every hit confirmed against the model.</td><td>Nothing yet: the agent finds by name.</td><td><code>insight.embeddings</code> with pgvector, built into the bundled PostgreSQL; later the semantic layer (what a table means to the business, its terms and measures) in the same index. Rich metadata now is what makes that worth having.</td></tr><tr><td><b>What is known to be wrong</b></td><td>Every gap and broken design rule, with its evidence, its impact and the next step.</td><td>The rules refuse what breaks the schema; nothing records a design rule broken (the open decision rules-tables).</td><td><code>findings</code>: what the design rules find, and how the design differs from a live database (pipelines-tables).</td></tr><tr><td><b>Worked out vs. written</b></td><td>What is written is the truth; what is worked out from it is rebuilt, keyed by what it came from.</td><td>The model is written by turns, with its log.</td><td>Insight is worked out from a locked version or an input hash, refreshed from the log after each turn, and can always be dropped and rebuilt: it never needs a log or a migration of its data.</td></tr><tr><td><b>How it is asked</b></td><td>Find candidates by meaning, read one object whole, walk what a change reaches, and count or list exactly with SQL: a search is never a count.</td><td>The prototype's MCP tools read and change the model.</td><td>MCP tools search, object, impact and sql; sql runs as a read-only PostgreSQL role, so a chat can question a design and change it only by operations.</td></tr></tbody></table></div>
<figure>{ahead_svg}<figcaption>The line drawn: what is written is the truth; what is worked out from it is rebuilt and keyed by what it came from. The model, written by turns, is the truth; an <code>insight</code> namespace would hold what is worked out from a locked version, never edited and never logged, and could be dropped and rebuilt.</figcaption></figure></section>

<section id="decisions"><h2>Decisions</h2><p class="lede">What was decided with the operator, and where it now lives. The open ones close in a design session before the task that needs them.</p>
<div class="scroll"><table class="t"><thead><tr><th>Decision</th><th>What</th><th>Date</th></tr></thead><tbody>{dec}</tbody></table></div>
<h3>Still open</h3><ul class="small">{opend}</ul></section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("files", "Databases"), ("model", "Model"), ("parts", "Object parts"), ("log", "Log"), ("workspace", "Workspace"), ("accounts", "Accounts"), ("engines", "Engines"), ("tables", "Every table"), ("rules", "Rules"), ("ahead", "Talking to a design"), ("decisions", "Decisions")])
HTML = page("database", "%PRODUCT% Database", CSS, body, sub)
