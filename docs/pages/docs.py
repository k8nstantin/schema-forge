"""Renders every doc of the design (docs/*.xml, docs/owner-template/README.xml, engines/*/README.xml) as a page of the
site, doc-<id>.html. The XML is the one source: agents read it as it is, people read these pages; nothing is written
twice (decision xml-for-agents). This file only lays them out."""
import glob
import os
import re
import xml.etree.ElementTree as ET
from common import BRANCH, REPO, REPO_URL, SITE_URL, e, page


def sources():
    """Every doc, as (path from the repository's root, its root element), in path order."""
    paths = sorted(glob.glob(f"{REPO}/docs/*.xml")) + [f"{REPO}/docs/owner-template/README.xml"] + sorted(
        glob.glob(f"{REPO}/engines/*/README.xml"))
    return [(os.path.relpath(p, REPO), ET.parse(p).getroot()) for p in paths if os.path.exists(p)]


DOCS = sources()
BY_PATH = {path: el.get("id") for path, el in DOCS}


def doc_file(doc_id):
    return f"doc-{doc_id}.html"


def doc_href(doc_id):
    """A doc's page: relative on the site, the site's address from a published preview."""
    import common
    return doc_file(doc_id) if common.MODE == "site" else f"{SITE_URL}{doc_file(doc_id)}"


def slug(title):
    """A section's anchor, as GitHub made it from the heading: lowercase, spaces as dashes, punctuation dropped."""
    return re.sub(r"[^a-z0-9 _-]", "", title.lower()).replace(" ", "-")


def link(href, here):
    """A doc's link as the page links it: another doc to its page, a file of the repository to GitHub."""
    if re.match(r"^[a-z]+:", href) or href.startswith("#"):
        return href
    target, _, anchor = href.partition("#")
    path = os.path.normpath(os.path.join(os.path.dirname(here), target)).replace(os.sep, "/")
    if path in BY_PATH:
        return doc_href(BY_PATH[path]) + (f"#{anchor}" if anchor else "")
    kind = "tree" if os.path.isdir(os.path.join(REPO, path)) else "blob"
    return f"{REPO_URL}/{kind}/{BRANCH}/{path}" + (f"#{anchor}" if anchor else "")


def inline(el, here):
    """An element's text and inline children (c, a, b, i) as HTML."""
    out = [e(el.text or "")]
    for ch in el:
        inner = inline(ch, here)
        if ch.tag == "c":
            out.append(f"<code>{inner}</code>")
        elif ch.tag == "a":
            out.append(f'<a href="{e(link(ch.get("href"), here))}">{inner}</a>')
        elif ch.tag == "b":
            out.append(f"<strong>{inner}</strong>")
        elif ch.tag == "i":
            out.append(f"<em>{inner}</em>")
        else:
            raise SystemExit(f"{here}: <{ch.tag}> is not an inline element of a doc")
        out.append(e(ch.tail or ""))
    return "".join(out)


def block(el, here):
    """A block of a doc (p, list, steps, table, code, note, section, part) as HTML."""
    t = el.tag
    if t == "p":
        return f"<p>{inline(el, here)}</p>"
    if t in ("list", "steps"):
        tag = "ol" if t == "steps" else "ul"
        return f"<{tag}>" + "".join(f"<li>{inline(i, here)}</li>" for i in el) + f"</{tag}>"
    if t == "table":
        rows = []
        for r in el:
            cell = "th" if r.tag == "head" else "td"
            rows.append("<tr>" + "".join(f"<{cell}>{inline(c, here)}</{cell}>" for c in r) + "</tr>")
        return f'<div class="scroll"><table class="t">{"".join(rows)}</table></div>'
    if t == "code":
        return f"<pre>{e(el.text or '')}</pre>"
    if t == "note":
        return f'<p class="note">{inline(el, here)}</p>'
    if t in ("section", "part"):
        h = "h2" if t == "section" else "h3"
        title = el.get("title")
        return f'<{h} id="{e(slug(title))}">{e(title)}</{h}>' + "".join(block(c, here) for c in el)
    raise SystemExit(f"{here}: <{t}> is not a block of a doc")


CSS = """.doc{max-width:860px}.doc h2{margin-top:36px}.doc h3{margin-top:24px}.doc ul,.doc ol{padding-left:22px}
.doc li{margin:6px 0}.doc pre{overflow-x:auto}.doc .src{margin:4px 0 22px}"""


def render(path, el):
    here = path
    body = "".join(block(c, here) for c in el)
    src = f'{REPO_URL}/blob/{BRANCH}/{path}'
    head = (f'<header class="doc"><h1>{e(el.get("title"))}</h1><p class="small src">The source, for people and agents alike: '
            f'<a href="{e(src)}"><code>{e(path)}</code></a></p></header>')
    return page(f"doc-{el.get('id')}", el.get("title"), CSS, f'{head}<article class="doc">{body}</article>')


PAGES = {doc_file(el.get("id")): render(path, el) for path, el in DOCS}
