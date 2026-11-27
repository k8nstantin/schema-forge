"""The Architecture page: how SchemaForge is put together (the store, the app, the clients), who may write what, how a
change travels, and why each choice was made, with the research behind it and what that research changed."""
import xml.etree.ElementTree as ET

from common import REPO, Svg, e, page

root = ET.parse(f"{REPO}/specs/root.xml").getroot()
seq = {t.get("id"): t for t in root.find("sequence").findall("task")}


def issue(oid):
    t = seq[oid]
    n = t.get("key")[3:]
    return f'<a href="%REPO%/issues/{n}" target="_blank" rel="noopener">#{n} {e(t.get("name"))}</a>'


# --- 1. the three layers -------------------------------------------------------------------------------------------------
g = Svg(1040, 450, "The three layers: the clients (the canvas and coding agents), the app (one Rust binary) and the store (one PostgreSQL database); each box links to its explanation.")
g.band(10, 10, 1020, 96, "clients")
g.box("canvas", 150, 50, 260, 46, "canvas (browser)", "React and TypeScript", cls="lg", href="#clients")
g.box("agent", 630, 50, 260, 46, "coding agent", "Claude Code and others", cls="lg", href="#clients")
g.band(10, 124, 1020, 186, "app: schema-forge, one Rust binary")
g.box("serve", 150, 162, 260, 46, "serve", "HTTP API and websocket", cls="eng", href="#app")
g.box("mcp", 630, 162, 260, 46, "mcp", "the agent's tools, over stdio", cls="eng", href="#app")
g.box("query", 40, 246, 200, 46, "query", "DataFusion, read-only", cls="eng", href="#app")
g.box("store", 290, 246, 200, 46, "store", "pools, retries, bell", cls="eng", href="#app")
g.box("core", 540, 246, 200, 46, "core", "turns, operations, undo", cls="eng", href="#app")
g.box("engines", 790, 246, 200, 46, "engines", "engine_mysql, then more", cls="eng", href="#app")
g.band(10, 328, 1020, 112, "store: PostgreSQL 18, database schema_forge")
g.box("cortex", 150, 372, 220, 46, "cortex", "plugs, history, model", cls="pri", href="#store")
g.box("emysql", 410, 372, 220, 46, "engine_mysql", "MySQL's own, 24 tables", cls="pri", href="#store")
g.box("ui", 670, 372, 200, 46, "ui", "the canvas's state (o7)", cls="pri", href="#store")
for a, b in [("canvas", "serve"), ("agent", "mcp"), ("serve", "core"), ("mcp", "core"), ("core", "store"), ("core", "engines"),
             ("store", "cortex"), ("query", "cortex"), ("engines", "emysql")]:
    g.arrow(a, b)
g.containers = set()
layers_svg = g.render()

# --- 2. who may write what -----------------------------------------------------------------------------------------------
g = Svg(1040, 430, "Who may write what: the app and the agent write turns and the shared model; a plugin's account writes the shared model and its own tables, for its own engine's designs; the reader writes nothing; only the trigger writes the log.")
g.box("app", 40, 60, 300, 46, "cortex_service, cortex_agent", "the app and the coding agent", cls="eng")
g.box("reader", 40, 170, 300, 46, "cortex_reader", "the query layer: reads, never writes", cls="lg")
g.box("plugin", 40, 280, 300, 46, "engine_mysql_service", "the plugin, its designs alone", cls="eng")
g.box("turns", 640, 20, 340, 46, "turns", "open, commit, number: a round of work", cls="pri", href="database.html#cortex.turns")
g.box("model", 640, 150, 340, 46, "the shared model", "objects, columns, indexes, keys", cls="pri", href="database.html#cortex.objects")
g.box("own", 640, 280, 340, 46, "engine_mysql's tables", "what only MySQL has", cls="pri", href="database.html#engine_mysql")
g.box("trigger", 300, 370, 260, 46, "cortex.log_row", "a trigger on every table", cls="lg")
g.box("log", 640, 370, 340, 46, "the log: row_changes", "before and after of every row", cls="pri", href="database.html#cortex.row_changes")
for a, b in [("app", "turns"), ("app", "model"), ("plugin", "model"), ("plugin", "own"), ("trigger", "log")]:
    g.arrow(a, b)
g.containers = set()
roles_svg = g.render()

# --- 3. a change, end to end ---------------------------------------------------------------------------------------------
STEPS = [("agent: change", "an MCP tool, over stdio"), ("core opens a turn", "one open turn per design"),
         ("one transaction", "SERIALIZABLE, one account"), ("log_row logs each row", "before and after, as JSONB"),
         ("the turn commits", "numbered in commit order"), ("NOTIFY design:number", "once per commit, never per row"),
         ("server pushes it", "websocket, to every canvas"), ("the canvas redraws", "a gap in numbers: read again")]
g = Svg(1040, 220, "A change, end to end: the agent calls change, the core opens a turn, the operation is one transaction whose rows the trigger logs, the turn commits and is numbered, one notification rings, the server pushes it, and every canvas redraws.")
for i, (t, s) in enumerate(STEPS):
    x = 20 + (i if i < 4 else 7 - i) * 260
    g.box(f"s{i}", x, 30 if i < 4 else 150, 220, 46, f"{i + 1}. {t}", s, cls="eng" if i < 4 else "pri")
for i in range(7):
    g.arrow(f"s{i}", f"s{i + 1}")
g.containers = set()
flow_svg = g.render()

# --- 4. the crates and what each may depend on --------------------------------------------------------------------------
g = Svg(1040, 360, "The crates of the Rust workspace and what each depends on: the binary on serve and mcp, both on core, core on the store, the query layer and the engine interface; each engine implements the interface and depends on nothing else of the app.")
g.box("bin", 410, 20, 220, 46, "schema-forge", "the one binary", cls="lg")
g.box("serve", 150, 110, 220, 46, "crates/server: serve", "API, websocket, canvas", cls="eng")
g.box("mcpc", 670, 110, 220, 46, "crates/server: mcp", "the agent's tools", cls="eng")
g.box("corec", 410, 200, 220, 46, "crates/core", "turns, operations, undo", cls="eng")
g.box("queryc", 40, 290, 200, 46, "crates/query", "DataFusion, read-only", cls="eng")
g.box("storec", 290, 290, 200, 46, "crates/store", "pools, retries, bell", cls="eng")
g.box("enginec", 560, 290, 200, 46, "crates/engine", "the Engine trait", cls="pri")
g.box("emc", 810, 290, 200, 46, "engines/mysql", "implements it", cls="pri")
for a, b in [("bin", "serve"), ("bin", "mcpc"), ("serve", "corec"), ("mcpc", "corec"), ("corec", "queryc"), ("corec", "storec"),
             ("corec", "enginec"), ("emc", "enginec")]:
    g.arrow(a, b)
g.containers = set()
crates_svg = g.render()

# --- 5. the HTTP API, the canvas's way in ----------------------------------------------------------------------------------
ROUTES = [("GET /designs", "the designs", "core"), ("GET /designs/{id}/model", "a design's model", "core"),
          ("POST /designs/{id}/turns", "a turn of operations", "core"), ("POST /turns/{id}/undo", "undo a turn", "core"),
          ("POST /import", "a live server into a design", "eng"), ("GET /designs/{id}/sql", "the design as SQL", "eng"),
          ("WS /bell", "committed turns, live", "bell")]
g = Svg(1040, 470, "The HTTP API the canvas uses, a first draft: routes for designs, models, turns and undo go to the core; import and write go to the engine; the websocket carries the bell.")
g.box("api", 300, 10, 340, 450, "", "", cls="band")
g.text(470, 32, "serve: the routes", "cap", "middle")
g.box("cv", 30, 210, 200, 50, "the canvas", "React and TypeScript", cls="lg")
for i, (r, s, _) in enumerate(ROUTES):
    g.box(f"r{i}", 320, 46 + i * 58, 300, 44, r, s, cls="eng")
g.box("t_core", 800, 108, 210, 50, "core", "designs, turns, undo", cls="pri")
g.box("t_eng", 800, 306, 210, 50, "engines", "read and write SQL", cls="pri")
g.box("t_bell", 800, 398, 210, 50, "the bell", "LISTEN, one connection", cls="pri")
g.arrow("cv", "api")
for i, (_, _, t) in enumerate(ROUTES):
    g.arrow(f"r{i}", {"core": "t_core", "eng": "t_eng", "bell": "t_bell"}[t])
g.containers = {"api"}
api_svg = g.render()

# --- 6. the MCP, the agent's way in ----------------------------------------------------------------------------------------
TOOLS = [("designs", "list the designs", "core"), ("describe", "a design's model, as text", "core"),
         ("start_turn", "open a turn on a design", "core"), ("change", "operations, all or none", "core"),
         ("undo", "undo a committed turn", "core"), ("query", "read-only SQL", "query")]
g = Svg(1040, 420, "The MCP tools a coding agent calls over stdio: designs, describe, start_turn, change and undo go to the core; query goes to the read-only DataFusion layer.")
g.box("mcpb", 320, 10, 260, 400, "", "", cls="band")
g.text(450, 32, "mcp: the tools", "cap", "middle")
g.box("ag", 30, 180, 200, 50, "coding agent", "starts schema-forge mcp", cls="lg")
for i, (t, s, _) in enumerate(TOOLS):
    g.box(f"m{i}", 340, 46 + i * 58, 220, 46, t, s, cls="eng")
g.box("mt_core", 820, 166, 200, 50, "core", "as cortex_agent", cls="pri")
g.box("mt_query", 820, 336, 200, 50, "query", "as cortex_reader", cls="pri")
g.arrow("ag", "mcpb")
for i, (_, _, t) in enumerate(TOOLS):
    g.arrow(f"m{i}", "mt_core" if t == "core" else "mt_query")
g.containers = {"mcpb"}
mcp_svg = g.render()

# --- 7. undo is a turn too -------------------------------------------------------------------------------------------------
TURNS = [("turn 1: import", "a live MySQL read in"), ("turn 2: your edit", "renamed a column"),
         ("turn 3: the agent", "added two tables"), ("turn 4: undo of 3", "its inverse, newest first")]
OPS = ["add_table, add_column ...", "rename_column", "add_table x 2", "drop_table x 2"]
g = Svg(1040, 230, "Undo is a turn too: every turn's operations are logged row by row, and undoing turn 3 writes turn 4, the inverse of its row changes, newest first, which can itself be undone.")
for i, ((t, s), o) in enumerate(zip(TURNS, OPS)):
    g.box(f"u{i}", 20 + i * 260, 30, 220, 50, t, s, cls="pri" if i < 3 else "lg")
    g.box(f"o{i}", 20 + i * 260, 150, 220, 46, "its operations", o, cls="eng")
    g.arrow(f"u{i}", f"o{i}")
for i in range(3):
    g.arrow(f"u{i}", f"u{i + 1}")
g.containers = set()
undo_svg = g.render()

# --- 8. adding an engine ---------------------------------------------------------------------------------------------------
g = Svg(1040, 250, "Adding an engine: engine_postgresql brings a schema the installer plugs into the store and a crate the binary registers; core, server, MCP and canvas do not change.")
g.box("newe", 400, 20, 240, 50, "engine_postgresql", "one plugin, two halves", cls="lg", href="#app")
g.box("half_s", 120, 120, 260, 50, "its schema", "tables, owner, service account", cls="pri")
g.box("half_c", 660, 120, 260, 50, "its crate", "implements the Engine trait", cls="eng")
g.box("in_store", 120, 190, 260, 46, "plugged into the store", "five checked steps", cls="pri")
g.box("in_app", 660, 190, 260, 46, "registered in the binary", "core and UI unchanged", cls="eng")
for a, b in [("newe", "half_s"), ("newe", "half_c"), ("half_s", "in_store"), ("half_c", "in_app")]:
    g.arrow(a, b)
g.containers = set()
engine_svg = g.render()

# --- the explanations ----------------------------------------------------------------------------------------------------
LAYERS = [
    ("store", "The store: one database, and the schema is the product",
     ["Everything SchemaForge knows of a design is rows of one PostgreSQL 18 database, <code>schema_forge</code>, split into schemas, each with its "
      "own owner role and its own service account.",
      "<b>cortex</b> (21 tables): the plugs (plugins, engines, versions, flavors, object kinds), the history (designs, branches, turns, "
      "operations, row changes, locked versions) and the model every engine shares (namespaces, objects, columns, indexes, constraints, "
      "dependencies). <b>engine_mysql</b> (24 tables) holds only what MySQL has beyond the shared model, each row extending a cortex row "
      "with the same id. <b>ui</b> (" + issue("o7") + ") holds the canvas's own state, versioned and undone with the design.",
      "The database, not the code, keeps it right: every id a UUIDv7, every reference a foreign key within its design, every value "
      "checked, row-level security fencing each plugin to its own engine's designs, one trigger logging every change, one open turn per "
      "design. A change the rules forbid is refused whoever makes it. <a href=\"database.html\">Every table, column and role</a>."]),
    ("app", "The app: one Rust binary, <code>schema-forge</code>",
     ["<b>store</b> (" + issue("o4") + "): a connection pool per account; every operation one SERIALIZABLE transaction, retried whole when "
      "two writers collide; the bell, listening for committed turns on a connection of its own.",
      "<b>core</b> (" + issue("o4") + "): designs, branches, turns, operations, undo, restore and locked versions, on the cortex's own "
      "functions. It never names an engine.",
      "<b>engines</b> (" + issue("o5") + "): the <code>Engine</code> trait each plugin implements (read a live server into the model, its rows, "
      "write SQL back, its types as Apache Arrow's) and the registry of the engines the binary ships. <code>engine_mysql</code> is ported "
      "from the Python, which stays as the oracle the Rust must equal row for row.",
      "<b>serve</b> and <b>mcp</b> (" + issue("o6") + "): the HTTP API and the websocket for the canvas; the MCP tools for coding agents, "
      "run as the agent's child process. <b>query</b>: Apache DataFusion over the store and live servers, signed in as "
      "<code>cortex_reader</code>, so no query can write.",
      "The rules that keep it clean: core, server and canvas never name an engine; an engine never depends on another, nor on "
      "DataFusion (Arrow types only); a new engine (" + issue("o9") + ") is a new schema and a new crate, with no change to core or UI."]),
    ("clients", "The clients: the canvas and coding agents",
     ["<b>The canvas</b> (" + issue("o7") + ", " + issue("o8") + "): React and TypeScript in the browser, served from inside the binary; "
      "diagrams drawn as plain SVG, laid out by rule; its API types generated from the server's own description, so the two cannot drift.",
      "<b>Coding agents</b> (" + issue("o6") + "): Claude Code and others start <code>schema-forge mcp</code> and call its tools: list "
      "designs, describe one, start a turn, change (operations, all or none), undo, query. Every change an agent makes is a turn like "
      "a person's: shown live, kept, or rejected by undoing it."]),
]
layers_html = "".join(
    f'<section id="{k}"><p class="kicker">{k}</p><h2>{t}</h2>' + "".join(f"<p>{p}</p>" for p in ps) + "</section>" for k, t, ps in LAYERS)

ROLES = [("cortex_service", "the app", "designs, branches, turns, operations, the shared model; undo"),
         ("cortex_agent", "the coding agent", "the same, but designs, branches and locked versions it only reads"),
         ("cortex_reader", "the query layer", "reads everything, writes nothing"),
         ("engine_mysql_service", "the plugin", "the shared model and its own tables, for MySQL designs alone; adds operations to a turn, never opens one"),
         ("&lt;schema&gt;_owner", "never signs in", "owns its schema and runs its migrations"),
         ("cortex.log_row", "a trigger", "the only writer of the log; nobody rewrites history")]
roles_rows = "".join(f"<tr><td><code>{a}</code></td><td class=\"small\">{b}</td><td>{c}</td></tr>" for a, b, c in ROLES)

STEP_TEXT = [
    "The agent calls the MCP tool <code>change</code> with a list of operations; the canvas does the same through the HTTP API.",
    "The core opens a turn on the design. The database allows one open turn per design, so a second writer is told who holds it.",
    "Each operation is one transaction on one account: an operation that touches MySQL's own rows is written whole by "
    "<code>engine_mysql_service</code>, the rest by the app's or the agent's account. It lands whole or not at all, and is "
    "retried whole if another writer collided with it.",
    "The trigger <code>cortex.log_row</code> writes every row's before and after to the log, under the operation the transaction "
    "names; a change outside an operation is refused.",
    "The turn commits and the database gives it the next number in the design's commit order.",
    "One notification rings: the design and that number. Once per committed turn, never per row.",
    "The server pushes it over the websocket to every open canvas.",
    "Each canvas reads what changed and redraws. A gap in the numbers (a notification lost while a connection was down) means "
    "read every turn past the last one seen. The verdict comes after: keep it, or reject it, which undoes the turn.",
]
steps_html = "<ol>" + "".join(f"<li>{s}</li>" for s in STEP_TEXT) + "</ol>"

# --- why: every choice and the evidence --------------------------------------------------------------------------------------
SRC = {
    "pg-serial": ("PostgreSQL 18: Serialization Failure Handling", "https://www.postgresql.org/docs/18/mvcc-serialization-failure-handling.html"),
    "tom-lane": ("pgsql-bugs: set_config with is_local and custom settings (Tom Lane)", "https://www.postgresql.org/message-id/392925.1673397546%40sss.pgh.pa.us"),
    "dbos": ("DBOS: Postgres LISTEN/NOTIFY can actually scale", "https://dbos.dev/blog/postgres-listen-notify-scalability"),
    "notifier": ("Brandur: the notifier pattern", "https://brandur.org/notifier"),
    "supa-audit": ("Supabase: Postgres auditing in 150 lines of SQL", "https://supabase.com/blog/2022/03/08/audit"),
    "cybertec": ("Cybertec: trigger-based auditing and its limits", "https://www.cybertec-postgresql.com/en/?p=11489"),
    "rls-perf": ("Supabase: Row Level Security performance", "https://supabase.com/docs/guides/database/postgres/row-level-security-performance"),
    "rls-foot": ("Bytebase: Postgres row-level security footguns", "https://www.bytebase.com/blog/postgres-row-level-security-footguns/"),
    "mcp-local": ("MCP: Local Server Security", "https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/local-server-security"),
    "owasp-mcp": ("OWASP: MCP Security Cheat Sheet", "https://cheatsheetseries.owasp.org/cheatsheets/MCP_Security_Cheat_Sheet.html"),
    "df-tp": ("Apache DataFusion: writing custom table providers", "https://datafusion.apache.org/blog/2026/03/31/writing-table-providers/"),
    "crates": ("crates.io: datafusion, rmcp, axum, tokio-postgres, deadpool-postgres, mysql_async", "https://crates.io/crates/datafusion"),
    "ms-rust": ("Microsoft: Rust project guidelines", "https://microsoft.github.io/rust-guidelines/guidelines/project/"),
    "cargo-ws": ("The Cargo Book: workspaces", "https://doc.rust-lang.org/cargo/reference/workspaces.html"),
}


def cite(*keys):
    return " ".join(f'<a href="#src-{k}">[{list(SRC).index(k) + 1}]</a>' for k in keys)


WHY = [
    ("History as one trigger writing before and after as JSONB, undo from it",
     "One log for every engine; undo, restore and branch switch work the same for all of them, and no engine writes its own history.",
     "The established pattern for generic audit trails in PostgreSQL. Its known weakness: a table's owner or a superuser can switch "
     "the trigger off; here owners never sign in, and no service account owns a table.", ("supa-audit", "cybertec"), "in place"),
    ("The operation named by set_config(..., true), for its transaction alone",
     "A pooled connection must never carry one caller's operation into another's work.",
     "Verified: after the transaction a custom setting falls back to an empty string, not NULL. The trigger reads it with "
     "<code>nullif(..., '')</code>, so a leftover is treated as absent and the change refused.", ("tom-lane",), "in place"),
    ("Every write SERIALIZABLE, the whole transaction retried on 40001 and 40P01",
     "Two writers can never together break a rule each alone keeps.",
     "PostgreSQL's own guidance: retry serialization failures unconditionally, deadlocks too, and re-run the whole transaction "
     "including the logic that chose what to write. So the store takes an operation as a function it can run again, never a "
     "list of statements.", ("pg-serial",), "built in o4"),
    ("LISTEN/NOTIFY as the bell, once per committed turn",
     "Every open canvas and agent learns of a change at once, with no polling.",
     "A commit that notifies takes a global lock; one measured system stalled near 2,900 notifying commits a second. The bell "
     "rings once per committed turn, never per row or operation, far below that. Notifications are not durable, so the "
     "numbers in each one let a reader see a gap and read what it missed; one listening connection per process.",
     ("dbos", "notifier"), "built in o4"),
    ("Row-level security fencing each plugin to its own engine's designs",
     "No cross-engine writes, held by the database whatever the code does.",
     "A policy that calls a function for every row is the commonest cost of row-level security. Changed by this research: the "
     "fence becomes one uncorrelated subquery, the designs of the asking account, worked out once per statement, on the "
     "indexed design column. Owners bypass their own policies, which is safe here only because owners never sign in.",
     ("rls-perf", "rls-foot"), "changed: built in o4"),
    ("The MCP over stdio, as the agent's child process",
     "No network port to guard for the agent's tools.",
     "The MCP project's guidance: a stdio server shares the agent's trust domain, so give it only its own narrowly scoped "
     "credential. Changed by this research: <code>schema-forge mcp</code> reads only <code>cortex_agent</code>'s credential, "
     "never the whole accounts file.", ("mcp-local",), "changed: built in o6"),
    ("The canvas's API on 127.0.0.1",
     "The canvas talks to its own server on the same machine.",
     "Binding to 127.0.0.1 is not an authentication boundary: a web page can reach it through the browser (DNS rebinding). "
     "Changed by this research: <code>serve</code> checks every request's Origin and a token made at each launch, on the API "
     "and the websocket.", ("mcp-local", "owasp-mcp"), "changed: built in o6"),
    ("Apache DataFusion for reading, signed in as cortex_reader",
     "SQL over designs and live servers (drift, impact) without writing a query engine.",
     "Custom table providers are DataFusion's supported way to expose another system's tables. Pinned to release 55, which the "
     "community MySQL and PostgreSQL providers support; the newest, 56, is days old.", ("df-tp", "crates"), "built in o6"),
    ("One Rust workspace: crates with one job each, engines behind a trait",
     "An engine never breaks another; a new engine changes nothing in core or UI.",
     "Shared workspace lints, the toolchain pinned, clippy warnings failing the build, versions pinned exactly where a crate "
     "moves fast (rmcp releases weekly).", ("ms-rust", "cargo-ws", "crates"), "built in o4"),
]
why_rows = "".join(
    f'<tr><td><b>{e(c)}</b><br><span class="small">{e(w)}</span></td><td>{ev} {cite(*k)}</td><td class="small">{e(s)}</td></tr>'
    for c, w, ev, k, s in WHY)
sources = "".join(f'<li id="src-{k}"><a href="{e(u)}" target="_blank" rel="noopener">{e(t)}</a></li>' for k, (t, u) in SRC.items())

CSS = """.tbl{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:14px 0;min-width:0;overflow-x:auto}
.cols{width:100%;border-collapse:collapse;font-size:14px;margin:8px 0}.cols td,.cols th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
.toc{display:flex;flex-wrap:wrap;gap:10px;margin:10px 0}
.d a rect{cursor:pointer}.d a:hover rect{stroke-width:2.8}.d a:hover text{text-decoration:underline}
figure{margin:18px 0;overflow-x:auto}figure svg{min-width:720px}ol li{margin:6px 0}"""

body = f"""
<header class="hero"><p class="eyebrow">The architecture</p><h1>A store, one binary, and its clients.</h1>
<p class="lede">SchemaForge is three layers: the store, one PostgreSQL database whose schema is the product; the app, one Rust
binary; and its clients, the canvas in a browser and coding agents. Every database engine is a plugin that adds its own schema
to the store and its own crate to the app. Every choice below names the research behind it.</p>
<div class="toc"><a href="#map">The map</a><a href="#store">The store</a><a href="#app">The app</a><a href="#clients">The clients</a>
<a href="#crates">The crates</a><a href="#api">The HTTP API</a><a href="#mcp">The MCP</a>
<a href="#who">Who may write what</a><a href="#flow">A change, end to end</a><a href="#undo">Undo</a><a href="#new-engine">Adding an engine</a><a href="#why">Why, and the evidence</a><a href="#sources">Sources</a></div></header>
<section id="map"><p class="kicker">The map</p><h2>Three layers. Click any box.</h2><figure>{layers_svg}</figure></section>
{layers_html}
<section id="who"><p class="kicker">Who may write what</p><h2>Each account writes only what its job needs.</h2><figure>{roles_svg}</figure>
<div class="tbl"><table class="cols"><thead><tr><th>Account</th><th></th><th>May write</th></tr></thead><tbody>{roles_rows}</tbody></table></div>
<p>An operation is one transaction on one account, so it lands whole or not at all; no transaction spans two accounts.</p></section>
<section id="crates"><p class="kicker">The crates</p><h2>One job each; arrows point at what a crate may use.</h2><figure>{crates_svg}</figure>
<p>The arrows never point upward and never between engines: an engine knows only the <code>Engine</code> trait, so a bug in one engine
stays in it, and only <code>crates/query</code> depends on DataFusion. The canvas's built files are embedded in <code>serve</code>, so
SchemaForge ships as one file.</p></section>
<section id="api"><p class="kicker">The HTTP API</p><h2>How the canvas talks to the app.</h2><figure>{api_svg}</figure>
<p>A first draft: every route and type is written before it is built, in the decision <code>api-contract</code>, which closes
before {issue("o6")}. The canvas's TypeScript types are generated from the server's own OpenAPI description, so the two cannot drift.
The server listens on 127.0.0.1 only, and checks every request's Origin and a token made at each launch, on the API and the websocket.</p></section>
<section id="mcp"><p class="kicker">The MCP</p><h2>How a coding agent talks to the app.</h2><figure>{mcp_svg}</figure>
<p>The Model Context Protocol is how coding agents call tools. The agent starts <code>schema-forge mcp</code> as its own child process
and talks to it over stdin and stdout, so there is no port to guard. It signs in as <code>cortex_agent</code>, reading only that
account's credential; <code>query</code> runs as <code>cortex_reader</code>, so it cannot write. Over HTTP later, the MCP gets a schema
of its own for its clients and an audit of their calls (decision <code>mcp-schema</code>).</p></section>
<section id="flow"><p class="kicker">A change, end to end</p><h2>From the agent's call to every canvas.</h2><figure>{flow_svg}</figure>{steps_html}</section>
<section id="undo"><p class="kicker">Undo</p><h2>Undo is a turn too.</h2><figure>{undo_svg}</figure>
<p>Every row change is in the log with its before and after, so undoing a turn applies the inverse of its changes, newest first, as a
new turn. Nothing is lost: the undo can itself be undone. Restore and branch switch are undos of every turn since the one wanted.
Rejecting an agent's change is exactly this.</p></section>
<section id="new-engine"><p class="kicker">Adding an engine</p><h2>A schema and a crate; nothing else changes.</h2><figure>{engine_svg}</figure>
<p>{issue("o9")} is built this way: the store takes its schema through the same five checked steps as <code>engine_mysql</code>, and the
binary registers its crate. Spanner ({issue("o10")}) and CockroachDB ({issue("o11")}) are flavors of it, not new engines.</p></section>
<section id="why"><p class="kicker">Why, and the evidence</p><h2>Every choice checked against published practice; three changed by it.</h2>
<div class="tbl"><table class="cols"><thead><tr><th>Choice</th><th>What the research says</th><th>State</th></tr></thead><tbody>{why_rows}</tbody></table></div></section>
<section id="sources"><p class="kicker">Sources</p><h2>What the choices rest on.</h2><ol>{sources}</ol></section>
"""

HTML = page("architecture", "SchemaForge · the architecture", CSS, body)
