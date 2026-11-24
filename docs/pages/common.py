"""What every page of the Schema Forge pack shares: the schema folders read as data, the SVG drawing, the look and the
shared head. Nothing about a table is typed here: every table, column, key and reference is read from its file."""
import glob, html, json, os, re

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
e = html.escape
OWNERS = [("cortex", "schema/cortex"), ("workspace", "schema/workspace")] + [
    (os.path.basename(os.path.dirname(d)), os.path.relpath(d, REPO))
    for d in sorted(glob.glob(f"{REPO}/engines/*/schema"))]
COLDEF = re.compile(r'^\s+("?[a-z_]+"?)\s+(TEXT|INTEGER|REAL|BLOB|ANY)\b(.*?)(?:--\s*(.*))?$')


def table_files(folder):
    """Every table of a schema folder: its name, what it holds, its columns, its keys and references, its text."""
    out = []
    for f in sorted(glob.glob(f"{REPO}/{folder}/*.sql")):
        if f.endswith("integrity.sql"):
            continue
        text = open(f, encoding="utf-8").read()
        lines = text.splitlines()
        name = os.path.basename(f)[:-4]
        about = re.sub(r"\s*Owner: [\w]+\.\s*$", "", lines[0].split(":", 1)[1].strip())
        notes = [l[3:].strip() for l in lines[1:] if l.startswith("-- ") and not l.startswith("-- Owner:")
                 and "CREATE" not in l]
        cols, constraints, indexes = [], [], []
        in_table = False
        for l in lines:
            if l.startswith("CREATE TABLE"):
                in_table = True
                continue
            if l.startswith(") STRICT"):
                in_table = False
                continue
            m = COLDEF.match(l) if in_table else None
            if m:
                body = m.group(3)
                ref = re.search(r"REFERENCES (\w+) \((\w+)\)(?: ON DELETE (CASCADE|SET NULL))?", body)
                chk = re.search(r"CHECK \((.*)\)\s*,?\s*$", body)
                cols.append({
                    "name": m.group(1).strip('"'), "type": m.group(2),
                    "pk": "PRIMARY KEY" in body, "not_null": "NOT NULL" in body, "unique": " UNIQUE" in body,
                    "default": (re.search(r"DEFAULT (\S+)", body) or [None, None])[1],
                    "ref": ref.group(1) if ref else None, "ref_col": ref.group(2) if ref else None,
                    "on_delete": ref.group(3) if ref and ref.group(3) else None,
                    "check": chk.group(1) if chk else None, "comment": (m.group(4) or "").strip()})
            elif in_table and l.strip().startswith(("UNIQUE", "CHECK")):
                constraints.append(l.strip().rstrip(","))
            elif l.startswith("CREATE") and "INDEX" in l:
                indexes.append(l.split("--")[0].strip())
        out.append({"name": name, "about": about, "notes": notes, "columns": cols, "constraints": constraints,
                    "indexes": indexes, "text": text, "file": os.path.relpath(f, REPO)})
    return out


def integrity(folder):
    p = f"{REPO}/{folder}/integrity.sql"
    if not os.path.exists(p):
        return []
    q = []
    for block in re.split(r"\n(?=-- name: )", open(p, encoding="utf-8").read()):
        m = re.match(r"-- name: (\S+)\n((?:-- .*\n)+)(.*)", block, re.S)
        if m:
            q.append({"name": m.group(1), "says": " ".join(l[3:] for l in m.group(2).splitlines()),
                      "sql": m.group(3).strip()})
    return q


def database():
    """Every owner's tables and integrity queries, and every reference between tables."""
    db = {o: {"folder": f, "tables": table_files(f), "integrity": integrity(f)} for o, f in OWNERS}
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

    def box(self, key, x, y, w, h, title, sub="", cls="box"):
        self.boxes[key] = (x, y, w, h)
        self.overflow = getattr(self, "overflow", [])
        if 7.4 * len(title) > w - 8 or 5.9 * len(sub) > w - 8:
            self.overflow.append(f"text of {key} overflows its box")
        self.parts.append(f'<g class="nd"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" class="{cls}"/>'
                          f'<text x="{x + w / 2}" y="{y + (h / 2 + 4 if not sub else 19)}" text-anchor="middle" class="m b6">{e(title)}</text>'
                          + (f'<text x="{x + w / 2}" y="{y + 35}" text-anchor="middle" class="lb">{e(sub)}</text>' if sub else "") + "</g>")

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
PAGES = [("home", "Start here"), ("database", "Database"), ("build-spec", "Build Spec")]


def links():
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "links.json")
    return json.load(open(p)) if os.path.exists(p) else {}


CSS = r"""
:root{
  --bg:#F2F4F3;--surface:#FFFFFF;--raised:#F8FAF9;--ink:#15202B;--ink2:#3A4652;--muted:#5C6873;--line:#D4DBD8;
  --accent:#0B6B66;--accent-soft:#DCEEEA;--engine:#6A4FA3;--engine-soft:#ECE7F6;--log:#8A5A00;--log-soft:#FBF0DA;
  --crit:#B42318;--crit-soft:#FDECEA;
  --head:"Barlow Semi Condensed","Arial Narrow",system-ui,sans-serif;--sans:"IBM Plex Sans",system-ui,-apple-system,"Segoe UI",sans-serif;
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;
  --bg:#0F1519;--surface:#151D22;--raised:#1A2329;--ink:#E1E7EB;--ink2:#C0C9D0;--muted:#93A0AA;--line:#2A353D;
  --accent:#4FB6AE;--accent-soft:#143330;--engine:#B39DEB;--engine-soft:#2A2340;--log:#E8B04A;--log-soft:#33270F;--crit:#F97066;--crit-soft:#3A1A18}}
:root[data-theme="dark"]{color-scheme:dark;
  --bg:#0F1519;--surface:#151D22;--raised:#1A2329;--ink:#E1E7EB;--ink2:#C0C9D0;--muted:#93A0AA;--line:#2A353D;
  --accent:#4FB6AE;--accent-soft:#143330;--engine:#B39DEB;--engine-soft:#2A2340;--log:#E8B04A;--log-soft:#33270F;--crit:#F97066;--crit-soft:#3A1A18}
*{box-sizing:border-box}
html{scroll-padding-top:calc(env(safe-area-inset-top,0px) + 120px)}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 var(--sans);-webkit-font-smoothing:antialiased}
body::before{content:"";position:fixed;inset:0 0 auto;height:env(safe-area-inset-top,0px);z-index:70;background:var(--bg)}
.wrap{max-width:1120px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));padding-block:20px 80px}
.nav{position:sticky;top:env(safe-area-inset-top,0px);z-index:60;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;margin:0 0 14px;padding:8px 10px;background:var(--surface);border:1px solid var(--line);border-radius:10px}
.nav .l{font:500 10.5px/1 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 4px 0 2px}
.nav a{color:var(--ink);text-decoration:none;border:1px solid var(--line);border-radius:999px;padding:5px 12px;font-size:13px;white-space:nowrap}
.nav a:hover{border-color:var(--accent);color:var(--accent)}
.nav a[aria-current="page"]{background:var(--accent);border-color:var(--accent);color:var(--surface)}
.nav .sub{flex-basis:100%;display:flex;flex-wrap:wrap;gap:4px 10px;padding-top:6px;border-top:1px solid var(--line);font-size:13px}
.nav .sub a{border:0;padding:0;color:var(--accent);border-radius:0}
.tb{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));border:1.5px solid var(--ink);background:var(--surface)}
.tb div{padding:8px 12px;border-right:1px solid var(--line);border-bottom:1px solid var(--line);min-width:0}
.tb span{display:block;font:500 10.5px/1.2 var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.tb b{font:500 14px/1.4 var(--mono);overflow-wrap:anywhere}.tb a{color:var(--accent)}
h1{font:700 44px/1.05 var(--head);margin:22px 0 8px;text-wrap:balance}
h2{font:700 28px/1.15 var(--head);margin:0 0 8px;text-wrap:balance;display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 14px}
h3{font:700 21px/1.2 var(--head);margin:22px 0 6px;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px}
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
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Semi+Condensed:wght@600;700&family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Mono:wght@400;500&display=swap">')


def page(key, title, css, body, sub=""):
    L = links()
    nav = '<nav class="nav" aria-label="The Schema Forge pack"><span class="l">Schema Forge</span>'
    for k, name in PAGES:
        href = L.get(k, "#")
        cur = ' aria-current="page"' if k == key else ' target="_blank" rel="noopener"'
        nav += f'<a href="{"#top" if k == key else href}"{cur}>{e(name)}</a>'
    nav += f'<a href="https://github.com/k8nstantin/schema-forge/pull/92" target="_blank" rel="noopener">PR #92</a>'
    if sub:
        nav += f'<div class="sub">{sub}</div>'
    nav += "</nav>"
    return (f'<title>{e(title)}</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n{FONTS}\n'
            f'<style>{CSS}{css}</style>\n<div class="wrap"><span id="top"></span>{nav}{body}'
            '<p class="small" style="margin-top:56px">Generated by docs/pages/build.py from the repository (specs/ and the schema folders), '
            'branch design-database-and-specs. The files are the authority; a change is made there and the pages built again.</p></div>')
