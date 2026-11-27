"""The Database page: the one database, schema_forge, as its owners' folders give it: every namespace with its two roles,
every table with its columns, types, references, keys and comments, read from the files (the cortex, then every
plugin); nothing about a table is typed here."""
import os
import tomllib

from common import OWNERS, REPO, database, e, page

db, edges = database()

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
.toc{display:flex;flex-wrap:wrap;gap:10px;margin:10px 0}"""

body = f"""
<header class="hero"><p class="eyebrow">The database</p><h1>One database, <code>schema_forge</code>.</h1>
<p class="lede">The cortex holds what every engine shares and the plugs every engine fits into; each engine is a plugin with its own
namespace, its own owner and its own service account, the only writer of its tables. Every id is a UUIDv7. Every table below is
read from its file; every column's comment is its comment in the database. {total} tables.</p>
<div class="toc">{"".join(toc)}</div></header>
{"".join(sections)}
"""

HTML = page("database", "SchemaForge · the database", CSS, body)
