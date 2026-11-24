"""Renders specs/brief.xml, with specs/root.xml and specs/rules.xml, as the brief coding agents read (agents.md,
agents.xml, llms.txt) and the Contribute page people read. Every word of the brief is in specs/brief.xml; every name
and address is a parameter; this file only lays them out."""
import glob
import os
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as xesc, quoteattr as qa
from common import BRANCH, PRODUCT, RAW_URL, REPO, REPO_URL, SITE_URL, Svg, e, links, page

L = links()
root = ET.parse(f"{REPO}/specs/root.xml").getroot()
rules = ET.parse(f"{REPO}/specs/rules.xml").getroot()
brief = ET.parse(f"{REPO}/specs/brief.xml").getroot()


def flat(el):
    return " ".join("".join(el.itertext()).split()) if el is not None else ""


def fill(text):
    """The brief's text with its parameters filled in."""
    return (text.replace("%PRODUCT%", PRODUCT).replace("%SITE%", SITE_URL).replace("%REPO%", REPO_URL)
            .replace("%BRANCH%", BRANCH))


def said(path):
    return fill(flat(brief.find(path)))


def href(path):
    if not path:
        return ""
    if path.endswith("/") or "<" in path:
        return f"{REPO_URL}/tree/{BRANCH}/{path.split('<')[0].rstrip('/')}"
    return f"{RAW_URL}/{path}"


def link_md(path):
    return f"[{path}]({href(path)})"


# --- the brief, as data -------------------------------------------------------------------------------------------------
identity, purpose = flat(root.find("identity/product")), flat(root.find("identity/purpose"))
authority = [(a.get("path"), a.get("decides")) for a in root.find("authority") if a.get("path")]
sequence = [t for t in root.find("sequence") if t.tag == "task"]
open_decisions = [(d.get("id"), d.get("closes-before"), flat(d)) for d in root.find("decisions") if d.get("status") == "open"]
rule_list = [(r.get("id"), flat(r.find("text"))) for r in rules.findall("rule")]
authority_paths = {p for p, _ in authority}
docs = sorted(p for p in (os.path.relpath(x, REPO) for x in glob.glob(f"{REPO}/docs/*.md")) if p not in authority_paths)
owners = ["schema/cortex/", "schema/workspace/"] + sorted(
    os.path.relpath(p, REPO) + "/" for p in glob.glob(f"{REPO}/engines/*/schema"))
method = [(s.get("name"), s.get("short"), fill(flat(s))) for s in brief.find("method").findall("step")]
ways = [(w.get("name"), w.get("kicker"), w.get("title"), fill(flat(w.find("for-agent"))), fill(flat(w.find("for-people"))))
        for w in brief.find("ways").findall("way")]
helping = [fill(flat(d)) for d in brief.find("helping").findall("do")]
architecture = [(p.get("name"), p.get("href") or "",
                 fill(flat(root.find("identity/repository")) if p.get("source") == "repository" else flat(p)))
                for p in brief.find("architecture").findall("part")]
start_steps = [fill(flat(s)) for s in brief.find("start").findall("step")]
PROMPT = said("prompt")

# what is wanted now: from the sequence (built, file, depends) and the open decisions
built = {t.get("id") for t in sequence if t.get("built")}
ready = [t for t in sequence if t.get("file") and not t.get("built") and all(d in built for d in (t.get("depends") or "").split())]
queued = [t for t in sequence if t.get("file") and not t.get("built") and t not in ready]
ahead = [t for t in sequence if not t.get("file")]


def issue(t):
    return f"{REPO_URL}/issues/{t.get('key')[3:]}" if t.get("key") else ""


def task_line(t):
    return f"{t.get('id')} {t.get('name')}" + (f" ({t.get('key')})" if t.get("key") else "")


def group_files(g):
    """A reading group's files, each (path, what): from its path, its paths, or its source."""
    if g.get("path"):
        return [(g.get("path"), fill(flat(g)))]
    if g.get("paths"):
        return [(p, "") for p in g.get("paths").split()]
    source = g.get("source")
    if source == "authority":
        return authority
    if source == "sequence":
        return [(t.get("file") or "", f"{t.get('id')} {t.get('name')}" + (f" ({t.get('key')})" if t.get("key") else "")
                 + f": {flat(t)}") for t in sequence]
    if source == "docs":
        return [(d, "") for d in docs]
    raise SystemExit(f"specs/brief.xml: group {g.get('name')} has no files")


read = [(g.get("name"), group_files(g)) for g in brief.find("read").findall("group")]

# --- agents.md, and the same for the repository's agent files ----------------------------------------------------------
def render_md(link_md, head):
    """The brief in Markdown: head first, then every section, each file linked by link_md."""
    md = head + [said("welcome"), "", said("intro"), "",
                 "## If you were pointed at a task file", "", said("if-task-file"), "",
                 "## The mission", "", identity, "", purpose, "",
                 "## The architecture", "", said("architecture/note"), ""]
    md += [f"- **{n}**" + (f" ({link_md(h)})" if h else "") + f": {x}" for n, h, x in architecture]
    md += ["", "## Wanted now", "", said("wanted/note"), "", f"**Ready to build**: {said('wanted/ready')}", ""]
    md += [f"- {task_line(t)}: {link_md(t.get('file'))}" + (f", issue {issue(t)}" if issue(t) else "") + f". {flat(t)}" for t in ready] or ["- none just now"]
    md += ["", f"**Queued**: {said('wanted/queued')}", ""]
    md += [f"- {task_line(t)}: {link_md(t.get('file'))}" + (f", issue {issue(t)}" if issue(t) else "") for t in queued]
    md += ["", f"**Ahead**: {said('wanted/ahead')}", ""] + [f"- {task_line(t)}: {flat(t)}" for t in ahead]
    md += ["", f"**Needs a design session**: {said('wanted/design')}", ""] + [f"- **{i}** (before {c})" for i, c, _ in open_decisions]
    md += ["", f"**Issues**: {said('wanted/issues')}", "", "## How to start", ""]
    md += [f"{i}. {s}" for i, s in enumerate(start_steps, 1)]
    md += ["", "## The method you are joining", "", said("method/note"), ""]
    md += [f"{i}. **{n}**: {t}" for i, (n, _, t) in enumerate(method, 1)] + ["", "## How your human contributes through you", ""]
    md += [f"- **{n}**: {a}" for n, _, _, a, _ in ways] + ["", "## Read, in this order", ""]
    for i, (group, files) in enumerate(read, 1):
        if len(files) == 1 and files[0][1]:
            md.append(f"{i}. {link_md(files[0][0])}: {files[0][1]}.")
            continue
        md.append(f"{i}. {group[:1].upper() + group[1:]}:")
        md += ["   - " + (link_md(p) if p else "") + (": " if p and w else "") + w for p, w in files]
    md += ["", "## The database at the core", "", said("database"), ""] + [f"- {link_md(o)}" for o in owners]
    md += ["", "## Still open", "", "These are decided by the maintainer in a design session, never by an agent. Do not build around them:", ""]
    md += [f"- **{i}** (before {c}): {t}" for i, c, t in open_decisions]
    md += ["", "## The rules you work under", "", "Every rule of specs/rules.xml binds you. In short:", ""]
    md += [f"- **{i}**: {t}" for i, t in rule_list] + ["", "## When you help someone contribute", ""]
    md += [f"- {h}" for h in helping] + [""]
    return "\n".join(md)


AGENTS_MD = render_md(link_md, [f"# {PRODUCT}: the brief for coding agents", "",
                                    f"The same brief in the method's own format: {SITE_URL}agents.xml.", ""])
REPO_AGENTS_MD = render_md(lambda p: f"[{p}]({p.split('<')[0]})", [
    f"# {PRODUCT}: for the coding agent opened in this repository", "",
    "<!-- Rendered from specs/brief.xml, specs/root.xml and specs/rules.xml by docs/pages/build.py: edit those, never this. -->", "",
    f"You are in the {PRODUCT} repository. If the first message of this session is a task file's path, follow that file and nothing here. "
    f"Otherwise this is the same brief as {SITE_URL}agents.md, with the files linked where they are in this checkout.", ""])
CLAUDE_MD = (f"<!-- Rendered by docs/pages/build.py from specs/brief.xml: edit that, never this. -->\n"
             f"Read @AGENTS.md: the brief for the coding agent opened in the {PRODUCT} repository.\n")

# --- agents.xml ---------------------------------------------------------------------------------------------------------
xl = ['<?xml version="1.0" encoding="UTF-8"?>',
      f"<!-- {PRODUCT}: the brief for coding agents, rendered from specs/brief.xml, specs/root.xml and specs/rules.xml; "
      f"the same as {SITE_URL}agents.md. -->",
      f"<brief product={qa(PRODUCT)} repository={qa(REPO_URL)} branch={qa(BRANCH)} brief-version={qa(brief.get('version'))} "
      f"root-version={qa(root.get('version'))} date={qa(brief.get('date'))}>",
      f"  <welcome>{xesc(said('welcome'))}</welcome>",
      f"  <intro>{xesc(said('intro'))}</intro>", f"  <if-task-file>{xesc(said('if-task-file'))}</if-task-file>",
      f"  <mission>\n    <product>{xesc(identity)}</product>\n    <purpose>{xesc(purpose)}</purpose>\n  </mission>",
      f"  <architecture>\n    <note>{xesc(said('architecture/note'))}</note>"]
xl += [f"    <part name={qa(n)}" + (f" href={qa(href(h))}" if h else "") + f">{xesc(x)}</part>" for n, h, x in architecture]
xl += ["  </architecture>",
      f"  <wanted>\n    <note>{xesc(said('wanted/note'))}</note>",
      f"    <ready about={qa(said('wanted/ready'))}>"]
xl += [f"      <task id={qa(t.get('id'))} name={qa(t.get('name'))} href={qa(href(t.get('file')))}" + (f" issue={qa(issue(t))}" if issue(t) else "") + f">{xesc(flat(t))}</task>" for t in ready]
xl += ["    </ready>", f"    <queued about={qa(said('wanted/queued'))}>"]
xl += [f"      <task id={qa(t.get('id'))} name={qa(t.get('name'))} href={qa(href(t.get('file')))}/>" for t in queued]
xl += ["    </queued>", f"    <design about={qa(said('wanted/design'))}>"]
xl += [f"      <decision id={qa(i)} closes-before={qa(c)}/>" for i, c, _ in open_decisions]
xl += ["    </design>", f"    <ahead about={qa(said('wanted/ahead'))}>"]
xl += [f"      <task id={qa(t.get('id'))} name={qa(t.get('name'))}>{xesc(flat(t))}</task>" for t in ahead]
xl += ["    </ahead>", f"    <issues href={qa(REPO_URL + '/issues')}>{xesc(said('wanted/issues'))}</issues>", "  </wanted>", "  <start>"]
xl += [f'    <step n="{i}">{xesc(s)}</step>' for i, s in enumerate(start_steps, 1)]
xl += ["  </start>", f"  <method>\n    <note>{xesc(said('method/note'))}</note>"]
xl += [f'    <step n="{i}" name={qa(n)}>{xesc(t)}</step>' for i, (n, _, t) in enumerate(method, 1)]
xl += ["  </method>", "  <ways>"] + [f"    <way name={qa(n)}>{xesc(a)}</way>" for n, _, _, a, _ in ways] + ["  </ways>", "  <read>"]
for i, (group, files) in enumerate(read, 1):
    xl.append(f'    <group n="{i}" name={qa(group)}>')
    for p, w in files:
        attrs = f" path={qa(p)} href={qa(href(p))}" if p else ""
        xl.append(f"      <file{attrs}>{xesc(w)}</file>" if w else f"      <file{attrs}/>")
    xl.append("    </group>")
xl += ["  </read>", f"  <database>{xesc(said('database'))}"]
xl += [f"    <folder path={qa(o)} href={qa(href(o))}/>" for o in owners] + ["  </database>", "  <open>"]
xl += [f"    <decision id={qa(i)} closes-before={qa(c)}>{xesc(t)}</decision>" for i, c, t in open_decisions]
xl += ["  </open>", "  <rules>"] + [f"    <rule id={qa(i)}>{xesc(t)}</rule>" for i, t in rule_list]
xl += ["  </rules>", "  <helping>"] + [f"    <do>{xesc(h)}</do>" for h in helping] + ["  </helping>", "</brief>", ""]
AGENTS_XML = "\n".join(xl)

# --- llms.txt -----------------------------------------------------------------------------------------------------------
lt = [f"# {PRODUCT}", "", f"> {identity}", "",
      f"Start with the brief for coding agents: {SITE_URL}agents.md (the same in XML: {SITE_URL}agents.xml). "
      "The files below are the authority.", "", "## Spec", ""]
lt += [f"- [{p}]({href(p)}): {w}" for group, files in read[:2] for p, w in files]
lt += [f"- [{t.get('id')} {t.get('name')}]({href(t.get('file'))})" for t in sequence if t.get("file")]
lt += ["", "## Authority", ""] + [f"- {link_md(p)}: {d}" for p, d in authority]
lt += ["", "## Docs", ""] + [f"- {link_md(d)}" for d in docs]
LLMS_TXT = "\n".join(lt) + "\n"

# --- the Contribute page ------------------------------------------------------------------------------------------------
g = Svg(1040, 260, "The method every part of the product is built by: a design session writes the task, one agent builds it, gates and a person decide, and the lesson changes the method.")
loop, lesson = method[:-1], method[-1]
for i, (n, short, _) in enumerate(loop):
    g.box(n, 20 + i * 258, 60, 228, 64, n, short, cls="pri" if i < 2 else "box")
for a, b in zip(loop, loop[1:]):
    g.arrow(a[0], b[0], "", cls="ea")
g.box(lesson[0], 406, 176, 228, 56, lesson[0], lesson[1], cls="lg")
g.parts.append('<path d="M890,126 C890,206 700,204 636,204" class="ea" fill="none" marker-end="url(#mka)"/>')
g.parts.append('<path d="M404,204 C200,204 134,200 134,128" class="ea" fill="none" marker-end="url(#mka)"/>')
g.containers = set()
method_svg = g.render()

way_cards = "".join(f'<div class="card"><p class="kicker">{e(k)}</p><h3>{e(t)}</h3><p>{e(p)}</p></div>' for _, k, t, _, p in ways)
build_example = next((t.get("file") for t in sequence if t.get("file") and t.get("key")), "specs/tasks/<file>.xml")
body = f"""
<header class="hero">
  <p class="eyebrow">Contribute</p>
  <h1>Built with coding agents. Contributed the same way.</h1>
  <p>{e(purpose)}</p>
  <div class="btns"><a class="btn btn-primary" href="#start">Start with your agent</a>
  <a class="btn btn-secondary" href="{e(SITE_URL)}agents.md">The brief (Markdown)</a>
  <a class="btn btn-secondary" href="{e(SITE_URL)}agents.xml">The brief (XML)</a>
  <a class="btn btn-secondary" href="%REPO%/discussions">Discussions</a></div>
</header>

<section id="method"><p class="kicker">The method</p><h2>People and agents, each doing what they do best.</h2>
<p class="lede">{e(said('method/note'))}</p>
<figure>{method_svg}<figcaption>{' '.join(f'<b>{e(n)}</b>: {e(t)}' for n, _, t in method)}</figcaption></figure></section>

<section id="wanted"><p class="kicker">Wanted now</p><h2>What the project needs today.</h2>
<p class="lede">{e(said('wanted/note'))} Everyone may submit a build of a ready task; the maintainer reviews them side by side and merges the best.</p>
<div class="cards">{''.join(f'<a class="card" href="{e(href(t.get("file")))}"><p class="kicker">Ready to build</p><h3>{e(task_line(t))}</h3><p>{e(flat(t))}</p><span class="go">The task file →</span></a>' for t in ready)}
{''.join(f'<a class="card" href="{e(href(t.get("file")))}"><p class="kicker">Queued</p><h3>{e(task_line(t))}</h3><p>{e(flat(t)[:180])}…</p><span class="go">Read ahead →</span></a>' for t in queued)}
</div>
<p class="lede" style="margin-top:14px"><b>Needs a design session:</b> {', '.join(f'<code>{e(i)}</code>' for i, _, _ in open_decisions)}. Bring your view to <a href="%REPO%/discussions">Discussions</a>.</p></section>

<section id="start"><p class="kicker">Step one, for everyone</p><h2>Let your agent read the whole spec.</h2>
<pre class="prompt">{e(PROMPT)}</pre>
<p class="lede">Your agent reads <a href="{e(SITE_URL)}agents.md">agents.md</a> (or the same brief in the method's own format, <a href="{e(SITE_URL)}agents.xml">agents.xml</a>) and follows its links, then explains the project back to you before anything changes.</p></section>

<section id="ways"><p class="kicker">Then</p><h2>Three ways in.</h2><div class="cards">{way_cards}</div>
<p class="lede">To build a task, the first and only message of a new session is its path, for example:</p>
<pre class="prompt">{e(build_example)}</pre></section>

<section id="reads"><p class="kicker">What your agent reads</p><h2>The whole spec, in the order that makes sense of it.</h2>
<p class="lede">The brief is one file, <a href="%REPO%/blob/{e(BRANCH)}/specs/brief.xml">specs/brief.xml</a>, rendered with the root and the rules on every build, so it never falls behind them.</p>
<div class="cards">{''.join(f'<a class="card" href="{e(href(p))}"><h3>{e(p)}</h3><p>{e(w)}</p><span class="go">Open →</span></a>' for group, files in read[:2] for p, w in files)}
<a class="card" href="{e(href('specs/tasks/'))}"><h3>specs/tasks/</h3><p>One file per task, one branch and one pull request each: {sum(1 for t in sequence if t.get('file'))} written, {sum(1 for t in sequence if not t.get('file'))} still to write.</p><span class="go">Open →</span></a>
</div></section>

<section id="by-hand"><div class="cta"><p class="kicker">Reading first</p><h2>The same design, for people.</h2>
<p class="lede">Every page of this site is drawn from the same files your agent reads.</p>
<div class="btns"><a class="btn btn-primary" href="{e(L.get('home', '#'))}">Start here</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="%REPO%/blob/{e(BRANCH)}/CONTRIBUTING.md">CONTRIBUTING.md</a></div></div></section>
"""
CSS = ".prompt{white-space:pre-wrap;font:14px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-wrap:anywhere}"
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("wanted", "Wanted now"), ("method", "The method"), ("start", "Start"), ("ways", "Three ways in"), ("reads", "What it reads"), ("by-hand", "Reading first")])
HTML = page("contribute", "Contribute", CSS, body, sub)
