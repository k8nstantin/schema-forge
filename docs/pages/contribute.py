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


# --- agents.md: the brief a coding agent reads --------------------------------------------------------------------------
md = [f"# {PRODUCT}: the brief for coding agents", "",
      f"You were pointed here to understand {PRODUCT} or to help someone contribute to it. Read this file whole, then "
      "the files below in the order given, then report back to your human before you change anything. Everything "
      f"here is read from the repository ({REPO_URL}, branch {BRANCH}); the files are the authority, this brief only orders them.", "",
      "## If you were pointed at a task file", "",
      "Stop reading this brief. A task file (specs/tasks/*.xml) is a complete instruction: follow its start element "
      "exactly, from a new session, as the root's method says. Nothing here adds to or overrides it.", "",
      f"## What {PRODUCT} is", "", identity, "",
      "## Read, in this order", "",
      f"1. {link_path('specs/root.xml')}: identity, authority (which files decide), method (how every task is built), "
      "the sequence of tasks and every decision with its date.",
      f"2. {link_path('specs/rules.xml')}: every rule, where it comes from, and what catches a breach.",
      "3. The files that decide, as the root's authority lists them:"]
for path, decides in authority:
    md.append(f"   - {link_path(path)}: {decides}")
md += [f"4. The task files, in the order they are built:"]
for t in sequence:
    f = t.get("file")
    head = f"{t.get('id')} {t.get('name')}" + (f" ({t.get('key')})" if t.get("key") else "")
    md.append(f"   - {head}: " + (f"{link_path(f)}. {flat(t)}" if f else flat(t)))
md += [f"5. {link_path('specs/lessons.xml')}: what each build taught.",
       "6. The design for people, read after the authority and never instead of it:"]
md += [f"   - {link_path(d)}" for d in docs]
md += ["7. The code as merged, when you need it: "
       f"{link_path('crates/')}, {link_path('engines/')}, {link_path('tools/')}.", "",
       "## The database at the core", "",
       "Every table is a file of an owner's folder, one CREATE TABLE each, every column commented, its comments also "
       "in the database. Read a folder's files to know its tables; the owner template explains the shapes.", ""]
md += [f"- {link_path(o)}" for o in owners] + [""]
md += ["## Still open", "",
       "These are decided by the maintainer in a design session, never by an agent. Do not build around them:", ""]
md += [f"- **{d.get('id')}** (before {d.get('closes-before')}): {flat(d)}" for d in open_decisions] + [""]
md += ["## The rules you work under", "",
       "Every rule of specs/rules.xml binds you. In short:", ""]
md += [f"- **{rid}**: {text}" for rid, text in rule_list] + [""]
md += ["## When you help someone contribute", "",
       "- Report what you understood first, in your own words, and ask your human what they want to do.",
       f"- Start from an issue ({REPO_URL}/issues, *good first issue* for a start) or a question in Discussions "
       f"({REPO_URL}/discussions). Larger work is agreed with the maintainer before code, often as a task file.",
       "- Never change specs/, an owner's folder (schema/, engines/*/schema, features/), owner.toml or "
       "postgres/manifest.toml: they change only in a design session with the maintainer.",
       "- One issue, one branch, one pull request; `tools/check.sh` passes before you push (it needs Docker).",
       "- No attribution of any kind in commits or pull requests: your human is the author, and answers for every line.",
       "- Ask your human before you open an issue, push, comment or open a pull request: those speak for them.", ""]
AGENTS_MD = "\n".join(md)

# --- llms.txt: the index in the format agents look for ------------------------------------------------------------------
lt = [f"# {PRODUCT}", "", f"> {identity}", "",
      f"Start with the brief for coding agents: {SITE_URL}agents.md. The files below are the authority.", "",
      "## Spec", "",
      f"- [root.xml]({raw('specs/root.xml')}): identity, authority, method, sequence, decisions",
      f"- [rules.xml]({raw('specs/rules.xml')}): the rules and their guards"]
lt += [f"- [{t.get('id')} {t.get('name')}]({raw(t.get('file'))})" for t in sequence if t.get("file")]
lt += ["", "## Authority", ""] + [f"- {link_path(p)}: {d}" for p, d in authority]
lt += ["", "## Docs", ""] + [f"- {link_path(d)}" for d in docs]
LLMS_TXT = "\n".join(lt) + "\n"

# --- the page people read -----------------------------------------------------------------------------------------------
steps = "".join(f'<div class="card"><p class="kicker">Step {i}</p><h3>{a}</h3><p>{b}</p></div>' for i, (a, b) in enumerate([
    ("Point your agent at the brief", f"Paste the prompt above into Claude Code, Codex, Cursor or any agent that can read the web. It reads <a href=\"{e(SITE_URL)}agents.md\">agents.md</a> and every file it lists, in order: the root, the rules, the files that decide, every task."),
    ("Let it explain the project back", "Before anything changes, your agent tells you what it understood: what %PRODUCT% is, how it is built, which decisions are still open, and what could fit you."),
    ("Pick something together", "A good first issue, a sample of real DDL that breaks a reader, an engine for a database you know, or a question in Discussions. Larger work is agreed with the maintainer first, often as a task file."),
    ("Build it the way the project does", "One issue, one branch, one pull request; tools/check.sh passes first; your name on the commits, no attribution. Your agent follows the rules the brief lists, and you answer for every line."),
], 1))
body = f"""
<header class="hero">
  <p class="eyebrow">Contribute with your coding agent</p>
  <h1>Point your agent here. It will read the whole spec.</h1>
  <p>%PRODUCT% is designed in the open and written down before it is built: the database, the rules, every task. Most people contribute through a coding agent now, so the project hands your agent one brief that lists everything it needs, in the order to read it.</p>
  <div class="btns"><a class="btn btn-primary" href="{e(SITE_URL)}agents.md">The brief for agents</a>
  <a class="btn btn-secondary" href="{e(SITE_URL)}llms.txt">llms.txt</a>
  <a class="btn btn-secondary" href="%REPO%/discussions">Ask a question</a></div>
</header>

<section id="prompt"><p class="kicker">The prompt</p><h2>Paste this into your agent.</h2>
<pre class="prompt">{e(PROMPT)}</pre>
<p class="lede">Your agent reads <code>agents.md</code>, follows its links to the raw files on GitHub, and comes back with what it understood. Nothing changes until you decide what to do.</p></section>

<section id="how"><p class="kicker">How it goes</p><h2>Four steps, you in charge of each.</h2><div class="cards two">{steps}</div></section>

<section id="reads"><p class="kicker">What your agent reads</p><h2>The whole spec, in the order that makes sense of it.</h2>
<p class="lede">The root first (who decides what, how every task is built, every decision with its date), then the rules, the files that decide, the task files in build order, and the design docs. The brief is generated from the repository on every build, so it never falls behind.</p>
<div class="cards">
<a class="card" href="{e(RAW_URL)}/specs/root.xml"><h3>specs/root.xml</h3><p>Identity, authority, method, sequence, decisions.</p><span class="go">Open →</span></a>
<a class="card" href="{e(RAW_URL)}/specs/rules.xml"><h3>specs/rules.xml</h3><p>{len(rule_list)} rules, each with where it comes from and what catches a breach.</p><span class="go">Open →</span></a>
<a class="card" href="{e(REPO_URL)}/tree/{e(BRANCH)}/specs/tasks"><h3>specs/tasks/</h3><p>One file per task, one branch and one pull request each: {sum(1 for t in sequence if t.get('file'))} written, {sum(1 for t in sequence if not t.get('file'))} still to write.</p><span class="go">Open →</span></a>
</div></section>

<section id="by-hand"><div class="cta"><p class="kicker">Without an agent</p><h2>Read it yourself, the same way.</h2>
<p class="lede">The brief is plain Markdown, and every page of this site is drawn from the same files. Start with the pages, then the root.</p>
<div class="btns"><a class="btn btn-primary" href="{e(L.get('home', '#'))}">Start here</a>
<a class="btn btn-secondary" style="color:var(--accent);border-color:var(--accent)" href="%REPO%/blob/{e(BRANCH)}/CONTRIBUTING.md">CONTRIBUTING.md</a></div></div></section>
"""
CSS = ".prompt{white-space:pre-wrap;font:14px/1.6 var(--mono);background:var(--surface);border:1.5px solid var(--accent);border-radius:12px;padding:16px 18px;color:var(--ink);overflow-wrap:anywhere}"
sub = " ".join(f'<a href="#{k}">{v}</a>' for k, v in [("prompt", "The prompt"), ("how", "How it goes"), ("reads", "What it reads"), ("by-hand", "Without an agent")])
HTML = page("contribute", "Contribute", CSS, body, sub)
