"""Contributing with a coding agent: the page people read, and the brief their agent reads (agents.md, llms.txt),
every list in them read from the repository, so they never fall behind it."""
import glob
import os
import xml.etree.ElementTree as ET
from common import BRANCH, PRODUCT, RAW_URL, REPO, REPO_URL, SITE_URL, e, links, page

root = ET.parse(f"{REPO}/specs/root.xml").getroot()
rules = ET.parse(f"{REPO}/specs/rules.xml").getroot()
L = links()


def flat(el):
    return " ".join("".join(el.itertext()).split()) if el is not None else ""


def raw(path):
    return f"{RAW_URL}/{path}"


def tree(path):
    return f"{REPO_URL}/tree/{BRANCH}/{path.rstrip('/')}"


identity = flat(root.find("identity/product"))
purpose = flat(root.find("identity/purpose"))
authority = [(a.get("path"), a.get("decides")) for a in root.find("authority") if a.get("path")]
sequence = [t for t in root.find("sequence") if t.tag == "task"]
open_decisions = [d for d in root.find("decisions") if d.get("status") == "open"]
rule_list = [(r.get("id"), flat(r.find("text"))) for r in rules.findall("rule")]
docs = sorted(os.path.relpath(p, REPO) for p in glob.glob(f"{REPO}/docs/*.md"))
owners = ["schema/cortex/", "schema/workspace/"] + sorted(
    os.path.relpath(p, REPO) + "/" for p in glob.glob(f"{REPO}/engines/*/schema"))
PROMPT = (f"Read {SITE_URL}agents.md and every file it lists, in its order. Then tell me, in your own words, what "
          f"{PRODUCT} is, how it is built, and which open task or issue you think fits me; don't change anything yet.")


def link_path(path):
    """A raw link for a file; a tree link for a folder, or a path with a placeholder in it."""
    if path.endswith("/") or "<" in path:
        return f"[{path}]({tree(path.split('<')[0])})"
    return f"[{path}]({raw(path)})"


# --- the brief: one set of data, written as agents.md and agents.xml ------------------------------------------------------
INTRO = (f"You were pointed here to understand {PRODUCT} or to help someone contribute to it. Read this brief whole, then "
         "the files it lists in the order given, then report back to your human before you change anything. Everything "
         f"here is read from the repository ({REPO_URL}, branch {BRANCH}); the files are the authority, this brief only orders them.")
TASK_FILE = ("Stop reading this brief. A task file (specs/tasks/*.xml) is a complete instruction: follow its start element "
             "exactly, from a new session, as the root's method says. Nothing here adds to or overrides it.")
METHOD = [
    ("design session", "a person and an agent, with the maintainer, design or change the database in the owners' folders and write the work down as a task file under specs/tasks, every decision dated in specs/root.xml"),
    ("build session", "one agent, in a new session on a checkout of main, pointed at one task file and told nothing else; it reads in the order the root gives, builds only what the file says, decides only what it lists, and stops when anything is missing or two files disagree, rather than guess"),
    ("gates", "every gate of the task file runs (local, Docker, CI), and their results go into the pull request"),
    ("review", "a person reviews and merges; the agent never merges"),
    ("lesson", "what a build taught is added to specs/lessons.xml, and a design session changes the method or the rules because of it; the method is open to improvement like the code"),
]
WAYS = [
    ("build a task already written", "they claim its issue and the maintainer assigns it; then they open a new session on a fresh checkout of main whose first and only message is the task file's path (specs/tasks/<file>.xml); that session is not this one"),
    ("bring something new", "an engine, a feature, a fix: they open an issue or a discussion; the design is agreed in a design session and written as a task file; then it is built as above"),
    ("improve the method", "a lesson, a rule that would have caught a mistake, a clearer step: proposed in Discussions, decided in a design session"),
]
READ = [  # (group, [(path, what)])
    ("the root", [("specs/root.xml", "identity and purpose, authority (which files decide), method (how every task is built), the sequence of tasks and every decision with its date")]),
    ("the rules", [("specs/rules.xml", "every rule, where it comes from, and what catches a breach")]),
    ("the files that decide", authority),
    ("the task files, in the order they are built",
     [(t.get("file") or "", f"{t.get('id')} {t.get('name')}" + (f" ({t.get('key')})" if t.get("key") else "") + f": {flat(t)}") for t in sequence]),
    ("the lessons", [("specs/lessons.xml", "what each build taught")]),
    ("the design for people, read after the authority and never instead of it", [(d, "") for d in docs]),
    ("the code as merged, when you need it", [("crates/", ""), ("engines/", ""), ("tools/", "")]),
]
DATABASE = ("Every table is a file of an owner's folder, one CREATE TABLE each, every column commented, its comments also "
            "in the database. Read a folder's files to know its tables; the owner template explains the shapes.")
HELP = [
    "Report what you understood first, in your own words, and ask your human what they want to do.",
    f"Start from an issue ({REPO_URL}/issues, good first issue for a start) or a question in Discussions ({REPO_URL}/discussions). Larger work is agreed with the maintainer before code, often as a task file.",
    "Never change specs/, an owner's folder (schema/, engines/*/schema, features/), owner.toml or postgres/manifest.toml: they change only in a design session with the maintainer.",
    "One issue, one branch, one pull request; tools/check.sh passes before you push (it needs Docker).",
    "No attribution of any kind in commits or pull requests: your human is the author, and answers for every line.",
    "Ask your human before you open an issue, push, comment or open a pull request: those speak for them.",
]


def href(path):
    if not path:
        return ""
    return tree(path.split("<")[0]) if path.endswith("/") or "<" in path else raw(path)


# agents.md
md = [f"# {PRODUCT}: the brief for coding agents", "", INTRO, "",
      f"The same brief in the method's own format: {SITE_URL}agents.xml.", "",
      "## If you were pointed at a task file", "", TASK_FILE, "",
      f"## What {PRODUCT} is", "", identity, "", purpose, "",
      "## The method you are joining", "",
      "Every part of the product is built this way, by the maintainer and by every contributor, each with their own coding agent:", ""]
md += [f"{i}. **{name}**: {text}." for i, (name, text) in enumerate(METHOD, 1)] + ["", "## How your human contributes through you", ""]
md += [f"- **{name}**: {text}." for name, text in WAYS] + ["", "## Read, in this order", ""]
for i, (group, items) in enumerate(READ, 1):
    if len(items) == 1 and items[0][1]:
        md.append(f"{i}. {link_path(items[0][0])}: {items[0][1]}.")
        continue
    md.append(f"{i}. {group[:1].upper() + group[1:]}:")
    md += [f"   - " + (f"{link_path(p)}" if p else "") + (": " if p and w else "") + w for p, w in items]
md += ["", "## The database at the core", "", DATABASE, ""] + [f"- {link_path(o)}" for o in owners] + [""]
md += ["## Still open", "", "These are decided by the maintainer in a design session, never by an agent. Do not build around them:", ""]
md += [f"- **{d.get('id')}** (before {d.get('closes-before')}): {flat(d)}" for d in open_decisions] + [""]
md += ["## The rules you work under", "", "Every rule of specs/rules.xml binds you. In short:", ""]
md += [f"- **{rid}**: {text}" for rid, text in rule_list] + ["", "## When you help someone contribute", ""]
md += [f"- {h}" for h in HELP] + [""]
AGENTS_MD = "\n".join(md)

# agents.xml
from xml.sax.saxutils import escape as x, quoteattr as qa
xl = ['<?xml version="1.0" encoding="UTF-8"?>',
      f"<!-- {PRODUCT}: the brief for coding agents, generated from the repository by docs/pages/contribute.py; the same as {SITE_URL}agents.md. -->",
      f'<brief product={qa(PRODUCT)} repository={qa(REPO_URL)} branch={qa(BRANCH)} root-version={qa(root.get("version"))} date={qa(root.get("date"))}>',
      f"  <intro>{x(INTRO)}</intro>",
      f"  <if-task-file>{x(TASK_FILE)}</if-task-file>",
      f"  <product>{x(identity)}</product>",
      f"  <purpose>{x(purpose)}</purpose>",
      "  <method>"]
xl += [f'    <step n="{i}" name={qa(n)}>{x(s)}</step>' for i, (n, s) in enumerate(METHOD, 1)]
xl += ["  </method>", "  <ways>"] + [f"    <way name={qa(n)}>{x(s)}</way>" for n, s in WAYS] + ["  </ways>", "  <read>"]
for i, (group, items) in enumerate(READ, 1):
    xl.append(f'    <group n="{i}" name={qa(group)}>')
    for p, w in items:
        attrs = (f" path={qa(p)} href={qa(href(p))}" if p else "")
        xl.append(f"      <file{attrs}>{x(w)}</file>" if w else f"      <file{attrs}/>")
    xl.append("    </group>")
xl += ["  </read>", f"  <database>{x(DATABASE)}"] + [f"    <folder path={qa(o)} href={qa(href(o))}/>" for o in owners] + ["  </database>", "  <open>"]
xl += [f"    <decision id={qa(d.get('id'))} closes-before={qa(d.get('closes-before'))}>{x(flat(d))}</decision>" for d in open_decisions]
xl += ["  </open>", "  <rules>"] + [f"    <rule id={qa(rid)}>{x(text)}</rule>" for rid, text in rule_list]
xl += ["  </rules>", "  <helping>"] + [f"    <do>{x(h)}</do>" for h in HELP] + ["  </helping>", "</brief>", ""]
AGENTS_XML = "\n".join(xl)

# --- llms.txt: the index in the format agents look for ------------------------------------------------------------------
lt = [f"# {PRODUCT}", "", f"> {identity}", "",
      f"Start with the brief for coding agents: {SITE_URL}agents.md (the same in XML: {SITE_URL}agents.xml). The files below are the authority.", "",
      "## Spec", "",
      f"- [root.xml]({raw('specs/root.xml')}): identity, authority, method, sequence, decisions",
      f"- [rules.xml]({raw('specs/rules.xml')}): the rules and their guards"]
lt += [f"- [{t.get('id')} {t.get('name')}]({raw(t.get('file'))})" for t in sequence if t.get("file")]
lt += ["", "## Authority", ""] + [f"- {link_path(p)}: {d}" for p, d in authority]
lt += ["", "## Docs", ""] + [f"- {link_path(d)}" for d in docs]
LLMS_TXT = "\n".join(lt) + "\n"

# --- the page people read -----------------------------------------------------------------------------------------------
from common import Svg
g = Svg(1040, 260, "The method every part of the product is built by: a design session writes the task, one agent builds it, gates and a person decide, and the lesson changes the method.")
loop = [("design", "design session", "person + agent: database, task file"), ("build", "build session", "one agent, one task file"),
        ("gates", "gates", "local · Docker · CI, in the PR"), ("review", "review", "a person merges; never the agent")]
for i, (k, a2, b2) in enumerate(loop):
    g.box(k, 20 + i * 258, 60, 228, 64, a2, b2, cls="pri" if k in ("design", "build") else "box")
for x, y in zip(loop, loop[1:]):
    g.arrow(x[0], y[0], "", cls="ea")
g.box("lesson", 406, 176, 228, 56, "lesson", "it changes the method", cls="lg")
g.parts.append('<path d="M890,126 C890,206 700,204 636,204" class="ea" fill="none" marker-end="url(#mka)"/>')
g.parts.append('<path d="M404,204 C200,204 134,200 134,128" class="ea" fill="none" marker-end="url(#mka)"/>')
g.containers = set()
method_svg = g.render()

ways = "".join(f'<div class="card"><p class="kicker">{k}</p><h3>{a2}</h3><p>{b2}</p></div>' for k, a2, b2 in [
    ("Build", "A task already written", "Claim its issue; once it is yours, open a new session on a fresh checkout of main and give your agent one line: the task file's path. It reads, builds, runs the gates and opens the pull request; you review it before the maintainer does."),
    ("Design", "Something new", "An engine for a database you know, a feature, a fix: open an issue or a discussion. You, your agent and the maintainer design it and write its task file; then it is built like any other."),
    ("Method", "The way we work", "A lesson from your build, a rule that would have caught a mistake, a clearer step: propose it in Discussions. The method is built in the open, like the code."),
])
body = f"""
<header class="hero">
  <p class="eyebrow">Contribute</p>
  <h1>Built with coding agents. Contributed the same way.</h1>
  <p>%PRODUCT% builds two things at once: the product, and the method it is built by, where people and coding agents develop together. Every part is designed in a session, written as a task file, built by one agent, and decided by gates and a person's review. You contribute exactly the way it is built, with your own agent, and the method is yours to improve too.</p>
  <div class="btns"><a class="btn btn-primary" href="#start">Start with your agent</a>
  <a class="btn btn-secondary" href="{e(SITE_URL)}agents.md">The brief (Markdown)</a>
  <a class="btn btn-secondary" href="{e(SITE_URL)}agents.xml">The brief (XML)</a>
  <a class="btn btn-secondary" href="%REPO%/discussions">Discussions</a></div>
</header>

<section id="method"><p class="kicker">The method</p><h2>People and agents, each doing what they do best.</h2>
<p class="lede">People decide: the design, the open questions, the review. Agents build: one task each, exactly as written, stopping rather than guessing. Everything an agent needs is in the files, so any contributor's agent builds the same thing.</p>
<figure>{method_svg}<figcaption>The task file is the contract between the people who designed the work and the agent that builds it. A lesson closes the loop: what went wrong once becomes a rule that catches it next time.</figcaption></figure></section>

<section id="start"><p class="kicker">Step one, for everyone</p><h2>Let your agent read the whole spec.</h2>
<pre class="prompt">{e(PROMPT)}</pre>
<p class="lede">Your agent reads <a href="{e(SITE_URL)}agents.md">agents.md</a> (or the same brief in the method's own format, <a href="{e(SITE_URL)}agents.xml">agents.xml</a>) and follows its links: the root, the rules, the files that decide, every task in build order. It explains the project back to you before anything changes.</p></section>

<section id="ways"><p class="kicker">Then</p><h2>Three ways in.</h2><div class="cards">{ways}</div>
<p class="lede">To build a task, the first and only message of a new session is its path, for example:</p>
<pre class="prompt">specs/tasks/SF-94.xml</pre></section>

<section id="reads"><p class="kicker">What your agent reads</p><h2>The whole spec, in the order that makes sense of it.</h2>
<p class="lede">The brief is generated from the repository on every build, so it never falls behind it.</p>
<div class="cards">
<a class="card" href="{e(RAW_URL)}/specs/root.xml"><h3>specs/root.xml</h3><p>Purpose, authority, the method, the sequence, every decision with its date.</p><span class="go">Open →</span></a>
<a class="card" href="{e(RAW_URL)}/specs/rules.xml"><h3>specs/rules.xml</h3><p>{len(rule_list)} rules, each with where it comes from and what catches a breach.</p><span class="go">Open →</span></a>
<a class="card" href="{e(REPO_URL)}/tree/{e(BRANCH)}/specs/tasks"><h3>specs/tasks/</h3><p>One file per task, one branch and one pull request each: {sum(1 for t in sequence if t.get('file'))} written, {sum(1 for t in sequence if not t.get('file'))} still to write.</p><span class="go">Open →</span></a>
</div></section>

<section id="by-hand"><div class="cta"><p class="kicker">Reading first</p><h2>The same design, for people.</h2>
<p class="lede">Every page of this site is drawn from the same files your agent reads.</p>
<div class="btns"><a class="btn btn-primary" href="{e(L.get('home', '#'))}">Start here</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="%REPO%/blob/{e(BRANCH)}/CONTRIBUTING.md">CONTRIBUTING.md</a></div></div></section>
"""
CSS = ".prompt{white-space:pre-wrap;font:14px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-wrap:anywhere}"
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("method", "The method"), ("start", "Start"), ("ways", "Three ways in"), ("reads", "What it reads"), ("by-hand", "Reading first")])
HTML = page("contribute", "Contribute", CSS, body, sub)
