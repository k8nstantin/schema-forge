"""The Owner Template page: the template every engine and feature copies, drawn and listed from docs/owner-template."""
import glob, os, re, tomllib
from common import REPO, Svg, e, page, rules, table_files

FOLDER = "docs/owner-template/schema"
tables = {t["short"]: t for t in table_files(FOLDER)}
owner = tomllib.load(open(f"{REPO}/docs/owner-template/owner.toml", "rb"))
rl = rules(FOLDER)
migrations = [(os.path.basename(f), open(f, encoding="utf-8").read()) for f in sorted(glob.glob(f"{REPO}/{FOLDER}/migrations/*.sql"))]

# --- options first, then the two shapes ------------------------------------------------------------------------------
g = Svg(1040, 330, "What an owner adds: options of cortex rows, declared as rows, and tables only for what is many rows of its own.")
g.band(10, 10, 360, 310, "cortex")
g.band(420, 10, 610, 310, "engine_example")
g.box("c.decl", 40, 40, 300, 52, "option_declarations", "seeded by the owner: name, type, values", cls="box")
g.box("c.objects", 40, 150, 300, 52, "objects.options", "{format, frozen, location, ...}", cls="pri")
g.box("c.columns", 40, 240, 300, 52, "columns", "", cls="pri")
shapes = [("column_codecs", 150, "1. an ordered list", "in order, each a UUIDv7"),
          ("nested_fields", 240, "2. a tree", "parent: the same table")]
for nm, y, title, sub in shapes:
    g.box(nm, 600, y, 280, 52, nm, title, cls="eng")
for nm, y, *_ in shapes:
    ax, ay, aw, ah = g.boxes[nm]; bx, by, bw, bh = g.boxes["c.columns"]
    g.parts.append(f'<line x1="{ax}" y1="{ay + ah / 2}" x2="{bx + bw + 2}" y2="{by + bh / 2}" class="ea" marker-end="url(#mka)"/>')
    g.lines.append((nm, "c.columns", ax, ay + ah / 2, bx + bw + 2, by + bh / 2))
ax, ay, aw, ah = g.boxes["c.objects"]; bx, by, bw, bh = g.boxes["c.decl"]
g.parts.append(f'<line x1="{ax + aw / 2}" y1="{ay}" x2="{bx + bw / 2}" y2="{by + bh + 2}" class="es" marker-end="url(#mks)"/>')
g.text(ax + aw / 2 + 8, ay - 22, "checked against", "lb m")
ax, ay, aw, ah = g.boxes["nested_fields"]
g.parts.append(f'<path d="M{ax + aw},{ay + 14} C{ax + aw + 60},{ay - 10} {ax + aw + 60},{ay + ah + 10} {ax + aw + 2},{ay + ah - 14}" class="ea" fill="none" marker-end="url(#mka)"/>')
g.text(ax + aw + 66, ay + ah / 2 + 4, "parent", "lb m")
g.containers = set()
shapes_svg = g.render()
seed = open(f"{REPO}/{FOLDER}/seeds/declaration.sql", encoding="utf-8").read()
declared = re.findall(r"\('example/(\w+)/(\w+)', 'example', '\w+', '\w+', '(\w+)', (true|false), (NULL|'[^']*'), '((?:[^']|'')*)'\)", seed)
decl_rows = "".join(f"<tr><td><code>{e(part)}</code></td><td><code>{e(name)}</code></td><td>{e(vt)}{'' if nl == 'true' else ', not null'}</td>"
                    f"<td>{e(ch.strip(chr(39)) if ch != 'NULL' else 'any')}</td><td>{e(about.replace(chr(39) * 2, chr(39)))}</td></tr>"
                    for part, name, vt, nl, ch, about in declared)

# --- versions: frozen 1, add, then remove ----------------------------------------------------------------------------
g = Svg(1040, 210, "A rename in two versions: the first adds and copies, a later release removes; version 1 is frozen once version 2 exists.")
steps = [("v1", "1_tables.sql", "frozen: the files as shipped"), ("v2", "2_..._add.sql", "adds compaction_policy, copies"),
         ("v3", "3_..._drop_old.sql", "removes compaction"), ("files", "the table files", "always the newest shape")]
for i, (k, t, s) in enumerate(steps):
    g.box(k, 30 + i * 255, 60, 220, 60, t, s, cls="lg" if k != "files" else "pri")
for a, b, lab, x in [("v1", "v2", "release n", 267), ("v2", "v3", "a later release", 522)]:
    g.arrow(a, b, "", cls="ea"); g.text(x, 46, lab, "lb m", "middle")
g.parts.append('<line x1="725" y1="90" x2="793" y2="90" class="es" marker-end="url(#mks)"/>')
g.text(760, 150, "= applying 1 to 3 to an empty database (pg_dump --schema-only, PostgreSQL 18)", "lb", "middle")
g.containers = set()
versions_svg = g.render()

def code(text): return f"<pre>{e(text.strip())}</pre>"
cards = "".join(
    f'<article class="tbl"><h3><code class="tn">{e(tables[nm]["name"])}</code><span class="pill eng">{e(title)}</span>'
    f'<span class="path">{e(tables[nm]["file"])}</span></h3><p class="lede">{e(sub[:1].upper() + sub[1:])}. {e(" ".join(tables[nm]["notes"]))}</p>'
    f'<details><summary>The file, whole</summary>{code(tables[nm]["text"])}</details></article>'
    for nm, _, title, sub in sorted(shapes, key=lambda s: s[2]))
rules_rows = "".join(f'<tr><td><code>{e(q["name"])}</code></td><td>{e(q["says"])}</td><td><details><summary class="small"><code>{e(q["view"])}</code></summary><pre>{e(q["sql"])}</pre></details></td></tr>' for q in rl)
mig = "".join(f'<details><summary><code>{e(n)}</code></summary>{code(t)}</details>' for n, t in migrations)
toml = open(f"{REPO}/docs/owner-template/owner.toml").read()

CSS = """.tbl{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:14px 0;min-width:0}
.tbl h3{margin:0 0 4px}.tn{font-size:16px;font-weight:600;background:none;border:0;padding:0}"""
body = f"""
<div class="tb" role="group" aria-label="Title block">
  <div><span>Owner</span><b>{e(owner["id"])} · {e(owner["kind"])}</b></div><div><span>Namespace</span><b>{e(owner["namespace"])}</b></div>
  <div><span>Version</span><b>{owner["version"]}</b></div><div><span>Needs cortex</span><b>{owner["requires_cortex"]}</b></div><div><span>Date</span><b>2026-11-26</b></div>
</div>
<h1>The Owner Template</h1>
<p class="lede"><b>Modularity and yet coherence.</b> Every engine and every feature (insight, a semantic layer, design rules, pipelines) brings its own
tables, in its own namespace, versioned on its own, and never changes another owner's; every one of them is built the same way, refers to the
cortex by foreign keys, and is enforced by the same database. <code>docs/owner-template</code> is a complete owner, <code>example</code>, to copy.
Everything below is read from its files.</p>

<section id="card"><h2>The owner's card</h2><p class="lede"><code>owner.toml</code>: who it is, where its tables live, its newest version and the cortex it is written against.</p>{code(toml)}</section>

<section id="shapes"><h2>Options first, then the two shapes</h2><p class="lede">What the engine says of one cortex row is that row's <code>options</code>, each option a row of <code>cortex.option_declarations</code> in the owner's seeds: its type, the values it may take and the versions that have it, checked by the database as the row is written. A new option is a new row, never a column (decision declared-options). A table is only for what is many rows of its own.</p>
<figure>{shapes_svg}<figcaption>Solid arrows are foreign keys: an owner's rows always belong to a cortex row, and go with it when it is deleted. The dashed one is the check every option passes as it is written.</figcaption></figure>
<h3>Example's declared options <span class="path">{FOLDER}/seeds/declaration.sql</span></h3>
<div class="scroll"><table class="t"><thead><tr><th>Part</th><th>Option</th><th>Type</th><th>Values</th><th>What it is</th></tr></thead><tbody>{decl_rows}</tbody></table></div>
{cards}</section>

<section id="rules"><h2>Its rules</h2><p class="lede">What a foreign key cannot state: one view each, <code>broken_&lt;rule&gt;</code>. <code>cortex.enforce_rules('{e(owner["namespace"])}')</code> puts the triggers on every table each view reads.</p>
<div class="scroll"><table class="t"><thead><tr><th>Rule</th><th>What it requires</th><th>Its view</th></tr></thead><tbody>{rules_rows}</tbody></table></div></section>

<section id="versions"><h2>Its versions</h2><p class="lede">Every change adds. A rename or a removal takes two versions, in different releases. The table files always show the newest shape, so version 1 is frozen once version 2 is written, and a column a migration adds is written last. A whole-schema change is a version too: 4 gave every table its design, 5 made one row's facts options.</p>
<figure>{versions_svg}<figcaption>Proved on PostgreSQL 18: a database made from every version in order and one made from the table files dump to the same schema, line for line.</figcaption></figure>
{mig}</section>
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("card", "Card"), ("shapes", "Shapes"), ("rules", "Rules"), ("versions", "Versions")])
HTML = page("template", "Owner Template", CSS, body, sub)
