"""The Engines page: two full-feature engines and the families of databases that fall into them, how an engine plugs in,
who writes what, how a turn flows, and how an engine is proven. Every flavor, fact, source and kind is read from the
engines' seeds; every box of every diagram is a link."""
import json
import re

from common import REPO, REPO_URL, Svg, e, links, page

L = links()
SEEDS = open(f"{REPO}/engines/mysql/seeds/engine.sql", encoding="utf-8").read()
FLAVORS = [(m.group(1), m.group(2), json.loads(m.group(3)), json.loads(m.group(5)))
           for m in re.finditer(r"\('mysql/(\w+)', 'mysql', '\w+', '([^']+)',\s*'(\{.*?\})', '(\{.*?\})',\s*'(\[.*?\])'\)", SEEDS, re.S)]
KINDS = [(m.group(1), m.group(2), m.group(3), m.group(4)) for m in
         re.finditer(r"\('mysql/(\w+)', 'mysql', '\w+', '([^']+)', (?:true|false), '(\w+)', \d+, (NULL|'[\d.]+')\)", SEEDS)]
VERSIONS = re.findall(r"\('mysql/([\d.]+)', 'mysql', '[\d.]+', 'MySQL [\d.]+', \d+\)", SEEDS)
GH = f"{REPO_URL}/blob/main"
DB = L.get("database", "database.html")

# --- 1. the families ---------------------------------------------------------------------------------------------------
g = Svg(1040, 490, "Two full-feature engines; every managed service and compatible database falls into its family as a subset; both plug into one cortex.")
g.band(10, 10, 500, 400, "the MySQL family: engine_mysql, built")
g.band(530, 10, 500, 400, "the PostgreSQL family: engine_postgresql, next")
my_subsets = [("percona", "Percona Server", "a superset: one table more"), ("rds", "Amazon RDS", "refuses 3 facts"), ("cloudsql", "Cloud SQL", "InnoDB only"),
              ("aurora", "Amazon Aurora", "MySQL 8.0 only"), ("tidb", "TiDB", "planned: 2 tables more")]
def across(g, a, b):
    """A straight arrow from a box to the tall engine box beside it, at the box's own height."""
    ax, ay, aw, ah = g.boxes[a]
    bx, by, bw, bh = g.boxes[b]
    y = ay + ah / 2
    x1, x2 = (ax + aw, bx - 2) if ax < bx else (ax, bx + bw + 2)
    g.parts.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" class="es" marker-end="url(#mks)"/>')
    g.lines.append((a, b, x1, y, x2, y))


for i, (k, t, s) in enumerate(my_subsets):
    g.box(f"my_{k}", 30, 46 + i * 70, 200, 50, t, s, cls="eng" if k != "tidb" else "box", href=f"#flavor-{k}")
g.box("engine_mysql", 290, 46, 200, 330, "engine_mysql", "MySQL 5.7 · 8.0 · 8.4 · 9.7", cls="pri", href="#mysql")
for k, *_ in my_subsets:
    across(g, f"my_{k}", "engine_mysql")
pg_subsets = [("rds", "Amazon RDS"), ("cloudsql", "Cloud SQL"), ("aurora", "Amazon Aurora"), ("alloydb", "AlloyDB"), ("spanner", "Spanner"), ("cockroach", "CockroachDB")]
for i, (k, t) in enumerate(pg_subsets):
    g.box(f"pg_{k}", 810, 40 + i * 58, 200, 44, t, "a subset, planned", cls="box", href="#postgresql")
g.box("engine_postgresql", 550, 46, 200, 330, "engine_postgresql", "PostgreSQL 15 to 18", cls="box", href="#postgresql")
for k, _ in pg_subsets:
    across(g, f"pg_{k}", "engine_postgresql")
g.box("cortex", 380, 420, 280, 56, "the cortex", "both plug into it", cls="pri", href=f"{DB}#cortex")
g.arrow("engine_mysql", "cortex")
g.arrow("engine_postgresql", "cortex")
g.containers = set()
families_svg = g.render()

# --- 2. the rule for what a subset adds ----------------------------------------------------------------------------------
g = Svg(1040, 330, "What a subset brings, and where it goes: a refusal is a declared fact; a new kind a typed table; a new option a declared key; a key that points at an object a typed column.")
g.box("fact", 20, 135, 200, 60, "a fact of a flavor", "from its provider's docs", cls="pri", href="#rule")
rules = [("refuses", 20, "it refuses something", "cortex.engine_flavors.refuses", "refused as the design is written"),
         ("kind", 100, "a new kind of object", "a typed table", "TiDB placement policies, Percona dictionaries"),
         ("option", 180, "a new option", "a flavor_options key", "declared, typed, checked"),
         ("ref", 260, "a key that points at an object", "a typed column", "a foreign key, never a name")]
for k, y, cond, where, sub in rules:
    g.box(f"c_{k}", 330, y, 250, 50, cond, cls="box", href="#rule")
    g.box(f"w_{k}", 690, y, 330, 50, where, sub, cls="eng", href="#rule")
    g.arrow("fact", f"c_{k}", cls="es")
    g.arrow(f"c_{k}", f"w_{k}")
g.containers = set()
rule_svg = g.render()

# --- 3. plugging in: five steps, each as its role ------------------------------------------------------------------------
steps = [("s1", "the superuser", "its roles, its schema"), ("s2", "cortex_owner", "its row; open_to"), ("s3", "<ns>_owner", "its tables, functions"),
         ("s4", "cortex_owner", "seeds; plug_in checks"), ("s5", "<ns>_owner", "fit_plugin: grants, fence")]
g = Svg(1040, 190, "Plugging a plugin in: five steps, each run as the role it belongs to; a table that is not a plug is refused at step four.")
for i, (k, t, s) in enumerate(steps):
    g.box(k, 14 + i * 206, 70, 186, 60, f"{i + 1}. {t}", s, cls="pri" if i in (1, 3) else "eng", href=f"#step-{i + 1}")
for (a, *_), (b, *_) in zip(steps, steps[1:]):
    g.arrow(a, b)
g.text(520, 40, "tools/sf/plugin.py runs them; tools/mysql/load.py proves engine_mysql plugged in", "lb m", "middle")
g.text(520, 166, "every plugin the same way: its namespace, its owner, its service account, its seeds", "lb", "middle")
g.containers = set()
plug_svg = g.render()

# --- 4. who writes what ------------------------------------------------------------------------------------------------
g = Svg(1040, 400, "Who writes what: the app and the agent write the cortex model; each plugin's service account is the only writer of its namespace, fenced to its own engine's designs.")
g.box("app", 20, 70, 220, 54, "cortex_service", "the app", cls="pri", href="#roles")
g.box("agent", 20, 170, 220, 54, "cortex_agent", "the coding agent", cls="pri", href="#roles")
g.box("reader", 20, 270, 220, 54, "cortex_reader", "reads only", cls="box", href="#roles")
g.box("t_my", 400, 30, 240, 60, "engine_mysql tables", "MySQL's own", cls="eng", href=f"{DB}#engine_mysql")
g.box("model", 400, 170, 240, 60, "the cortex model", "every engine shares it", cls="pri", href=f"{DB}#cortex")
g.box("t_pg", 400, 310, 240, 60, "engine_postgresql tables", "PostgreSQL's own", cls="box", href="#postgresql")
g.box("s_my", 800, 90, 220, 54, "engine_mysql_service", "MySQL designs only", cls="eng", href="#roles")
g.box("s_pg", 800, 250, 220, 54, "engine_postgresql_service", "PostgreSQL designs only", cls="box", href="#roles")
g.arrow("app", "model", "writes")
g.arrow("agent", "model")
g.arrow("reader", "model", cls="es")
g.arrow("s_my", "t_my", "the only writer")
g.arrow("s_my", "model")
g.arrow("s_pg", "model")
g.arrow("s_pg", "t_pg", "the only writer")
g.containers = set()
roles_svg = g.render()

# --- 5. one turn -------------------------------------------------------------------------------------------------------
g = Svg(1040, 220, "One turn: the app opens it, the plugin writes under its own operation, every row is logged, the app commits it; undo is the cortex's, the same for every engine.")
turn = [("open", "the app opens a turn", "cortex_service"), ("write", "the plugin writes", "under its operation"),
        ("log", "every row logged", "cortex.log_row"), ("commit", "the app commits", "numbered, rung")]
for i, (k, t, s) in enumerate(turn):
    g.box(k, 20 + i * 255, 60, 220, 60, t, s, cls="lg" if k == "log" else "pri", href=f"{DB}#how")
for (a, *_), (b, *_) in zip(turn, turn[1:]):
    g.arrow(a, b)
g.box("undo", 530, 150, 220, 50, "undo, restore, branch", "the cortex's, for every engine", cls="eng", href=f"{DB}#how")
g.arrow("undo", "log", "inverse")
g.containers = set()
turn_svg = g.render()

# --- 6. the proof: the round trip --------------------------------------------------------------------------------------
g = Svg(1040, 300, "How an engine is proven: a sample of every object, read, stored, read back, written into a fresh server and read again; nothing may differ.")
proof = [("sample", 20, 40, "every-object sample", "per version and flavor", f"{GH}/tools/mysql/samples"),
         ("a", 280, 40, "server A", "a container", f"{GH}/tools/sf/servers.py"),
         ("read", 540, 40, "reader.py", "a live server read", f"{GH}/engines/mysql/reader.py"),
         ("store", 800, 40, "the store", "as engine_mysql_service", f"{GH}/engines/mysql/rows.py"),
         ("write", 800, 190, "writer.py", "rows as SQL", f"{GH}/engines/mysql/writer.py"),
         ("b", 540, 190, "server B", "fresh, same image", f"{GH}/tools/sf/servers.py"),
         ("cmp", 280, 190, "compared", "model and SHOW CREATE", f"{GH}/tools/mysql/roundtrip.py")]
for k, x, y, t, s, h in proof:
    g.box(k, x, y, 220, 60, t, s, cls="lg" if k == "cmp" else ("eng" if k in ("read", "write", "store") else "box"), href=h)
for a, b in [("sample", "a"), ("a", "read"), ("read", "store"), ("store", "write"), ("write", "b"), ("b", "cmp")]:
    g.arrow(a, b)
g.text(520, 150, "read back from the store: identical", "lb m", "middle")
g.text(520, 286, "7 servers, the samples and 2 private production schemas: identical (tools/mysql/all.py, in CI)", "lb", "middle")
g.containers = set()
proof_svg = g.render()


def card(t, s, id_=None, href=None):
    head = f'<h3><a href="{e(href)}">{t}</a></h3>' if href else f"<h3>{t}</h3>"
    return f'<div class="card"{f" id={chr(34)}{id_}{chr(34)}" if id_ else ""}>{head}<p>{s}</p></div>'


def facts(refuses):
    out = []
    for k, label in (("versions", "versions"), ("kinds", "kinds of object"), ("engines", "storage engines"), ("privileges", "privileges"),
                     ("table_options", "table options"), ("database_names", "database names")):
        if refuses.get(k):
            out.append(f"<li><b>{label}:</b> {', '.join(f'<code>{e(x)}</code>' for x in refuses[k])}</li>")
    return "<ul>" + "".join(out) + "</ul>" if out else "<p class=small>nothing: it is the engine itself</p>"


flavor_cards = "".join(
    f'<div class="card" id="flavor-{e(k)}"><h3>{e(name)}</h3><p class="small">refuses</p>{facts(ref)}'
    f'<p class="small">{" · ".join(f"<a href={chr(34)}{e(s)}{chr(34)}>source</a>" for s in src)}</p></div>'
    for k, name, ref, src in FLAVORS)
flavor_cards += ('<div class="card" id="flavor-tidb"><h3>TiDB <span class="pill">planned</span></h3><p class="small">a subset of MySQL 8.0, by the rule</p><ul>'
                 "<li><b>refuses:</b> procedures, functions, triggers, events, FULLTEXT, spatial, tablespaces, subpartitions, every engine but its own</li>"
                 "<li><b>new kinds:</b> sequences, placement policies (two typed tables)</li>"
                 "<li><b>a reference:</b> a table's, database's or partition's placement policy (a typed column)</li>"
                 "<li><b>new options:</b> AUTO_RANDOM, SHARD_ROW_ID_BITS, PRE_SPLIT_REGIONS, AUTO_ID_CACHE, TTL, TiFlash replicas, clustered keys (flavor_options)</li></ul>"
                 f'<p class="small"><a href="https://docs.pingcap.com/tidb/stable/mysql-compatibility/">source</a> · surveyed with <a href="{GH}/tools/mysql/survey.py">tools/mysql/survey.py</a></p></div>')
kind_rows = "".join(f'<tr><td><code>{e(k)}</code></td><td>{e(n)}</td><td><a href="{DB}#engine_mysql.{e(t)}"><code>engine_mysql.{e(t)}</code></a></td>'
                    f'<td>{e(s.strip(chr(39))) + " and later" if s != "NULL" else "every version"}</td></tr>' for k, n, t, s in KINDS)
step_cards = "".join(card(f"{i + 1}. {e(t)}", e(x), id_=f"step-{i + 1}") for i, (t, x) in enumerate([
    ("The superuser", "Makes the plugin's two roles, <namespace>_owner (no login) and <namespace>_service, and its schema, owned by its owner."),
    ("cortex_owner opens the cortex", "Adds the plugin's row to cortex.plugins and runs cortex.open_to: its owner may see the cortex and reference the tables its own extend, nothing else."),
    ("The plugin's owner makes its tables", "Its tables and functions, each a plug: id and design, UNIQUE (design, id), a foreign key to the cortex row it extends; and lets cortex_owner see them."),
    ("cortex_owner checks it", "Loads its seeds (engine, versions, flavors, kinds, plugin_tables) and runs cortex.plug_in: a table that is not a plug, or not registered, is refused."),
    ("The plugin's owner fits it", "cortex.fit_plugin: its service account the only writer of its tables, the cortex's accounts readers, every change logged, row-level security fencing it to its engine's designs."),
]))

CSS = (".prompt{white-space:pre-wrap;font:14px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-wrap:anywhere}"
       ".d a rect{cursor:pointer}.d a:hover rect{stroke-width:2.8}.d a:hover text{text-decoration:underline}"
       ".card ul{margin:6px 0 8px;padding-left:18px;font-size:14px;color:var(--ink2)}.card li{margin:2px 0}"
       ".kinds{width:100%;border-collapse:collapse;font-size:14px}.kinds td,.kinds th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left}"
       "figure{margin:18px 0;overflow-x:auto}figure svg{min-width:720px}")

body = f"""
<header class="hero">
  <p class="eyebrow">Two engines, a dozen databases</p>
  <h1>Build two engines. Get every database in their families.</h1>
  <p>%PRODUCT% builds two full-feature engines, each once across every version of its database: <b>engine_mysql</b> and <b>engine_postgresql</b>.
  Every managed service, distribution and compatible database is a subset that falls right into its family: what it refuses is a declared fact,
  what it adds a typed table or a declared option. What looks very complex is solved by the design of the schema.</p>
  <div class="btns"><a class="btn btn-primary" href="#families">See the families</a><a class="btn btn-secondary" href="{DB}">The database</a></div>
</header>

<section id="families"><p class="kicker">The families</p><h2>Two full-feature engines. Every subset falls into one.</h2>
<p class="lede">The plain engine has the most features; a managed service or a compatible database has fewer, and sometimes a few of its own.
Building the full engine once, across every version, builds the schema of its whole family. Click any box.</p>
<figure>{families_svg}<figcaption>Solid: built and proven. Dashed or plain: next, by the same rule. A true fork that diverges beyond a subset (MariaDB) becomes an engine of its own, built from its family's engine as a template.</figcaption></figure></section>

<section id="mysql"><p class="kicker">engine_mysql · built</p><h2>Every object of MySQL {", ".join(VERSIONS)}.</h2>
<p class="lede">24 typed tables in its own namespace, each a plug of the cortex. Each kind of object, the versions that have it, and the table that holds it:</p>
<table class="kinds"><thead><tr><th>Kind</th><th>Name</th><th>Its table</th><th>Versions</th></tr></thead><tbody>{kind_rows}</tbody></table>
<p class="small">Read from <a href="{GH}/engines/mysql/seeds/engine.sql">engines/mysql/seeds/engine.sql</a>. Every table, column and reference: <a href="{DB}#engine_mysql">the Database page</a>.</p>
<h3>Its flavors, and what each refuses</h3><div class="cards">{flavor_cards}</div></section>

<section id="rule"><p class="kicker">The rule</p><h2>What a subset brings, and where it goes.</h2>
<figure>{rule_svg}<figcaption>A refusal costs a fact; a new kind a table; a new option a key. A subset never costs an engine. Decision service-plugins in <a href="{GH}/specs/root.xml">specs/root.xml</a>.</figcaption></figure></section>

<section id="postgresql"><p class="kicker">engine_postgresql · next</p><h2>PostgreSQL 15 to 18, and its family.</h2>
<p class="lede">The same baseline and principles as engine_mysql, its own and far larger design: schemas, relations, types, domains, enums, ranges,
sequences, functions and procedures, aggregates, operators and their classes, casts, collations, statistics, text search, policies, rules, triggers and
event triggers, foreign data wrappers and servers, publications and subscriptions, extensions, roles and privileges. Amazon RDS, Cloud SQL, Amazon
Aurora, AlloyDB, Spanner and CockroachDB fall into it as subsets. Objective <a href="{REPO_URL}/issues/141">#141</a>.</p></section>

<section id="plug"><p class="kicker">How an engine plugs in</p><h2>Five steps, each as its role.</h2>
<figure>{plug_svg}</figure><div class="cards">{step_cards}</div></section>

<section id="roles"><p class="kicker">Who writes what</p><h2>No cross-engine writes, ever.</h2>
<figure>{roles_svg}<figcaption>Every namespace has two roles named after it: &lt;namespace&gt;_owner owns it and never signs in; &lt;namespace&gt;_service is its service account,
with only the privileges its work needs. engine_postgresql_service cannot even read engine_mysql. Proven by <a href="{GH}/tools/cortex/privileges.py">tools/cortex/privileges.py</a>.</figcaption></figure></section>

<section id="turn"><p class="kicker">One turn</p><h2>Every change logged, every engine undone the same way.</h2>
<figure>{turn_svg}</figure></section>

<section id="proof"><p class="kicker">How an engine is proven</p><h2>The round trip: nothing may differ.</h2>
<figure>{proof_svg}<figcaption>Every box links to its file. CI runs it on every pull request; the private production schemas run where they are.</figcaption></figure></section>

<section id="yours"><div class="cta"><p class="kicker">Your database next</p><h2>A subset of a family, or an engine of its own.</h2>
<p class="lede">If your database is a subset of MySQL or PostgreSQL, it is a flavor: its facts, with their sources, and by the rule a table or a key where it adds.
If it is a database of its own, it is an engine: its own package, built the way engine_mysql was. Paste this into your agent:</p>
<pre class="prompt">Read %SITE%agents.xml, then {GH}/specs/root.xml (decision service-plugins), and tell me whether &lt;my database&gt; is a subset of an engine family or an engine of its own; change nothing yet.</pre></div></section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("families", "Families"), ("mysql", "engine_mysql"), ("rule", "The rule"), ("postgresql", "engine_postgresql"),
                                                       ("plug", "Plugging in"), ("roles", "Who writes"), ("turn", "One turn"), ("proof", "The proof")])
HTML = page("engines", "%PRODUCT% Engines", CSS, body, sub)
