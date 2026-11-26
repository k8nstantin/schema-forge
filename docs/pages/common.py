"""What every page of the the product pack shares: the schema folders read as data, the SVG drawing, the look and the
shared head. Nothing about a table is typed here: every table, column, key and reference is read from its file."""
import glob, html, json, os, re

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
e = html.escape
OWNERS = [("cortex", "schema/cortex"), ("ui", "schema/ui")] + [
    ("engine_" + os.path.basename(os.path.dirname(d)), os.path.relpath(d, REPO))
    for d in sorted(glob.glob(f"{REPO}/engines/*/schema"))] + [
    (os.path.basename(os.path.dirname(d)), os.path.relpath(d, REPO)) for d in sorted(glob.glob(f"{REPO}/features/*/schema"))]
TYPES = "TEXT|INTEGER|BIGINT|NUMERIC|BOOLEAN|UUID|TIMESTAMPTZ|JSONB"
COLDEF = re.compile(r'^\s+("?[a-z_][a-z0-9_]*"?)\s+(' + TYPES + r')\b(.*?)(?:--\s*(.*))?$')


def short(name):
    """A table's name without its namespace: cortex.objects is objects."""
    return name.split(".", 1)[1] if "." in name else name


def table_files(folder):
    """Every table of a schema folder: its full name (namespace.table), what it holds, its columns, its keys and
    references, its text. A file of the folder that creates no table (enforce_rules.sql) is not a table."""
    out = []
    for f in sorted(glob.glob(f"{REPO}/{folder}/*.sql")):
        text = open(f, encoding="utf-8").read()
        m = re.search(r"^CREATE TABLE ([\w.]+) \(", text, re.M)
        if not m:
            continue
        name = m.group(1)
        lines = text.splitlines()
        first = next(i for i, l in enumerate(lines) if l.startswith("CREATE TABLE"))
        head = [l[3:].strip() for l in lines[:first] if l.startswith("-- ")]
        about = re.sub(r"\s*Owner: [\w]+\.\s*$", "", head[0].split(":", 1)[1].strip())
        notes = [re.sub(r"^Owner: \w+\.\s*", "", h) for h in head[1:]]
        notes = [n for n in notes if n]
        cols, constraints, indexes = [], [], []
        in_table = False
        for l in lines:
            if l.startswith("CREATE TABLE"):
                in_table = True
                continue
            if l.startswith(");"):
                in_table = False
                continue
            c = COLDEF.match(l) if in_table else None
            if c:
                body = c.group(3)
                ref = re.search(r"REFERENCES ([\w.]+) \((\w+)\)(?: ON DELETE (CASCADE|SET NULL))?", body)
                chk = re.search(r"CHECK \((.*)\)\s*,?\s*$", body)
                cols.append({
                    "name": c.group(1).strip('"'), "type": c.group(2),
                    "pk": "PRIMARY KEY" in body, "not_null": "NOT NULL" in body, "unique": " UNIQUE" in body,
                    "default": (re.search(r"DEFAULT (\S+?),?(?:\s|$)", body) or [None, None])[1],
                    "ref": ref.group(1) if ref else None, "ref_col": ref.group(2) if ref else None,
                    "on_delete": ref.group(3) if ref and ref.group(3) else None,
                    "check": chk.group(1) if chk else None, "comment": (c.group(4) or "").strip()})
            elif in_table and l.strip().startswith("FOREIGN KEY (design, "):
                # a reference within the design: (design, column) -> (design, id); drawn as the column's own
                fk = re.match(r'FOREIGN KEY \(design, "?(\w+)"?\) REFERENCES ([\w.]+) \(design, id\)(?: ON DELETE (CASCADE|SET NULL))?', l.strip())
                col = next(c for c in cols if c["name"] == fk.group(1))
                col.update({"ref": fk.group(2), "ref_col": "id", "on_delete": fk.group(3)})
            elif in_table and l.strip().startswith(("UNIQUE", "CHECK")):
                constraints.append(l.split("--")[0].strip().rstrip(","))
            elif l.startswith("CREATE") and "INDEX" in l:
                indexes.append(l.split("--")[0].strip())
        out.append({"name": name, "short": short(name), "about": about, "notes": notes, "columns": cols,
                    "constraints": constraints, "indexes": indexes, "text": text, "file": os.path.relpath(f, REPO)})
    return out


def rules(folder):
    """Every rule of a schema folder's rules/: its name, what it requires, its view and the view's query."""
    q = []
    for f in sorted(glob.glob(f"{REPO}/{folder}/rules/*.sql")):
        text = open(f, encoding="utf-8").read()
        m = re.match(r"-- ([a-z0-9-]+): (.*?) Owner: \w+\.\n", text)
        v = re.search(r"CREATE VIEW ([\w.]+) AS\n(.*?);\n", text, re.S)
        q.append({"name": m.group(1), "says": m.group(2), "view": v.group(1), "sql": v.group(2).strip(),
                  "file": os.path.relpath(f, REPO)})
    return q


def database():
    """Every owner's tables and rules, and every reference between tables, by full name."""
    db = {o: {"folder": f, "tables": table_files(f), "rules": rules(f)} for o, f in OWNERS}
    edges = []
    for o, d in db.items():
        for t in d["tables"]:
            for c in t["columns"]:
                if c["ref"]:
                    edges.append((t["name"], c["name"], c["ref"]))
    return db, edges


# --- drawing ---------------------------------------------------------------------------------------------------
class Svg:
    """A diagram of boxes and arrows; an arrow runs from the referring box's edge to the referred box's edge."""

    def __init__(self, w, h, label):
        self.w, self.h, self.label, self.parts, self.boxes = w, h, label, [], {}
        self.lines, self.labels = [], []   # for the layout check: (a, b, x1, y1, x2, y2) and (x, y, w, h, text)

    def box(self, key, x, y, w, h, title, sub="", cls="box", href=None):
        self.boxes[key] = (x, y, w, h)
        self.overflow = getattr(self, "overflow", [])
        if 7.4 * len(title) > w - 8 or 5.9 * len(sub) > w - 8:
            self.overflow.append(f"text of {key} overflows its box")
        self.parts.append(f'<g class="nd"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" class="{cls}"/>'
                          f'<text x="{x + w / 2}" y="{y + (h / 2 + 4 if not sub else 19)}" text-anchor="middle" class="m b6">{e(title)}</text>'
                          + (f'<text x="{x + w / 2}" y="{y + 35}" text-anchor="middle" class="lb">{e(sub)}</text>' if sub else "") + "</g>")
        if href:  # the box is a link: to the table's own entry on the page
            self.parts[-1] = f'<a href="{e(href)}"><title>{e(key)}</title>{self.parts[-1]}</a>'


    def _edge_point(self, key, tx, ty):
        x, y, w, h = self.boxes[key]
        cx, cy = x + w / 2, y + h / 2
        dx, dy = tx - cx, ty - cy
        if dx == 0 and dy == 0:
            return cx, cy
        sx = (w / 2) / abs(dx) if dx else float("inf")
        sy = (h / 2) / abs(dy) if dy else float("inf")
        s = min(sx, sy)
        return cx + dx * s, cy + dy * s

    def arrow(self, a, b, label="", cls="ea", lx=0, ly=0):
        ax, ay, aw, ah = self.boxes[a]
        bx, by, bw, bh = self.boxes[b]
        acx, acy, bcx, bcy = ax + aw / 2, ay + ah / 2, bx + bw / 2, by + bh / 2
        x1, y1 = self._edge_point(a, bcx, bcy)
        x2, y2 = self._edge_point(b, acx, acy)
        mk = "mka" if cls == "ea" else "mks"
        self.parts.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" class="{cls}" marker-end="url(#{mk})"/>')
        self.lines.append((a, b, x1, y1, x2, y2))
        if label:
            t = (label if isinstance(label, (int, float)) else 0.5)
            mx, my = x1 + (x2 - x1) * 0.5 + lx, y1 + (y2 - y1) * 0.5 + ly
            self.parts.append(f'<text x="{mx:.1f}" y="{my - 4:.1f}" text-anchor="middle" class="lb m halo">{e(label)}</text>')
            tw = 6.6 * len(label)
            self.labels.append((mx - tw / 2, my - 14, tw, 13, label))

    def loop(self, a, label, side="right"):
        x, y, w, h = self.boxes[a]
        if side == "left":
            self.parts.append(f'<path d="M{x + 18},{y} C{x + 18},{y - 26} {x - 22},{y - 26} {x - 22},{y + 10} L{x - 2},{y + 14}" class="ea" fill="none" marker-end="url(#mka)"/>'
                              f'<text x="{x - 26}" y="{y - 10}" text-anchor="end" class="lb m">{e(label)}</text>')
            self.labels.append((x - 26 - 6.6 * len(label), y - 21, 6.6 * len(label), 13, label))
        else:
            self.parts.append(f'<path d="M{x + w - 18},{y} C{x + w - 18},{y - 26} {x + w + 22},{y - 26} {x + w + 22},{y + 10} L{x + w + 2},{y + 14}" class="ea" fill="none" marker-end="url(#mka)"/>'
                              f'<text x="{x + w + 26}" y="{y - 10}" class="lb m">{e(label)}</text>')
            self.labels.append((x + w + 26, y - 21, 6.6 * len(label), 13, label))

    def text(self, x, y, s, cls="lb", anchor="start"):
        self.parts.append(f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="{cls}">{e(s)}</text>')
        if cls != "cap":
            tw = (6.6 if "m" in cls.split() else 5.9) * len(s)
            x0 = x - tw / 2 if anchor == "middle" else (x - tw if anchor == "end" else x)
            self.labels.append((x0, y - 11, tw, 13, s))

    def band(self, x, y, w, h, label):
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" class="band"/>'
                          f'<text x="{x + 12}" y="{y + 18}" class="cap">{e(label)}</text>')

    def check(self):
        """Where the layout fails: an arrow through a box it does not join, two arrows crossing, labels overlapping."""
        out = list(getattr(self, "overflow", []))
        def seg_box(x1, y1, x2, y2, bx, by, bw, bh):
            for i in range(1, 40):
                t = i / 40; x, y = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
                if bx + 1 < x < bx + bw - 1 and by + 1 < y < by + bh - 1: return True
            return False
        def cross(p, q):
            (x1, y1, x2, y2), (x3, y3, x4, y4) = p, q
            d = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3)
            if abs(d) < 1e-9: return False
            ta = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / d
            tb = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / d
            return 0.02 < ta < 0.98 and 0.02 < tb < 0.98
        for a, b, *L in self.lines:
            for k, bx in self.boxes.items():
                if k not in (a, b) and k not in getattr(self, "containers", ()) and seg_box(*L, *bx): out.append(f"{a}->{b} runs through {k}")
        for i, (a, b, *L) in enumerate(self.lines):
            for c, d, *M in self.lines[i + 1:]:
                if len({a, b, c, d}) == 4 and cross(L, M): out.append(f"{a}->{b} crosses {c}->{d}")
        for i, (x, y, w, h, t) in enumerate(self.labels):
            for x2, y2, w2, h2, t2 in self.labels[i + 1:]:
                if x < x2 + w2 and x2 < x + w and y < y2 + h2 and y2 < y + h: out.append(f"label {t} overlaps label {t2}")
            for k, (bx, by, bw, bh) in self.boxes.items():
                if k not in getattr(self, "containers", ()) and x < bx + bw and bx < x + w and y < by + bh and by < y + h: out.append(f"label {t} overlaps box {k}")
        return out

    def render(self):
        return (f'<svg class="d" viewBox="0 0 {self.w} {self.h}" role="img" aria-label="{e(self.label)}">'
                '<defs><marker id="mka" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" class="mkf"/></marker>'
                '<marker id="mks" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0 L8,4 L0,8 z" class="mkm"/></marker></defs>'
                + "".join(self.parts) + "</svg>")


# --- the look and the shared head ---------------------------------------------------------------------------------
PAGES = [("home", "Start here"), ("engines", "Engines"), ("database", "Database"), ("template", "Owner Template"), ("build-spec", "Build Spec"), ("contribute", "Contribute")]


def _parameters():
    """The product's parameters, read from their seed: the one place a name or a link is written."""
    text = open(f"{REPO}/schema/cortex/seeds/workspace_parameters.sql", encoding="utf-8").read()
    return {k: json.loads(v.replace("''", "'")) for k, v in re.findall(r"\('([a-z_.]+)', '((?:[^']|'')*)', ", text)}


PARAMS = _parameters()
_BRIEF = __import__("xml.etree.ElementTree", fromlist=["parse"]).parse(f"{REPO}/specs/brief.xml").getroot()
PRODUCT = PARAMS["product.name"]
REPO_URL = PARAMS["product.repository"]
SITE_URL = PARAMS["product.site"]
BRANCH = PARAMS["product.branch"]
RAW_URL = REPO_URL.replace("https://github.com/", "https://raw.githubusercontent.com/") + "/" + BRANCH


def task_title(task):
    """A task's title as the root's naming convention gives it: <id> · <name>: <title>."""
    return f"{task.get('id')} · {task.get('name')}: {task.get('title')}"


FILES = {"site": "index.html", "home": "start.html", "database": "database.html", "template": "template.html",
         "build-spec": "build-spec.html", "engines": "engines.html", "contribute": "contribute.html"}


def links():
    """Where each page is: the site's own files, relative, so any domain serves it."""
    return dict(FILES)


CSS = r"""
:root{
  --bg:#F8F4FB;--surface:#FFFFFF;--raised:#FBF8FD;--ink:#1F062A;--ink2:#3B2447;--muted:#6B5A74;--line:#E3D9EA;
  --accent:#9500BF;--accent-soft:#F3E3FA;--engine:#0E7C86;--engine-soft:#DDF2F3;--log:#8A5A00;--log-soft:#FBF0DA;
  --crit:#B42318;--crit-soft:#FDECEA;
  --head:"Space Grotesk",system-ui,-apple-system,"Segoe UI",sans-serif;--sans:system-ui,-apple-system,"Segoe UI",Arial,sans-serif;
  --mono:"JetBrains Mono","Fira Code",ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;
  --bg:#1F062A;--surface:#2A0F38;--raised:#331545;--ink:#FFFFFF;--ink2:#E3D6EC;--muted:#ADACAC;--line:#45285A;
  --accent:#CC66FF;--accent-soft:#3C1452;--engine:#4FD1C5;--engine-soft:#123B3B;--log:#E8B04A;--log-soft:#33270F;--crit:#F97066;--crit-soft:#3A1A18}}
:root[data-theme="dark"]{color-scheme:dark;
  --bg:#1F062A;--surface:#2A0F38;--raised:#331545;--ink:#FFFFFF;--ink2:#E3D6EC;--muted:#ADACAC;--line:#45285A;
  --accent:#CC66FF;--accent-soft:#3C1452;--engine:#4FD1C5;--engine-soft:#123B3B;--log:#E8B04A;--log-soft:#33270F;--crit:#F97066;--crit-soft:#3A1A18}
*{box-sizing:border-box}
.hero{background:linear-gradient(160deg,#1F062A 0%,#2A0838 55%,#3A0A4D 100%);color:#FFFFFF;border-radius:18px;padding:56px 28px 48px;margin:0 0 8px;position:relative;overflow:hidden}
.hero::after{content:"";position:absolute;right:-120px;top:-120px;width:420px;height:420px;border-radius:50%;background:radial-gradient(closest-side,rgba(204,102,255,.35),transparent);pointer-events:none}
.hero .eyebrow{font:500 12px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:#CC66FF;margin:0 0 14px}
.hero h1{color:#FFFFFF;font-size:52px;margin:0 0 16px;max-width:22ch}
.hero p{color:#E3D6EC;font-size:18px;max-width:62ch;margin:0 0 24px}
.btns{display:flex;flex-wrap:wrap;gap:10px;position:relative;z-index:1}
.btn{display:inline-block;font:600 15px/1 var(--sans);padding:13px 20px;border-radius:10px;text-decoration:none;border:1.5px solid transparent}
.btn-primary{background:#9500BF;color:#FFFFFF;border-color:#9500BF}.btn-primary:hover{background:#B500BA;border-color:#B500BA;color:#FFFFFF}
.btn-secondary{background:transparent;color:#FFFFFF;border-color:rgba(255,255,255,.35)}.btn-secondary:hover{border-color:#CC66FF;color:#CC66FF}
.note{display:inline-block;margin-top:22px;font:500 12.5px var(--mono);color:#ADACAC;position:relative;z-index:1}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:14px;margin-top:18px}
.cards.two{grid-template-columns:repeat(auto-fit,minmax(min(100%,440px),1fr))}
.card{background:var(--surface);border:1px solid var(--line);border-radius:14px;padding:18px 18px 16px;min-width:0}
.card h3{margin:0 0 6px;font-size:18px}.card p{margin:0;color:var(--ink2);font-size:14.5px}
a.card{display:block;text-decoration:none;color:var(--ink)}a.card:hover{border-color:var(--accent)}a.card .go{display:block;margin-top:10px;color:var(--accent);font:600 13px var(--mono)}
.kicker{font:500 12px/1.4 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--accent);margin:0 0 6px}
.cta{background:var(--accent-soft);border:1px solid var(--line);border-radius:18px;padding:28px 24px}
.foot{margin-top:56px;padding-top:18px;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:8px 18px;font-size:13px;color:var(--muted)}
@media (max-width:640px){.nav{position:static}.nav .sub{display:none}.hero{padding:40px 18px 36px}.hero h1{font-size:36px}.hero p{font-size:16px}}
html{scroll-padding-top:calc(env(safe-area-inset-top,0px) + 120px)}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--sans);-webkit-font-smoothing:antialiased}
body::before{content:"";position:fixed;inset:0 0 auto;height:env(safe-area-inset-top,0px);z-index:70;background:var(--bg)}
.wrap{max-width:1120px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));padding-block:20px 80px}
.nav{position:sticky;top:env(safe-area-inset-top,0px);z-index:60;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;margin:0 0 14px;padding:8px 10px;background:var(--surface);border:1px solid var(--line);border-radius:10px}
.nav .brand{font:600 15px/1 var(--head);color:var(--ink);border:0;padding:5px 8px 5px 2px}.nav .brand::before{content:"";display:inline-block;width:10px;height:10px;border-radius:3px;background:var(--accent);margin-right:8px;vertical-align:0}
.nav .l{font:500 10.5px/1 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 4px 0 2px}
.nav a{color:var(--ink);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:5px 12px;font-size:13px;white-space:nowrap}
.nav a:hover{border-color:var(--accent);color:var(--accent)}
.nav a[aria-current="page"]{background:var(--accent);border-color:var(--accent);color:var(--surface)}
.nav .sub{flex-basis:100%;display:flex;flex-wrap:wrap;gap:4px 10px;padding-top:6px;border-top:1px solid var(--line);font-size:13px}
.nav .sub a{border:0;padding:0;color:var(--accent);border-radius:0}
.agents{margin-top:56px;border:1px dashed var(--accent);border-radius:14px;padding:18px 20px;background:var(--surface)}.agents p{margin:0 0 12px;max-width:80ch;color:var(--ink2)}.agents .kicker{margin-bottom:6px}
.btn-outline{background:transparent;color:var(--accent);border-color:var(--accent)}.btn-outline:hover{background:var(--accent);color:#FFFFFF}
.tb{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));border:1.5px solid var(--ink);background:var(--surface)}
.tb div{padding:8px 12px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);min-width:0}
.tb span{display:block;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.tb b{font:500 14px/1.4 var(--mono);overflow-wrap:anywhere}.tb a{color:var(--accent)}
h1{font:600 44px/1.08 var(--head);letter-spacing:-.01em;margin:22px 0 8px;text-wrap:balance}
h2{font:600 28px/1.15 var(--head);letter-spacing:-.01em;margin:0 0 8px;text-wrap:balance;display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 14px}
h3{font:600 21px/1.2 var(--head);margin:22px 0 6px;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
h4{margin:0 0 6px;font-size:15px}
.draft{font:600 12px var(--mono);letter-spacing:.06em;text-transform:uppercase;color:var(--log);background:var(--log-soft);border:1px solid var(--log);border-radius:999px;padding:2px 10px;vertical-align:middle}
.path{font:400 12.5px var(--mono);color:var(--muted)}
.lede{color:var(--ink2);max-width:78ch;margin:0 0 14px}
p{max-width:82ch}
.small{font-size:13px;color:var(--muted)}
code{font:13px var(--mono);background:var(--raised);border:1px solid var(--line);border-radius:4px;padding:0 4px;overflow-wrap:anywhere}
a{color:var(--accent)}a:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
section{margin:52px 0 0}
figure{margin:14px 0 0;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:14px;overflow-x:auto}
figure svg{display:block;width:100%;height:auto;min-width:680px}
figcaption{font-size:13.5px;color:var(--muted);margin-top:10px;max-width:86ch}
.d text{fill:var(--ink);font:12.5px var(--sans)}.d .m{font-family:var(--mono);font-size:12px}.d .b6{font-weight:600}
.d .lb{font-size:11px;fill:var(--muted)}.d .cap{font:600 11px var(--mono);letter-spacing:.06em;text-transform:uppercase;fill:var(--muted)}
.d .halo{paint-order:stroke;stroke:var(--surface);stroke-width:4px;stroke-linejoin:round}
.d .box{fill:var(--surface);stroke:var(--ink2);stroke-width:1.2}
.d .pri{fill:var(--accent-soft);stroke:var(--accent);stroke-width:1.6}
.d .eng{fill:var(--engine-soft);stroke:var(--engine);stroke-width:1.4}
.d .lg{fill:var(--log-soft);stroke:var(--log);stroke-width:1.4}
.d .file{fill:var(--raised);stroke:var(--ink);stroke-width:1.5}
.d .band{fill:none;stroke:var(--line);stroke-width:1.2;stroke-dasharray:5 4}
.d .ea{stroke:var(--accent);stroke-width:1.4;fill:none}.d .es{stroke:var(--muted);stroke-width:1.1;fill:none;stroke-dasharray:4 3}
.d .mkf{fill:var(--accent)}.d .mkm{fill:var(--muted)}
.d a:hover rect{stroke-width:2.4}
table.t{border-collapse:collapse;width:100%;font-size:14px;background:var(--surface);border:1px solid var(--line)}
table.t th{text-align:left;font:500 11px var(--mono);letter-spacing:.06em;text-transform:uppercase;color:var(--muted);padding:8px 10px;border-bottom:1px solid var(--line);background:var(--raised)}
table.t td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top;color:var(--ink2)}
.scroll{overflow-x:auto}
.pill{display:inline-block;font:500 11.5px var(--mono);border-radius:999px;padding:1px 9px;white-space:nowrap;border:1px solid var(--line);color:var(--ink2);background:var(--raised)}
.pill.ok{color:var(--accent);background:var(--accent-soft);border-color:transparent}
.pill.open{color:var(--log);background:var(--log-soft);border-color:transparent}
.pill.eng{color:var(--engine);background:var(--engine-soft);border-color:transparent}
.lab{font:500 10.5px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-right:6px}
details{border-top:1px solid var(--line);padding:8px 0}summary{cursor:pointer;font-weight:600}
pre{margin:8px 0 0;background:var(--raised);border:1px solid var(--line);border-radius:8px;padding:12px 14px;font:12.5px/1.55 var(--mono);color:var(--ink2);overflow:auto;white-space:pre}
@media (max-width:640px){h1{font-size:34px}}
@media (prefers-reduced-motion:reduce){*{scroll-behavior:auto}}
"""

FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap">')


def page(key, title, css, body, sub=""):
    L = links()
    site = L.get("site", "#")
    nav = (f'<nav class="nav" aria-label="%PRODUCT%"><a class="brand" href="{"#top" if key == "site" else site}"'
           '>%PRODUCT%</a>')
    for k, name in PAGES:
        href = L.get(k, "#")
        cur = ' aria-current="page"' if k == key else ""
        nav += f'<a href="{"#top" if k == key else href}"{cur}>{e(name)}</a>'
    nav += '<a href="%REPO%" target="_blank" rel="noopener">GitHub</a>'
    if sub:
        nav += f'<div class="sub">{sub}</div>'
    nav += "</nav>"
    icon = '<link rel="icon" href="favicon.svg" type="image/svg+xml">\n'
    note = " ".join("".join(_BRIEF.find("page-note").itertext()).split()).replace("%SITE%", SITE_URL).replace("%PRODUCT%", PRODUCT)
    agent = f'<link rel="alternate" type="application/xml" title="{e(note)}" href="{e(SITE_URL)}agents.xml">\n'
    said = " ".join("".join(_BRIEF.find("page-agent").itertext()).split()).replace("%SITE%", SITE_URL).replace("%PRODUCT%", PRODUCT)
    box = (f'<aside class="agents" aria-label="For coding agents"><p class="kicker">For coding agents</p><p>{e(said)}</p>'
           f'<a class="btn btn-outline" href="{e(SITE_URL)}agents.xml">The brief: agents.xml</a></aside>'
           )
    head = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    out = (f'{head}{agent}<title>{e(title)}</title>\n{icon}{FONTS}\n'
            f'<style>{CSS}{css}</style>\n<div class="wrap"><span id="top"></span>{nav}{body}{box}'
            '<p class="foot"><span>%PRODUCT% · MIT or Apache-2.0</span><a href="%REPO%">GitHub</a>'
            '<a href="%REPO%/discussions">Discussions</a>'
            f'<a href="{e(SITE_URL)}agents.xml">{e(note)}</a>'
            '<span>Generated by docs/pages/build.py from the repository: the files are the authority.</span></p></div>')
    return out.replace("%PRODUCT%", e(PRODUCT)).replace("%REPO%", e(REPO_URL)).replace("%SITE%", e(SITE_URL))
