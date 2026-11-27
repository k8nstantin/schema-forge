"""The Build Spec page: the root, the rules, every task file, the decisions and the review, rendered from specs/."""
import csv, re, xml.etree.ElementTree as ET
from collections import Counter
from common import REPO, Svg, e, page

def txt(el): return " ".join("".join(el.itertext()).split()) if el is not None else ""
def ticks(s): return re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", e(s))
root = ET.parse(f"{REPO}/specs/root.xml").getroot()
rules = ET.parse(f"{REPO}/specs/rules.xml").getroot()
lessons = ET.parse(f"{REPO}/specs/lessons.xml").getroot()
seq = root.find("sequence").findall("task")
tasks = {t.get("id"): ET.parse(f"{REPO}/{t.get('file')}").getroot() for t in seq if t.get("file")}
LEDGER = "specs/reviews/2026-11-24-draft-1.tsv"
ledger = list(csv.DictReader(open(f"{REPO}/{LEDGER}"), delimiter="\t"))
runs = Counter(r["run"] for r in ledger)

# --- what an agent reads, in order -------------------------------------------------------------------------------
g = Svg(1040, 170, "A build reads the merged code, then the root, the rules and its task file, then the files the task names, and nothing else.")
steps = [("code", "the merged code", ".rs and Cargo.toml"), ("root", "specs/root.xml", "the truth, the method"),
         ("rules", "specs/rules.xml", "every rule and its guard"), ("task", "its task file", "specs/tasks/SF-<n>.xml"),
         ("named", "what it names", "schema folders, code")]
for i, (k, t, s) in enumerate(steps):
    g.box(k, 20 + i * 206, 50, 180, 50, t, s, cls="pri" if k == "task" else "box")
for a, b in zip(steps, steps[1:]):
    g.arrow(a[0], b[0])
g.text(20, 30, "kickoff: an agent pointed at the task file, in any session, building from the files alone", "lb m")
g.text(20, 140, "nothing else is read: no earlier branch, no conversation, no page; what the files do not say is a stop, not a guess", "lb")
read_svg = g.render()

# --- the sequence and what each waits for -----------------------------------------------------------------------------
g = Svg(1040, 150, "The objectives in their order, each waiting for the one before it to be merged.")
for i, t in enumerate(seq):
    written = t.get("state") == "done"
    g.box(t.get("id"), 12 + i * 114, 50, 104, 58, t.get("key") or t.get("id"), t.get("name").replace("engine_", ""), cls="pri" if written else "band")
for t in seq:
    if t.get("depends"): g.arrow(t.get("depends"), t.get("id"))
g.text(16, 30, "solid: done (its issue closed, its pull requests merged) · dashed: still to come; each merged before the next starts", "lb")
seq_svg = g.render()

P = []; a = P.append
a(f'''<div class="tb" role="group" aria-label="Title block">
<div><span>Spec</span><b>root v{root.get("version")} · rules v{rules.get("version")}</b></div><div><span>Objectives</span><b><a href="%REPO%/issues/138" target="_blank" rel="noopener">#138 to #146</a></b></div>
<div><span>Tasks written</span><b>{len(tasks)} of {len(seq)}</b></div><div><span>Review</span><b>{len(ledger)} defects found and fixed</b></div><div><span>Date</span><b>{root.get("date")}</b></div></div>
<h1>%PRODUCT% Build Spec <span class="draft">The rebuild</span></h1>
<p class="lede">What a coding agent builds each branch and pull request from: the root says where the truth is and how the work is done,
the rules bind every task, and each task file says exactly what one build makes, how it is tested and what it may touch. Everything
below is read from <code>specs/</code>.</p>''')
a(f'<section id="read"><h2>How a build reads</h2><figure>{read_svg}<figcaption>The order is required; a session that reads out of order reads again from the start before it writes anything. {ticks(txt(root.find("method").find("silence")))}</figcaption></figure></section>')
a(f'<section id="sequence"><h2>The sequence</h2><figure>{seq_svg}<figcaption>One branch and one pull request each, keyed by its GitHub issue once it has one.</figcaption></figure><div class="seq">')
for t in seq:
    f = t.get("file"); key = t.get("key")
    a(f'<a class="card{"" if f else " todo"}" href="#{t.get("id") if f else "decisions"}"><span class="tid">{t.get("id")}</span><span class="tname">{e(t.get("name"))}</span>'
      f'<span class="tkey">{e(key or "not written yet")}</span><span class="small">{ticks(txt(t))[:160]}</span></a>')
a('</div></section>')
idn, auth, meth, dec = root.find("identity"), root.find("authority"), root.find("method"), root.find("decisions")
a(f'<section id="root"><h2>The root <span class="path">specs/root.xml · version {root.get("version")}</span></h2><p class="lede">{e(txt(idn.find("product")))}</p>')
a('<h3>The files that decide</h3><div class="scroll"><table class="t"><thead><tr><th>File</th><th>Decides</th></tr></thead><tbody>')
for el in auth:
    if el.get("path"): a(f'<tr><td><code>{e(el.get("path"))}</code></td><td>{e(el.get("decides") or txt(el))}</td></tr>')
a(f'</tbody></table></div><p class="small"><b>Not sources:</b> {e(txt(auth.find("not_sources")))}</p><h3>The method</h3><dl class="method">')
for el in meth:
    if el.tag != "note": a(f'<dt>{e(el.tag)}</dt><dd>{ticks(txt(el))}</dd>')
a('</dl></section>')
a('<section id="decisions"><h2>Decisions</h2><div class="scroll"><table class="t"><thead><tr><th>Decision</th><th>Status</th><th>What</th></tr></thead><tbody>')
for d in dec.findall("decision"):
    st = d.get("status")
    pill = f'<span class="pill {"ok" if st in ("confirmed", "replaced") else "open"}">{st}{" · " + d.get("date") if st in ("confirmed", "replaced") else " · before " + (d.get("closes-before") or "")}</span>'
    a(f'<tr><td><code>{e(d.get("id"))}</code></td><td>{pill}</td><td>{ticks(txt(d))}</td></tr>')
a('</tbody></table></div></section>')
a(f'<section id="rules"><h2>The rules <span class="path">specs/rules.xml</span></h2><p class="lede">Each binds every task; its breach names the guard that catches a break.</p><div class="rules">')
for r in rules.findall("rule"):
    a(f'<article class="rule"><h4><code>{e(r.get("id"))}</code></h4><p>{ticks(txt(r.find("text")))}</p><p class="breach"><span class="lab">Caught by</span>{ticks(txt(r.find("breach")))}</p><p class="small"><span class="lab">From</span>{e(txt(r.find("from")))}</p></article>')
a('</div></section><section id="tasks"><h2>Task files</h2><p class="lede">What a coding agent is pointed at, one per build.</p>')
for t in seq:
    if not t.get("file"): continue
    x = tasks[t.get("id")]; key = x.get("key")
    issue = (f'<a class="issue" href="%REPO%/issues/{key[3:]}" target="_blank" rel="noopener">issue #{key[3:]}</a>' if key
             else '<span class="issue">no issue yet</span>')
    a(f'<article class="task" id="{t.get("id")}"><header><span class="tid">{t.get("id")}</span><h3>{e(x.get("name"))}</h3><span class="tkey">{e(key or t.get("id"))} · v{x.get("version")}</span>'
      f'{issue}<span class="path">{e(t.get("file"))}</span></header>'
      f'<p class="lede">{ticks(txt(x.find("piece")))}</p><div class="ba"><div><span class="lab">Before</span><p>{ticks(txt(x.find("before")))}</p></div><div><span class="lab">After</span><p>{ticks(txt(x.find("after")))}</p></div></div>'
      '<details open><summary>Steps</summary><ol class="steps">')
    for s in x.iter("step"):
        a(f'<li><span class="sn">{s.get("n")}</span><div><b>{e(s.get("name"))}</b><p>{ticks(txt(s))}</p></div></li>')
    tests = x.find("build").find("tests")
    a(f'</ol></details><details><summary>Tests: {len(tests.findall("prove"))} items, one test each</summary><p class="small">{ticks(txt(tests.find("how")))}</p><ul class="proves">')
    for p in tests.findall("prove"): a(f'<li><span class="sn">step {e(p.get("step"))}</span> {ticks(p.text or "")}</li>')
    a('</ul></details><details><summary>Gates</summary><div class="scroll"><table class="t"><thead><tr><th>Gate</th><th>Command</th><th>Passes when</th></tr></thead><tbody>')
    for gt in x.find("gates").findall("gate"):
        a(f'<tr><td><b>{e(gt.get("id"))}</b><br><span class="small">{e(gt.get("kind"))} · {e(gt.get("proves"))}</span></td><td>{"<br>".join("<code>" + e(c.text or "") + "</code>" for c in gt.findall("cmd"))}</td><td>{ticks(txt(gt.find("expect")))}</td></tr>')
    a(f'</tbody></table></div></details><details><summary>What it may touch, and what it decides</summary><p><span class="lab">Owns</span>{ticks(txt(x.find("owns")))}</p><p><span class="lab">Forbids</span>{ticks(txt(x.find("forbid")))}</p><p><span class="lab">The agent decides only</span>{ticks(txt(x.find("agent-decides")))}</p></details>'
      f'<p class="done"><span class="lab">Done</span>{ticks(txt(x.find("done")))}</p></article>')
a('</section>')
runtiles = "".join(f'<div><b>{runs.get(str(i), 0)}</b><span>run {i}{" · everything" if i == 1 else " · from the run before"}</span></div>' for i in (1, 2, 3)) + '<div><b>0</b><span>run 4 · clean</span></div>'
a(f'<section id="review"><h2>The review <span class="path">{LEDGER}</span></h2><p class="lede">Every defect, recorded with its evidence and fix as it was found, then fixed; each run read what the one before changed. The fourth pass was clean.</p>'
  f'<div class="runs">{runtiles}</div><div class="scroll"><table class="t ledger"><thead><tr><th>#</th><th>Run</th><th>Class</th><th>Where</th><th>Defect</th><th>Fix</th></tr></thead><tbody>')
for r in ledger:
    a(f'<tr><td>{r["n"]}</td><td>{r["run"]}</td><td><span class="pill">{e(r["class"])}</span></td><td class="small"><code>{e(r["where"])}</code></td><td>{ticks(r["what"])}</td><td class="small">{ticks(r["fix"])}</td></tr>')
a('</tbody></table></div></section><section id="lessons"><h2>Lessons</h2><div class="rules">')
for l in lessons.findall("lesson"):
    a(f'<article class="rule"><h4><code>{e(l.get("id"))}</code> <span class="small">{e(l.get("date"))}</span></h4><p>{e(txt(l.find("found")))}</p><p class="breach"><span class="lab">The spec now</span>{e(txt(l.find("does")))}</p></article>')
a('</div></section>')
CSS = """
.seq{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:10px;margin-top:14px}
.card{display:flex;flex-direction:column;gap:2px;padding:12px 14px;background:var(--surface);border:1.5px solid var(--line);border-radius:10px;text-decoration:none;color:var(--ink);min-width:0}
.card:hover{border-color:var(--accent)}.card.todo{border-style:dashed;background:transparent;color:var(--muted)}
.tid{font:500 11px var(--mono);color:var(--muted);letter-spacing:.06em;text-transform:uppercase}
.tname{font:700 19px/1.2 var(--head)}.tkey{font:500 12.5px var(--mono);color:var(--accent)}.issue{font:500 12.5px var(--mono)}
dl.method{display:grid;grid-template-columns:120px 1fr;gap:8px 16px;margin:0;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:14px}
dl.method dt{font:500 12px var(--mono);text-transform:uppercase;letter-spacing:.06em;color:var(--accent);padding-top:2px}
dl.method dd{margin:0;color:var(--ink2);min-width:0}
@media (max-width:640px){dl.method{grid-template-columns:1fr}}
.rules{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}
.rule{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:14px 16px;min-width:0}.rule p{margin:6px 0;color:var(--ink2)}
.breach{font-size:13.5px}
.task{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:14px 0;min-width:0}
.task header{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 14px;margin-bottom:8px}.task header h3{margin:0}
.ba{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:6px 0 10px}.ba p{margin:2px 0;color:var(--ink2);font-size:14px}
@media (max-width:700px){.ba{grid-template-columns:1fr}}
ol.steps{list-style:none;margin:8px 0 0;padding:0;display:grid;gap:10px}ol.steps li{display:grid;grid-template-columns:34px 1fr;gap:10px}
ol.steps p{margin:2px 0;color:var(--ink2);font-size:14px}.sn{font:500 12px var(--mono);color:var(--accent)}
ol.steps .sn{display:grid;place-items:center;width:28px;height:28px;border:1.5px solid var(--accent);border-radius:50%}
ul.proves{margin:8px 0 0;padding-left:18px;color:var(--ink2);font-size:14px}ul.proves li{margin:4px 0}
.done{margin:10px 0 0;font-size:14px;color:var(--ink2)}
.runs{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:0 0 14px}
.runs div{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px 14px}
.runs b{display:block;font:700 32px/1 var(--head);font-variant-numeric:tabular-nums}.runs span{font-size:12.5px;color:var(--muted)}
@media (max-width:560px){.runs{grid-template-columns:repeat(2,1fr)}}
table.ledger td{font-size:13px}
"""
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("read", "How a build reads"), ("sequence", "Sequence"), ("root", "Root"), ("decisions", "Decisions"), ("rules", "Rules"), ("tasks", "Tasks"), ("review", "Review"), ("lessons", "Lessons")])
HTML = page("build-spec", "%PRODUCT% Build Spec", CSS, "\n".join(P), sub)
